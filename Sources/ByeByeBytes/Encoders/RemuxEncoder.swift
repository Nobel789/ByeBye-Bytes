import Foundation
import AVFoundation
import CoreMedia

/// Stream-copies an already-HEVC source into an MP4 container with an `hvc1`
/// sample entry. No decode, no re-encode; preserves original bitstream.
public struct RemuxEncoder: Encoder {
    public init() {}

    public func encode(
        sources: [URL],
        recipe: EncodeRecipe,
        outputURL: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        guard sources.count == 1, let sourceURL = sources.first else {
            throw EncoderError.unsupportedInput("Remux requires single source")
        }

        let asset = AVURLAsset(url: sourceURL)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw EncoderError.assetLoadFailed(sourceURL)
        }
        let durationSeconds = max(duration.seconds, 0.001)

        let videoTracks = try await asset.loadTracksAsync(.video)
        let audioTracks = try await asset.loadTracksAsync(.audio)
        guard let videoTrack = videoTracks.first else {
            throw EncoderError.unsupportedInput("No video track")
        }

        // Reader
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw EncoderError.readerSetupFailed(error.localizedDescription)
        }

        // Passthrough video output: outputSettings = nil means no decode.
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw EncoderError.readerSetupFailed("Cannot add passthrough video output")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTracks.first {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioOutput = out
            }
        }

        // Writer
        let writer = try makeWriter(outputURL: outputURL, fileType: .mp4)

        let videoFormatHint = try await videoTrack.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormatHint as CMFormatDescription?
        )
        videoInput.expectsMediaDataInRealTime = false
        // Preserve source orientation.
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        videoInput.transform = preferredTransform
        guard writer.canAdd(videoInput) else {
            throw EncoderError.writerSetupFailed("Cannot add passthrough video input")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioTrack = audioTracks.first, audioOutput != nil {
            let hint = try await audioTrack.load(.formatDescriptions).first
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: hint as CMFormatDescription?
            )
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else {
            throw EncoderError.readerSetupFailed(reader.error?.localizedDescription ?? "startReading failed")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw EncoderError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        // Drive video & audio on dedicated serial queues.
        let videoQueue = DispatchQueue(label: "byebyebytes.remux.video")
        let audioQueue = DispatchQueue(label: "byebyebytes.remux.audio")

        actor ProgressTracker {
            var latestVideoPTS: Double = 0
            func update(_ s: Double) { if s > latestVideoPTS { latestVideoPTS = s } }
        }
        let tracker = ProgressTracker()

        // Drain video
        async let videoDone: Void = withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    if Task.isCancelled {
                        videoInput.markAsFinished()
                        cont.resume()
                        return
                    }
                    if let sb = videoOutput.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                        if !pts.isNaN {
                            Task { await tracker.update(pts) }
                            let frac = min(1.0, max(0.0, pts / durationSeconds))
                            progress(frac)
                        }
                        if !videoInput.append(sb) {
                            videoInput.markAsFinished()
                            cont.resume()
                            return
                        }
                    } else {
                        videoInput.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }

        // Drain audio (may be nil)
        async let audioDone: Void = withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            guard let aInput = audioInput, let aOutput = audioOutput else {
                cont.resume()
                return
            }
            aInput.requestMediaDataWhenReady(on: audioQueue) {
                while aInput.isReadyForMoreMediaData {
                    if Task.isCancelled {
                        aInput.markAsFinished()
                        cont.resume()
                        return
                    }
                    if let sb = aOutput.copyNextSampleBuffer() {
                        if !aInput.append(sb) {
                            aInput.markAsFinished()
                            cont.resume()
                            return
                        }
                    } else {
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
            reader.cancelReading()
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
}
