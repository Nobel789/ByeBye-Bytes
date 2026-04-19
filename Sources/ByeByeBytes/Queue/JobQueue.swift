import Foundation
import Combine
import os

/// Simple async gate that bounds the number of concurrently running encodes.
/// Task-based, not thread-based: callers `await acquire()` before running
/// and `await release()` when done. Pending tasks suspend on continuations
/// in FIFO order.
fileprivate actor ExecutionGate {
    private let maxConcurrent: Int
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            // Slot transfers directly to the next waiter; inFlight unchanged.
            next.resume()
        } else {
            inFlight = max(0, inFlight - 1)
        }
    }
}

/// Main-actor-isolated job queue. SwiftUI observes `jobs` and
/// `pendingMultiDropURLs` to drive the UI. All mutations happen on the
/// main actor; encode work runs in detached tasks.
@MainActor
public final class JobQueue: ObservableObject {

    @Published public private(set) var jobs: [Job] = []
    @Published public private(set) var pendingMultiDropURLs: [URL]? = nil

    private let gate: ExecutionGate

    /// Matches the number of dedicated HEVC encoder engines on the host.
    /// Apple Silicon: M1 / M2 / M3 / M4 base chips ship 1 engine, Pro/Max/Ultra
    /// variants ship 2+ and also carry ≥10 CPU cores — so core count is a
    /// cheap, reliable proxy. Intel falls to the lower branch and encodes
    /// in software, where one concurrent encode keeps latency predictable.
    private static var defaultConcurrency: Int {
        ProcessInfo.processInfo.activeProcessorCount >= 10 ? 2 : 1
    }
    private var runners: [UUID: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "com.byebyebytes.queue", category: "JobQueue")
    private let settings: AppSettings?

    /// Minimum delta between UI-visible progress updates, per job.
    private static let progressThrottleInterval: TimeInterval = 0.1

    public init(settings: AppSettings? = nil) {
        self.settings = settings
        self.gate = ExecutionGate(maxConcurrent: Self.defaultConcurrency)
    }

    // MARK: - Public API

    /// Enqueues one or more URLs. A single URL encodes immediately; two or
    /// more surface `pendingMultiDropURLs` so the UI can prompt the user to
    /// choose between batch-encode and merge.
    public func submit(urls: [URL]) {
        guard !urls.isEmpty else { return }
        if urls.count == 1 {
            enqueueSingle(url: urls[0])
        } else {
            pendingMultiDropURLs = urls
        }
    }

    /// Commits the pending multi-drop as one job per URL.
    public func confirmBatch() {
        guard let pending = pendingMultiDropURLs else { return }
        pendingMultiDropURLs = nil
        for url in pending {
            enqueueSingle(url: url)
        }
    }

    /// Commits the pending multi-drop as a single merged job. No-op (but
    /// still clears the pending list) if fewer than two URLs are pending.
    public func confirmMerge() {
        guard let pending = pendingMultiDropURLs, pending.count >= 2 else {
            pendingMultiDropURLs = nil
            return
        }
        pendingMultiDropURLs = nil
        enqueueMerge(sources: pending)
    }

    /// Requests cancellation of the identified job. State transition to
    /// `.cancelled` happens inside the runner when it observes the cancel.
    public func cancel(id: Job.ID) {
        runners[id]?.cancel()
    }

    /// Removes all terminal jobs (`done`, `failed`, `cancelled`, `skipped`)
    /// from the visible queue. In-flight jobs are left alone.
    public func clearCompleted() {
        jobs.removeAll { job in
            switch job.state {
            case .done, .cancelled, .failed, .skipped:
                return true
            case .queued, .analyzing, .encoding:
                return false
            }
        }
    }

    // MARK: - Enqueue helpers

    private func enqueueSingle(url: URL) {
        let job = Job(
            kind: .single,
            sources: [url],
            displayName: friendlyName([url], kind: .single),
            bytesBefore: fileSize(url)
        )
        jobs.append(job)
        startRunner(for: job.id)
    }

    private func enqueueMerge(sources: [URL]) {
        let totalBytes = sources.reduce(Int64(0)) { $0 + fileSize($1) }
        let job = Job(
            kind: .merge,
            sources: sources,
            displayName: friendlyName(sources, kind: .merge),
            bytesBefore: totalBytes
        )
        jobs.append(job)
        startRunner(for: job.id)
    }

    // MARK: - Execution pipeline

    private func startRunner(for id: UUID) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(id: id)
        }
        runners[id] = task
    }

    private func run(id: UUID) async {
        // Wait for a slot — stays `.queued` until we acquire.
        await gate.acquire()
        defer {
            Task { await gate.release() }
        }

        // Refetch the job; the UI may have cancelled while we were waiting.
        guard let snapshot = currentJob(id: id) else { return }
        if Task.isCancelled {
            updateJob(id: id) { $0.state = .cancelled }
            return
        }

        do {
            // 1) Analyze.
            updateJob(id: id) { $0.state = .analyzing }
            let profiles = try await analyze(sources: snapshot.sources)
            try Task.checkCancellation()

            // 2) Recipe.
            let recipe: EncodeRecipe
            switch snapshot.kind {
            case .single:
                recipe = SettingsResolver.resolve(single: profiles[0])
            case .merge:
                recipe = SettingsResolver.resolve(merge: profiles)
            }

            // 3) Output URL.
            let outDir = settings?.outputDirectory
            let output: URL
            switch snapshot.kind {
            case .single:
                output = OutputRouter.outputURL(forSingle: snapshot.sources[0], in: outDir)
            case .merge:
                output = OutputRouter.outputURL(forMerge: snapshot.sources, in: outDir)
            }
            updateJob(id: id) { $0.outputURL = output }

            // 4) Pick encoder.
            let encoder = selectEncoder(for: snapshot.kind, strategy: recipe.strategy)

            // 5) Encode.
            updateJob(id: id) {
                $0.state = .encoding
                $0.startedAt = Date()
            }

            // Progress plumbing: reporter owned by the main actor, mutated via
            // a serial throttled hop. The closure itself is @Sendable.
            let reporterBox = ProgressBox()
            let progressClosure: @Sendable (Double) -> Void = { [weak self] fraction in
                guard let self else { return }
                Task { @MainActor in
                    self.handleProgress(id: id, fraction: fraction, box: reporterBox)
                }
            }

            _ = try await encoder.encode(
                sources: snapshot.sources,
                recipe: recipe,
                outputURL: output,
                progress: progressClosure
            )

            try Task.checkCancellation()

            // 6) Done — but bail if single-source encode didn't actually shrink the file.
            //    Threshold: require ≥2% reduction to call it a "save". Applies only to
            //    single jobs; merges are legitimate even when larger than any input.
            let outBytes = fileSize(output)
            let shouldKeep: Bool = {
                guard snapshot.kind == .single else { return true }
                guard outBytes > 0 else { return true }
                return Double(outBytes) < Double(snapshot.bytesBefore) * 0.98
            }()

            if !shouldKeep {
                try? FileManager.default.removeItem(at: output)
                updateJob(id: id) {
                    $0.progress = JobProgress(fraction: 1.0, etaSeconds: 0)
                    $0.state = .skipped("already well-compressed")
                    $0.finishedAt = Date()
                    $0.bytesAfter = nil
                    $0.outputURL = nil
                }
            } else {
                updateJob(id: id) {
                    $0.progress = JobProgress(fraction: 1.0, etaSeconds: 0)
                    $0.state = .done
                    $0.finishedAt = Date()
                    $0.bytesAfter = outBytes
                }
            }
        } catch is CancellationError {
            updateJob(id: id) { $0.state = .cancelled }
        } catch let err as EncoderError {
            if case .cancelled = err {
                updateJob(id: id) { $0.state = .cancelled }
            } else {
                let msg = err.errorDescription ?? "Encode failed"
                logger.error("Job \(id.uuidString, privacy: .public) failed: \(msg, privacy: .public)")
                updateJob(id: id) { $0.state = .failed(msg) }
            }
        } catch {
            if Task.isCancelled {
                updateJob(id: id) { $0.state = .cancelled }
            } else {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("Job \(id.uuidString, privacy: .public) failed: \(msg, privacy: .public)")
                updateJob(id: id) { $0.state = .failed(msg) }
            }
        }

        runners[id] = nil
    }

    private func analyze(sources: [URL]) async throws -> [SourceProfile] {
        var profiles: [SourceProfile] = []
        profiles.reserveCapacity(sources.count)
        for url in sources {
            try Task.checkCancellation()
            let profile = try await MediaInspector.inspect(url)
            profiles.append(profile)
        }
        return profiles
    }

    private func selectEncoder(for kind: JobKind, strategy: EncodeStrategy) -> any Encoder {
        switch kind {
        case .single:
            switch strategy {
            case .remux:
                return RemuxEncoder()
            case .reencode, .mergeFast, .mergeNormalize:
                return SingleFileEncoder()
            }
        case .merge:
            return MergeEncoder()
        }
    }

    // MARK: - Progress throttling

    /// Box for ProgressReporter state + last-emit timestamp. Held strongly by
    /// the progress closure and mutated only on the main actor.
    private final class ProgressBox {
        var reporter = ProgressReporter()
        var lastEmit: Date = .distantPast
    }

    private func handleProgress(id: UUID, fraction: Double, box: ProgressBox) {
        let now = Date()
        // Always let fraction==1.0 through; otherwise throttle.
        if fraction < 0.999,
           now.timeIntervalSince(box.lastEmit) < Self.progressThrottleInterval {
            return
        }
        box.lastEmit = now
        let next = box.reporter.update(fraction: fraction)
        updateJob(id: id) { $0.progress = next }
    }

    // MARK: - State helpers

    private func currentJob(id: UUID) -> Job? {
        jobs.first(where: { $0.id == id })
    }

    private func updateJob(id: UUID, _ mutate: (inout Job) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        var copy = jobs[idx]
        mutate(&copy)
        jobs[idx] = copy
    }

    // MARK: - File helpers

    private func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func friendlyName(_ urls: [URL], kind: JobKind) -> String {
        switch kind {
        case .single:
            return urls.first?.lastPathComponent ?? "Untitled"
        case .merge:
            return "\(urls.count) clips merged"
        }
    }
}
