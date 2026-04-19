/// Top-level window view: swaps between DropZoneView (empty) and QueueView, always accepts drops.

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import os

private let dropLog = Logger(subsystem: "com.byebyebytes.app", category: "drop")

@MainActor
struct RootView: View {
    @ObservedObject var queue: JobQueue
    @ObservedObject var settings: AppSettings
    @State private var isDropTargeted = false

    private static let acceptedExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "webm", "avi", "mpg", "mpeg", "3gp", "ts"
    ]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if queue.jobs.isEmpty && (queue.pendingMultiDropURLs?.isEmpty ?? true) {
                    DropZoneView(isTargeted: isDropTargeted, onPick: presentOpenPanel)
                } else {
                    QueueView(queue: queue,
                              isDropTargeted: isDropTargeted,
                              onPick: presentOpenPanel)
                }
            }
            .frame(maxHeight: .infinity)

            OutputFolderBar(settings: settings)
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(Theme.idleBg.ignoresSafeArea())
        .onDrop(
            of: [UTType.fileURL, UTType.movie, UTType.video,
                 UTType.quickTimeMovie, UTType.mpeg4Movie, UTType.item],
            isTargeted: $isDropTargeted
        ) { providers in
            dropLog.info("drop received: \(providers.count) provider(s)")
            for (i, p) in providers.enumerated() {
                dropLog.info("  [\(i)] types=\(p.registeredTypeIdentifiers)")
            }
            Task { @MainActor in
                let urls = await Self.extractFileURLs(from: providers)
                dropLog.info("resolved \(urls.count) URL(s): \(urls.map { $0.path })")
                guard !urls.isEmpty else { return }
                queue.submit(urls: urls)
            }
            return true
        }
        // Cmd-O opens the picker. Lives in an invisible button so the
        // shortcut is always discoverable via menu/accessibility.
        .background(
            Button("Open Video…", action: presentOpenPanel)
                .keyboardShortcut("o", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Open panel

    @MainActor
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose one or more videos to encode."
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        if panel.runModal() == .OK {
            let picked = panel.urls.filter(Self.isAcceptedVideo)
            guard !picked.isEmpty else { return }
            dropLog.info("picked \(picked.count) URL(s): \(picked.map { $0.path })")
            queue.submit(urls: picked)
        }
    }

    // MARK: - Drop extraction

    private static func extractFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var results: [URL] = []
        for provider in providers {
            if let url = await loadFileURL(from: provider), isAcceptedVideo(url) {
                results.append(url)
            }
        }
        return results
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        // Strategy 1: public.file-url loadItem — most Finder drags support this.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadItemAsURL(provider, typeIdentifier: UTType.fileURL.identifier) {
                dropLog.info("loaded via public.file-url: \(url.path)")
                return url
            }
        }

        // Strategy 2: loadFileRepresentation for any declared video UTI.
        //   This gives us a temporary file URL even for in-memory drag items.
        let videoTypes: [String] = provider.registeredTypeIdentifiers.filter { id in
            guard let t = UTType(id) else { return false }
            return t.conforms(to: .movie) || t.conforms(to: .video) || t.conforms(to: .audiovisualContent)
        }
        for id in videoTypes {
            if let url = await loadFileRep(provider, typeIdentifier: id) {
                dropLog.info("loaded via loadFileRepresentation(\(id)): \(url.path)")
                return url
            }
        }

        // Strategy 3: fallback — loadItem on any registered identifier; maybe Data/String URL.
        for id in provider.registeredTypeIdentifiers {
            if let url = await loadItemAsURL(provider, typeIdentifier: id) {
                dropLog.info("loaded via loadItem(\(id)): \(url.path)")
                return url
            }
        }

        dropLog.error("failed to resolve provider. types=\(provider.registeredTypeIdentifiers)")
        return nil
    }

    private static func loadItemAsURL(_ provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, err in
                if let err {
                    dropLog.error("loadItem(\(typeIdentifier)) error: \(err.localizedDescription)")
                }
                if let url = item as? URL {
                    cont.resume(returning: url)
                } else if let data = item as? Data {
                    if let url = URL(dataRepresentation: data, relativeTo: nil) {
                        cont.resume(returning: url)
                    } else if let str = String(data: data, encoding: .utf8),
                              let url = URL(string: str) {
                        cont.resume(returning: url)
                    } else {
                        cont.resume(returning: nil)
                    }
                } else if let str = item as? String, let url = URL(string: str) {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Copies into a temp directory on our side — `loadFileRepresentation` hands us a URL
    /// that's only valid inside the callback, so we must relocate before returning.
    private static func loadFileRep(_ provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { source, err in
                if let err {
                    dropLog.error("loadFileRepresentation(\(typeIdentifier)) error: \(err.localizedDescription)")
                    cont.resume(returning: nil)
                    return
                }
                guard let source else { cont.resume(returning: nil); return }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("byebyebytes-drops", isDirectory: true)
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                let target = dest.appendingPathComponent(source.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                do {
                    try FileManager.default.copyItem(at: source, to: target)
                    cont.resume(returning: target)
                } catch {
                    dropLog.error("copy failed: \(error.localizedDescription)")
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private static func isAcceptedVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if acceptedExtensions.contains(ext) { return true }
        // Fall back to UTI check for video content.
        if let t = UTType(filenameExtension: ext) {
            return t.conforms(to: .movie) || t.conforms(to: .video) || t.conforms(to: .audiovisualContent)
        }
        return false
    }
}
