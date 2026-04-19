import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Full single-source re-encode: AVAssetReader decodes → AVAssetWriterInput
/// (HEVC via hardware VideoToolbox) re-encodes to MP4/hvc1.
public struct SingleFileEncoder: Encoder {
    public init() {}

    public func encode(
        sources: [URL],
        recipe: EncodeRecipe,
        outputURL: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        guard sources.count == 1, let sourceURL = sources.first else {
            throw EncoderError.unsupportedInput("SingleFileEncoder requires single source")
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

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalRate = try await videoTrack.load(.nominalFrameRate)
        let fps = Int((nominalRate > 0 ? nominalRate : 30).rounded())

        // Determine encode size (respect rotation → use rendered size magnitudes).
        // Keep naturalSize as the pixel buffer size; transform applied via writerInput.transform.
        let encodeSize = CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))

        // Reader
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw EncoderError.readerSetupFailed(error.localizedDescription)
        }

        // Video decode output — request pixel format matching profile.
        let pixelFormat = pixelFormatType(for: recipe.hevcProfile)
        let videoReaderSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoReaderSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw EncoderError.readerSetupFailed("Cannot add decoded video output")
        }
        reader.add(videoOutput)

        // Audio output
        var audioOutput: AVAssetReaderTrackOutput?
        var audioSourceSampleRate: Double = 48_000
        var audioPassthroughActive = false
        if let audioTrack = audioTracks.first {
            if let fd = try await audioTrack.load(.formatDescriptions).first {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                    audioSourceSampleRate = asbd.mSampleRate
                    if recipe.audioPassthrough && asbd.mFormatID == kAudioFormatMPEG4AAC {
                        audioPassthroughActive = true
                    }
                }
            }
            let settings: [String: Any]? = audioPassthroughActive ? nil : [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioOutput = out
            }
        }

        // Writer
        let writer = try makeWriter(outputURL: outputURL, fileType: .mp4)

        // Preserve source common/quicktime metadata (creation date, GPS, model, etc.).
        // AVAssetWriter drops these by default.
        await copyPreservedMetadata(from: asset, to: writer)

        let videoSettings = hevcOutputSettings(size: encodeSize, fps: fps, recipe: recipe)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = preferredTransform
        guard writer.canAdd(videoInput) else {
            throw EncoderError.writerSetupFailed("Cannot add HEVC video input")
        }
        writer.add(videoInput)

        // Pixel buffer adaptor to pass CVPixelBuffers directly (no sample buffer re-wrap churn).
        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: Int(encodeSize.width),
            kCVPixelBufferHeightKey as String: Int(encodeSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )

        var audioInput: AVAssetWriterInput?
        if let audioTrack = audioTracks.first, audioOutput != nil {
            let input: AVAssetWriterInput
            if audioPassthroughActive {
                let hint = try await audioTrack.load(.formatDescriptions).first
                input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: nil,
                    sourceFormatHint: hint as CMFormatDescription?
                )
            } else {
                let settings = audioOutputSettings(recipe: recipe, sourceSampleRate: audioSourceSampleRate)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            }
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

        let videoQueue = DispatchQueue(label: "byebyebytes.reencode.video")
        let audioQueue = DispatchQueue(label: "byebyebytes.reencode.audio")

        // Video loop
        async let videoDone: Void = withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    if Task.isCancelled {
                        videoInput.markAsFinished()
                        cont.resume()
                        return
                    }
                    if let sb = videoOutput.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                        let ptsSeconds = pts.seconds
                        var appended = false
                        if let pb = CMSampleBufferGetImageBuffer(sb) {
                            appended = adaptor.append(pb, withPresentationTime: pts)
                        } else {
                            appended = videoInput.append(sb)
                        }
                        if !appended {
                            videoInput.markAsFinished()
                            cont.resume()
                            return
                        }
                        if !ptsSeconds.isNaN {
                            let frac = min(1.0, max(0.0, ptsSeconds / durationSeconds))
                            progress(frac)
                        }
                    } else {
                        videoInput.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }

        // Audio loop
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
