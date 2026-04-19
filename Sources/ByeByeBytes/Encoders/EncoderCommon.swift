import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

// MARK: - Writer factory

/// Create a preconfigured AVAssetWriter for streaming-optimized MP4 output.
/// - Sets `shouldOptimizeForNetworkUse = true` (moves `moov` atom to the head).
/// - Sets `movFragmentInterval = .invalid` so the file is not fragmented.
/// - With `.mp4` + `AVVideoCodecType.hevc`, AVAssetWriter writes the sample entry
///   as `hvc1` by default (not `hev1`), which is the QuickTime / streaming preferred tag.
func makeWriter(outputURL: URL, fileType: AVFileType = .mp4) throws -> AVAssetWriter {
    // Remove any existing file - AVAssetWriter refuses to overwrite.
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try? FileManager.default.removeItem(at: outputURL)
    }
    let writer: AVAssetWriter
    do {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
    } catch {
        throw EncoderError.writerSetupFailed(error.localizedDescription)
    }
    writer.shouldOptimizeForNetworkUse = true
    writer.movieFragmentInterval = CMTime.invalid
    return writer
}

// MARK: - HEVC output settings

func hevcOutputSettings(size: CGSize, fps: Int, recipe: EncodeRecipe) -> [String: Any] {
    let profileKey: String = {
        switch recipe.hevcProfile {
        case .main10: return kVTProfileLevel_HEVC_Main10_AutoLevel as String
        case .main:   return kVTProfileLevel_HEVC_Main_AutoLevel   as String
        }
    }()

    let gopFrames = max(1, Int(Double(max(fps, 1)) * max(recipe.gopSeconds, 0.1)))

    var compression: [String: Any] = [
        AVVideoQualityKey: recipe.quality,
        AVVideoMaxKeyFrameIntervalKey: gopFrames,
        AVVideoProfileLevelKey: profileKey,
        AVVideoAllowFrameReorderingKey: true,
        AVVideoExpectedSourceFrameRateKey: max(fps, 1),
    ]
    if let cap = recipe.bitrateCap {
        compression[AVVideoAverageBitRateKey] = NSNumber(value: cap)
    }

    var settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: Int(size.width.rounded()),
        AVVideoHeightKey: Int(size.height.rounded()),
        AVVideoCompressionPropertiesKey: compression,
    ]

    if recipe.preserveHDR {
        let transfer = (recipe.hevcProfile == .main10)
            ? AVVideoTransferFunction_ITU_R_2100_HLG
            : AVVideoTransferFunction_ITU_R_709_2
        settings[AVVideoColorPropertiesKey] = hdrColorProperties(forTransfer: transfer)
    }
    return settings
}

// MARK: - HDR color properties

/// Produce a color-properties dict matched to the given transfer function.
/// Handles PQ (HDR10), HLG, and SDR (Rec.709) cases.
func hdrColorProperties(forTransfer transfer: String) -> [String: String] {
    switch transfer {
    case AVVideoTransferFunction_SMPTE_ST_2084_PQ,
         AVVideoTransferFunction_ITU_R_2100_HLG:
        return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ]
    default:
        return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
    }
}

// MARK: - Audio output settings

func audioOutputSettings(recipe: EncodeRecipe, sourceSampleRate: Double) -> [String: Any] {
    // Clamp sample rate to a sane value; AAC-LC supports up to 48 kHz well.
    let rate: Double = {
        if sourceSampleRate > 0 { return min(sourceSampleRate, 48_000) }
        return 48_000
    }()
    return [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: max(1, recipe.audioChannels),
        AVEncoderBitRateKey: recipe.audioBitrate,
    ]
}

// MARK: - Pixel buffer format helper

func pixelFormatType(for profile: HEVCProfile) -> OSType {
    switch profile {
    case .main10: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    case .main:   return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
}

// MARK: - Hardware specification

/// Specification dictionary that forces VideoToolbox to pick a hardware encoder
/// when one is available (Apple Silicon media engine).
let hardwareHEVCEncoderSpecification: [String: Any] = [
    kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
    kVTCompressionPropertyKey_RealTime as String: false,
]

// MARK: - Async finish helper

extension AVAssetWriter {
    /// Async wrapper around `finishWriting(completionHandler:)`.
    func finishWritingAsync() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.finishWriting { cont.resume() }
        }
    }
}

// MARK: - Load-tracks helper

extension AVAsset {
    /// Back-compat wrapper around `loadTracks(withMediaType:)` (iOS 15+/macOS 12+).
    func loadTracksAsync(_ mediaType: AVMediaType) async throws -> [AVAssetTrack] {
        try await self.loadTracks(withMediaType: mediaType)
    }
}
