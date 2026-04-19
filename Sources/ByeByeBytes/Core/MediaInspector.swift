import Foundation
import AVFoundation
import CoreMedia
import CoreAudioTypes
import CoreVideo

/// Reads a media file and produces a `SourceProfile` describing it.
/// Uses the macOS 13+/iOS 16+ async `load(...)` APIs on AVAsset.
public enum MediaInspector {

    /// Probes `url` and returns a `SourceProfile`. Throws
    /// `EncoderError.assetLoadFailed` if AVFoundation cannot open the asset
    /// or its primary video track, and `EncoderError.unsupportedInput` if
    /// the asset has no video track or its format description is missing.
    public static func inspect(_ url: URL) async throws -> SourceProfile {
        // File size — resourceValues is cheap and works even if AVAsset chokes.
        let fileSize: Int64 = {
            if let vals = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let s = vals.fileSize {
                return Int64(s)
            }
            return 0
        }()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            async let t = asset.load(.tracks)
            async let d = asset.load(.duration)
            tracks = try await t
            duration = try await d
        } catch {
            throw EncoderError.assetLoadFailed(url)
        }

        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }

        guard let videoTrack = videoTracks.first else {
            throw EncoderError.unsupportedInput("No video track in \(url.lastPathComponent)")
        }

        // Video track properties loaded concurrently.
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let nominalFrameRate: Float
        let estimatedDataRate: Float
        let formatDescriptions: [CMFormatDescription]
        do {
            async let ns = videoTrack.load(.naturalSize)
            async let pt = videoTrack.load(.preferredTransform)
            async let fr = videoTrack.load(.nominalFrameRate)
            async let dr = videoTrack.load(.estimatedDataRate)
            async let fd = videoTrack.load(.formatDescriptions)
            naturalSize = try await ns
            preferredTransform = try await pt
            nominalFrameRate = try await fr
            estimatedDataRate = try await dr
            formatDescriptions = try await fd
        } catch {
            throw EncoderError.assetLoadFailed(url)
        }

        // Apply rotation from preferredTransform. For 90/270 rotations, swap width/height.
        let videoSize = applyTransform(to: naturalSize, transform: preferredTransform)

        guard let videoFormat = formatDescriptions.first else {
            throw EncoderError.unsupportedInput("Video track has no format description")
        }

        let videoCodec = CMFormatDescriptionGetMediaSubType(videoFormat)

        // estimatedDataRate is in bits/sec (despite AVFoundation using Float). 0 means unknown.
        let videoBitrate: Int64? = estimatedDataRate > 0 ? Int64(estimatedDataRate) : nil

        let bitDepth = detectBitDepth(format: videoFormat, codec: videoCodec)

        // Color info — returned as CF strings by CoreMedia; bridge to Swift String.
        let colorPrimaries = stringExtension(videoFormat, key: kCMFormatDescriptionExtension_ColorPrimaries)
        let transferFunction = stringExtension(videoFormat, key: kCMFormatDescriptionExtension_TransferFunction)
        let yCbCrMatrix = stringExtension(videoFormat, key: kCMFormatDescriptionExtension_YCbCrMatrix)

        let isHDR = isHDRTransfer(transferFunction)

        // Audio (optional).
        var hasAudio = false
        var audioCodec: AudioFormatID? = nil
        var audioChannels: Int = 0
        var audioSampleRate: Double = 0

        if let audioTrack = audioTracks.first {
            hasAudio = true
            let audioFormats: [CMFormatDescription]
            do {
                audioFormats = try await audioTrack.load(.formatDescriptions)
            } catch {
                audioFormats = []
            }
            if let audioFormat = audioFormats.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee {
                audioCodec = asbd.mFormatID
                audioChannels = Int(asbd.mChannelsPerFrame)
                audioSampleRate = asbd.mSampleRate
            }
        }

        return SourceProfile(
            url: url,
            fileSize: fileSize,
            duration: duration,
            videoSize: videoSize,
            frameRate: nominalFrameRate,
            videoCodec: videoCodec,
            videoBitrate: videoBitrate,
            bitDepth: bitDepth,
            isHDR: isHDR,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            hasAudio: hasAudio,
            audioCodec: audioCodec,
            audioChannels: audioChannels,
            audioSampleRate: audioSampleRate
        )
    }

    // MARK: - Helpers

    /// Applies the preferred transform to the natural size. A 90/270 rotation swaps W/H.
    private static func applyTransform(to size: CGSize, transform t: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(t)
        return CGSize(width: abs(rect.size.width), height: abs(rect.size.height))
    }

    private static func stringExtension(_ format: CMFormatDescription, key: CFString) -> String? {
        guard let ext = CMFormatDescriptionGetExtension(format, extensionKey: key) else { return nil }
        return ext as? String
    }

    /// Returns true for HLG or PQ/SMPTE ST 2084 transfer.
    private static func isHDRTransfer(_ transfer: String?) -> Bool {
        guard let transfer else { return false }
        if transfer == (AVVideoTransferFunction_ITU_R_2100_HLG as String) { return true }
        if transfer == (AVVideoTransferFunction_SMPTE_ST_2084_PQ as String) { return true }
        return false
    }

    /// Best-effort bit-depth detection. Defaults to 8 if nothing conclusive found.
    private static func detectBitDepth(format: CMFormatDescription, codec: CMVideoCodecType) -> Int {
        // 1. Generic Depth extension (sometimes populated for HEVC).
        if let depth = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_Depth) as? Int {
            // `Depth` is bits per pixel for the whole pixel; 30 = 10-bit RGB/YUV, 24 = 8-bit.
            if depth >= 30 { return 10 }
            if depth > 0   { return 8 }
        }

        // 2. Codec-specific sample description atoms.
        if let atoms = CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any] {

            // --- H.264: "avcC" — byte 1 is profile_idc.
            if codec == kCMVideoCodecType_H264, let avcC = atoms["avcC"] as? Data, avcC.count >= 2 {
                let profileIdc = avcC[1]
                // 110 High10, 122 High 4:2:2, 244 High 4:4:4 predictive — all >= 10-bit capable.
                if profileIdc == 110 || profileIdc == 122 || profileIdc == 244 {
                    return 10
                }
                return 8
            }

            // --- HEVC: "hvcC" — general_profile_idc is 5 bits at byte 1 low bits.
            //   bit_depth_luma_minus8 lives in the VPS/SPS, but general_profile_idc == 2 signals Main10.
            //   kCMVideoCodecType_HEVC matches 'hvc1'; 'hev1' variant also appears in the wild.
            if codec == kCMVideoCodecType_HEVC {
                let hvcCData: Data? = (atoms["hvcC"] as? Data) ?? (atoms["hev1"] as? Data)
                if let hvcC = hvcCData, hvcC.count >= 2 {
                    let generalProfileIdc = hvcC[1] & 0x1F
                    if generalProfileIdc == 2 { return 10 } // Main10
                    // Fall through to default 8 for Main (1).
                }
            }
        }

        // 3. HDR transfer implies 10-bit in practice even when we can't parse the atoms.
        if let transfer = stringExtension(format, key: kCMFormatDescriptionExtension_TransferFunction),
           isHDRTransfer(transfer) {
            return 10
        }

        return 8
    }
}

