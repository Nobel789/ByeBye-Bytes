import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage

/// Merges two or more source files. Two modes:
/// - `.mergeFast`: assume identical params, stitch via `AVMutableComposition` +
///   `AVAssetExportPresetPassthrough` (no re-encode).
/// - `.mergeNormalize`: scale + letterbox onto a black canvas of target size,
///   concatenated via a reader/writer pipeline with a running PTS offset.
public struct MergeEncoder: Encoder {
    public init() {}

    public func encode(
        sources: [URL],
        recipe: EncodeRecipe,
        outputURL: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        guard sources.count >= 2 else {
            throw EncoderError.unsupportedInput("Merge requires at least two sources")
        }

        switch recipe.strategy {
        case .mergeFast:
            return try await mergeFast(sources: sources, recipe: recipe,
                                       outputURL: outputURL, progress: progress)
        case .mergeNormalize(let targetSize, let targetFPS):
            return try await mergeNormalize(sources: sources, recipe: recipe,
                                            targetSize: targetSize, targetFPS: targetFPS,
                                            outputURL: outputURL, progress: progress)
        default:
            throw EncoderError.unsupportedInput("MergeEncoder only handles merge strategies")
        }
    }

    // MARK: Fast path

    private func mergeFast(
        sources: [URL],
        recipe: EncodeRecipe,
        outputURL: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EncoderError.writerSetupFailed("Could not create composition video track")
        }
        let aTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        for url in sources {
            let asset = AVURLAsset(url: url)
            let dur: CMTime
            do { dur = try await asset.load(.duration) } catch {
                throw EncoderError.assetLoadFailed(url)
            }
            let range = CMTimeRange(start: .zero, duration: dur)

            if let srcV = try await asset.loadTracksAsync(.video).first {
                do {
                    try vTrack.insertTimeRange(range, of: srcV, at: cursor)
                    if cursor == .zero {
                        vTrack.preferredTransform = try await srcV.load(.preferredTransform)
                    }
                } catch {
                    throw EncoderError.encodeFailed("Composition insert failed: \(error.localizedDescription)")
                }
            }
            if let srcA = try await asset.loadTracksAsync(.audio).first, let aTrack {
                try? aTrack.insertTimeRange(range, of: srcA, at: cursor)
            }
            cursor = CMTimeAdd(cursor, dur)
        }

        // Remove any pre-existing file.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            // Fallback: reader/writer passthrough.
            return try await passthroughCompositionFallback(composition: composition,
                                                            outputURL: outputURL,
                                                            progress: progress)
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        // Progress polling task.
        let progressTask = Task { [export] in
            while !Task.isCancelled {
                progress(Double(export.progress))
                if export.status == .completed || export.status == .failed || export.status == .cancelled {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await export.export()
        progressTask.cancel()

        if Task.isCancelled {
            export.cancelExport()
            throw EncoderError.cancelled
        }

        switch export.status {
        case .completed:
            progress(1.0)
            return outputURL
        case .failed, .cancelled:
            // Fall back to reader/writer passthrough if the passthrough preset refused
            // (common with mixed sample entry tags e.g. hev1 vs hvc1).
            return try await passthroughCompositionFallback(composition: composition,
                                                            outputURL: outputURL,
                                                            progress: progress)
        default:
            throw EncoderError.encodeFailed("Export ended in status \(export.status.rawValue)")
        }
    }

    /// Fallback stream-copy of an already-stitched composition using reader/writer.
    private func passthroughCompositionFallback(
        composition: AVComposition,
        outputURL: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        let total = max(composition.duration.seconds, 0.001)

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: composition) }
        catch { throw EncoderError.readerSetupFailed(error.localizedDescription) }

        let vTracks = try await composition.loadTracksAsync(.video)
        let aTracks = try await composition.loadTracksAsync(.audio)
        guard let vTrack = vTracks.first else {
            throw EncoderError.unsupportedInput("Composition has no video track")
        }

        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else {
            throw EncoderError.readerSetupFailed("Cannot add passthrough video output")
        }
        reader.add(vOut)

        var aOut: AVAssetReaderTrackOutput?
        if let aTrack = aTracks.first {
            let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            o.alwaysCopiesSampleData = false
            if reader.canAdd(o) { reader.add(o); aOut = o }
        }

        let writer = try makeWriter(outputURL: outputURL, fileType: .mp4)
        let vHint = try await vTrack.load(.formatDescriptions).first
        let vIn = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: vHint as CMFormatDescription?
        )
        vIn.expectsMediaDataInRealTime = false
        vIn.transform = (try? await vTrack.load(.preferredTransform)) ?? .identity
        guard writer.canAdd(vIn) else {
            throw EncoderError.writerSetupFailed("Cannot add passthrough video input")
        }
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if let aTrack = aTracks.first, aOut != nil {
            let hint = try await aTrack.load(.formatDescriptions).first
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: hint as CMFormatDescription?
            )
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); aIn = input }
        }

        guard reader.startReading() else {
            throw EncoderError.readerSetupFailed(reader.error?.localizedDescription ?? "startReading failed")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw EncoderError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let vQ = DispatchQueue(label: "byebyebytes.merge.fast.video")
        let aQ = DispatchQueue(label: "byebyebytes.merge.fast.audio")

        async let videoDone: Void = withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            vIn.requestMediaDataWhenReady(on: vQ) {
                while vIn.isReadyForMoreMediaData {
                    if Task.isCancelled { vIn.markAsFinished(); cont.resume(); return }
                    if let sb = vOut.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                        if !pts.isNaN {
                            progress(min(1.0, max(0.0, pts / total)))
                        }
                        if !vIn.append(sb) { vIn.markAsFinished(); cont.resume(); return }
                    } else { vIn.markAsFinished(); cont.resume(); return }
                }
            }
        }
        async let audioDone: Void = withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            guard let aIn, let aOut else { cont.resume(); return }
            aIn.requestMediaDataWhenReady(on: aQ) {
                while aIn.isReadyForMoreMediaData {
                    if Task.isCancelled { aIn.markAsFinished(); cont.resume(); return }
                    if let sb = aOut.copyNextSampleBuffer() {
                        if !aIn.append(sb) { aIn.markAsFinished(); cont.resume(); return }
                    } else { aIn.markAsFinished(); cont.resume(); return }
                }
            }
        }

        _ = await (videoDone, audioDone)

        if Task.isCancelled {
            writer.cancelWriting(); reader.cancelReading()
            throw EncoderError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw EncoderError.encodeFailed(reader.error?.localizedDescription ?? "reader failed")
        }

        await writer.finishWritingAsync()
        if writer.status == .failed {
            throw EncoderError.encodeFailed(writer.error?.localizedDescription ?? "writer failed")
        }
        progress(1.0)
        return outputURL
    }

    // MARK: Normalize path (Option B: CIContext letterbox)

    /// Per-source decoder + pre-computed transform parameters.
    private final class NormDecoder {
        let url: URL
        let duration: CMTime
        let transform: CGAffineTransform
        let scale: CGFloat
        let tx: CGFloat
        let ty: CGFloat
        let ptsOffset: CMTime
        let hasAudio: Bool
        let reader: AVAssetReader
        let videoOut: AVAssetReaderTrackOutput
        let audioOut: AVAssetReaderTrackOutput?
        var finishedVideo = false
        var finishedAudio = false
        init(url: URL, duration: CMTime, transform: CGAffineTransform, scale: CGFloat,
             tx: CGFloat, ty: CGFloat, ptsOffset: CMTime, hasAudio: Bool,
             reader: AVAssetReader, videoOut: AVAssetReaderTrackOutput,
             audioOut: AVAssetReaderTrackOutput?) {
            self.url = url; self.duration = duration; self.transform = transform
            self.scale = scale; self.tx = tx; self.ty = ty; self.ptsOffset = ptsOffset
            self.hasAudio = hasAudio; self.reader = reader
            self.videoOut = videoOut; self.audioOut = audioOut
        }
    }

    private final class PumpState {
        var index: Int = 0
        var resumed: Bool = false
    }

    private func mergeNormalize(
        sources: [URL],
        recipe: EncodeRecipe,
        targetSize: CGSize,
        targetFPS: Int,
        outputURL: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        // ----- Phase 1: Gather source info + build all decoders up-front.
        struct SourceInfo {
            let url: URL
            let duration: CMTime
            let naturalSize: CGSize
            let transform: CGAffineTransform
            let sampleRate: Double
            let hasAudio: Bool
        }
        var infos: [SourceInfo] = []
        var totalSeconds: Double = 0
        for url in sources {
            let a = AVURLAsset(url: url)
            let dur: CMTime
            do { dur = try await a.load(.duration) } catch { throw EncoderError.assetLoadFailed(url) }
            guard let vt = try await a.loadTracksAsync(.video).first else {
                throw EncoderError.unsupportedInput("Source \(url.lastPathComponent) has no video")
            }
            let size = try await vt.load(.naturalSize)
            let tx = try await vt.load(.preferredTransform)
            var rate: Double = 48_000
            var hasAudio = false
            if let at = try await a.loadTracksAsync(.audio).first,
               let fd = try await at.load(.formatDescriptions).first {
                hasAudio = true
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                    rate = asbd.mSampleRate
                }
            }
            infos.append(SourceInfo(url: url, duration: dur, naturalSize: size,
                                    transform: tx, sampleRate: rate, hasAudio: hasAudio))
            totalSeconds += dur.seconds
        }
        let total = max(totalSeconds, 0.001)

        // ----- Phase 2: Writer setup (single writer, single video + audio input).
        let writer = try makeWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings = hevcOutputSettings(size: targetSize, fps: targetFPS, recipe: recipe)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw EncoderError.writerSetupFailed("Cannot add HEVC video input")
        }
        writer.add(videoInput)

        let pixelFormat = pixelFormatType(for: recipe.hevcProfile)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: Int(targetSize.width),
                kCVPixelBufferHeightKey as String: Int(targetSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
        )

        let commonSampleRate: Double = min(48_000,
            infos.compactMap { $0.hasAudio ? $0.sampleRate : nil }.max() ?? 48_000)
        let audioSettings = audioOutputSettings(recipe: recipe, sourceSampleRate: commonSampleRate)
        let audioInput: AVAssetWriterInput? = {
            guard infos.contains(where: { $0.hasAudio }) else { return nil }
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = false
            guard writer.canAdd(ai) else { return nil }
            writer.add(ai)
            return ai
        }()

        guard writer.startWriting() else {
            throw EncoderError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        // ----- Phase 3: Build one NormDecoder per source with transforms pre-computed.
        var decoders: [NormDecoder] = []
        var cumOffset = CMTime.zero
        for info in infos {
            let asset = AVURLAsset(url: info.url)
            let reader: AVAssetReader
            do { reader = try AVAssetReader(asset: asset) }
            catch { throw EncoderError.readerSetupFailed(error.localizedDescription) }

            guard let videoTrack = try await asset.loadTracksAsync(.video).first else { continue }
            let decodeFormat: OSType = kCVPixelFormatType_32BGRA
            let vOut = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: decodeFormat,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                ])
            vOut.alwaysCopiesSampleData = false
            guard reader.canAdd(vOut) else {
                throw EncoderError.readerSetupFailed("Cannot add decoded video output")
            }
            reader.add(vOut)

            var aOut: AVAssetReaderTrackOutput?
            if info.hasAudio, let audioTrack = try await asset.loadTracksAsync(.audio).first {
                let pcm: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: commonSampleRate,
                    AVNumberOfChannelsKey: max(1, recipe.audioChannels),
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcm)
                o.alwaysCopiesSampleData = false
                if reader.canAdd(o) { reader.add(o); aOut = o }
            }

            guard reader.startReading() else {
                throw EncoderError.readerSetupFailed(reader.error?.localizedDescription ?? "startReading failed")
            }

            // Fit + letterbox computation against the rendered (post-rotation) source size.
            let rotated = info.naturalSize.applying(info.transform.inverted())
            let srcW = abs(rotated.width == 0 ? info.naturalSize.width : rotated.width)
            let srcH = abs(rotated.height == 0 ? info.naturalSize.height : rotated.height)
            let scale = min(targetSize.width / srcW, targetSize.height / srcH)
            let fitW = srcW * scale
            let fitH = srcH * scale
            let tx = (targetSize.width - fitW) / 2.0
            let ty = (targetSize.height - fitH) / 2.0

            decoders.append(NormDecoder(
                url: info.url, duration: info.duration, transform: info.transform,
                scale: scale, tx: tx, ty: ty, ptsOffset: cumOffset,
                hasAudio: info.hasAudio && aOut != nil,
                reader: reader, videoOut: vOut, audioOut: aOut
            ))
            cumOffset = CMTimeAdd(cumOffset, info.duration)
        }

        guard !decoders.isEmpty else {
            writer.cancelWriting()
            throw EncoderError.unsupportedInput("No playable video sources")
        }

        // ----- Phase 4: Single pump on video input; stateful source advancement.
        let ciContext = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .cacheIntermediates: false,
        ])
        let blackCanvas = CIImage(color: .black).cropped(
            to: CGRect(origin: .zero, size: targetSize))
        let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        let videoQueue = DispatchQueue(label: "byebyebytes.merge.norm.video")
        let audioQueue = DispatchQueue(label: "byebyebytes.merge.norm.audio")

        let videoState = PumpState()
        let audioState = PumpState()

        async let videoDone: Void = withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                // Guard: the callback can be re-entered after a terminating resume
                // if markAsFinished hasn't been called yet on this tick.
                if videoState.resumed { return }
                while videoInput.isReadyForMoreMediaData {
                    if Task.isCancelled {
                        videoState.resumed = true
                        videoInput.markAsFinished()
                        cont.resume()
                        return
                    }
                    // Advance past exhausted decoders.
                    while videoState.index < decoders.count && decoders[videoState.index].finishedVideo {
                        videoState.index += 1
                    }
                    if videoState.index >= decoders.count {
                        videoState.resumed = true
                        videoInput.markAsFinished()
                        cont.resume()
                        return
                    }
                    let d = decoders[videoState.index]
                    guard let sb = d.videoOut.copyNextSampleBuffer() else {
                        d.finishedVideo = true
                        continue  // try next decoder on next loop iteration
                    }
                    guard let srcPB = CMSampleBufferGetImageBuffer(sb) else { continue }
                    let rawPTS = CMSampleBufferGetPresentationTimeStamp(sb)
                    let outPTS = CMTimeAdd(d.ptsOffset, rawPTS)

                    var image = CIImage(cvPixelBuffer: srcPB)
                    image = image.transformed(by: d.transform)
                    let bounds = image.extent
                    image = image.transformed(by: CGAffineTransform(translationX: -bounds.origin.x,
                                                                    y: -bounds.origin.y))
                    image = image.transformed(by: CGAffineTransform(scaleX: d.scale, y: d.scale))
                    image = image.transformed(by: CGAffineTransform(translationX: d.tx, y: d.ty))
                    let composited = image.composited(over: blackCanvas)
                                          .cropped(to: CGRect(origin: .zero, size: targetSize))

                    guard let pool = adaptor.pixelBufferPool else { continue }
                    var outPB: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB)
                    guard let dst = outPB else { continue }
                    ciContext.render(composited, to: dst,
                                     bounds: CGRect(origin: .zero, size: targetSize),
                                     colorSpace: outputColorSpace)

                    if !adaptor.append(dst, withPresentationTime: outPTS) {
                        videoState.resumed = true
                        videoInput.markAsFinished()
                        cont.resume()
                        return
                    }

                    let ptsSeconds = outPTS.seconds
                    if !ptsSeconds.isNaN {
                        progress(min(1.0, max(0.0, ptsSeconds / total)))
                    }
                }
            }
        }

        async let audioDone: Void = withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            guard let aInput = audioInput else { cont.resume(); return }
            aInput.requestMediaDataWhenReady(on: audioQueue) {
                if audioState.resumed { return }
                while aInput.isReadyForMoreMediaData {
                    if Task.isCancelled {
                        audioState.resumed = true
                        aInput.markAsFinished()
                        cont.resume()
                        return
                    }
                    while audioState.index < decoders.count
                            && (!decoders[audioState.index].hasAudio || decoders[audioState.index].finishedAudio) {
                        audioState.index += 1
                    }
                    if audioState.index >= decoders.count {
                        audioState.resumed = true
                        aInput.markAsFinished()
                        cont.resume()
                        return
                    }
                    let d = decoders[audioState.index]
                    guard let aOut = d.audioOut else { d.finishedAudio = true; continue }
                    guard let sb = aOut.copyNextSampleBuffer() else {
                        d.finishedAudio = true
                        continue
                    }
                    let offsetSB = MergeEncoder.offsetSampleBuffer(sb, by: d.ptsOffset) ?? sb
                    if !aInput.append(offsetSB) {
                        audioState.resumed = true
                        aInput.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }

        _ = await (videoDone, audioDone)

        if Task.isCancelled {
            writer.cancelWriting()
            for d in decoders { d.reader.cancelReading() }
            throw EncoderError.cancelled
        }
        for d in decoders where d.reader.status == .failed {
            writer.cancelWriting()
            throw EncoderError.encodeFailed(d.reader.error?.localizedDescription ?? "reader failed")
        }

        await writer.finishWritingAsync()
        if writer.status == .failed {
            throw EncoderError.encodeFailed(writer.error?.localizedDescription ?? "writer failed")
        }
        progress(1.0)
        return outputURL
    }

    /// Shift a sample buffer's PTS (and DTS) by the given offset. Returns a new CMSampleBuffer.
    private static func offsetSampleBuffer(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        if offset == .zero { return sb }
        let count = CMSampleBufferGetNumSamples(sb)
        var timingInfos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(),
                                               count: max(count, 1))
        var outCount = CMItemCount(0)
        let status = CMSampleBufferGetSampleTimingInfoArray(
            sb, entryCount: timingInfos.count,
            arrayToFill: &timingInfos, entriesNeededOut: &outCount)
        guard status == noErr else { return nil }
        for i in 0..<Int(outCount) {
            if timingInfos[i].presentationTimeStamp.isValid {
                timingInfos[i].presentationTimeStamp = CMTimeAdd(timingInfos[i].presentationTimeStamp, offset)
            }
            if timingInfos[i].decodeTimeStamp.isValid {
                timingInfos[i].decodeTimeStamp = CMTimeAdd(timingInfos[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        let s = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sb,
            sampleTimingEntryCount: outCount,
            sampleTimingArray: timingInfos,
            sampleBufferOut: &out)
        return s == noErr ? out : nil
    }
}
