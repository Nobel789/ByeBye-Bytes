import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import Metal
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

/// Build the `outputSettings` dict for an HEVC `AVAssetWriterInput`.
///
/// Key design decisions (Apple Silicon-oriented):
/// - We force hardware-backed VideoToolbox encoding via the encoder-spec dict on the compression
///   props (`EnableHardwareAcceleratedVideoEncoder` + `RequireHardwareAcceleratedVideoEncoder`).
///   AVAssetWriter already prefers the HW HEVC block on Apple Silicon, but this makes it
///   explicit and asserts no silent fallback to the slow software path.
/// - We supply both `AVVideoMaxKeyFrameIntervalKey` (frame count) and
///   `AVVideoMaxKeyFrameIntervalDurationKey` (seconds) so the rate controller always has the
///   time-based fence even if the decoded `fps` is wrong.
/// - Prefer `AVVideoQualityKey` for visually-lossless targets. When the planner provides
///   `bitrateCap` we pair it with `AVVideoAverageBitRateKey` + a `DataRateLimits` safety fence
///   (140% average over 1s) so the VBR rate control can't spike in chaotic scenes.
/// - We pass `AVVideoAllowFrameReorderingKey = true` so B-frames kick in (HW HEVC supports them;
///   they meaningfully reduce size on static-ish footage like screen recordings).
/// - `RealTime = false` tells VT we prefer compression ratio over low-latency behavior.
func hevcOutputSettings(size: CGSize, fps: Int, recipe: EncodeRecipe) -> [String: Any] {
    let profileKey: String = {
        switch recipe.hevcProfile {
        case .main10: return kVTProfileLevel_HEVC_Main10_AutoLevel as String
        case .main:   return kVTProfileLevel_HEVC_Main_AutoLevel   as String
        }
    }()

    let safeFps = max(fps, 1)
    let gopFrames = max(1, Int(Double(safeFps) * max(recipe.gopSeconds, 0.1)))

    var compression: [String: Any] = [
        AVVideoQualityKey: recipe.quality,
        AVVideoMaxKeyFrameIntervalKey: gopFrames,
        AVVideoMaxKeyFrameIntervalDurationKey: max(recipe.gopSeconds, 0.1),
        AVVideoProfileLevelKey: profileKey,
        AVVideoAllowFrameReorderingKey: true,
        AVVideoExpectedSourceFrameRateKey: safeFps,
        // Explicit VT hints. Accept they may be filtered out by AVAssetWriter — harmless.
        kVTCompressionPropertyKey_RealTime as String: false,
        kVTCompressionPropertyKey_AllowTemporalCompression as String: true,
        kVTCompressionPropertyKey_AllowFrameReordering as String: true,
        kVTCompressionPropertyKey_MaxKeyFrameInterval as String: gopFrames,
        kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String: max(recipe.gopSeconds, 0.1),
        kVTCompressionPropertyKey_ExpectedFrameRate as String: safeFps,
    ]

    // Force hardware selection; no silent software fallback.
    compression[AVVideoEncoderSpecificationKey] = hardwareHEVCEncoderSpecification

    if let cap = recipe.bitrateCap {
        compression[AVVideoAverageBitRateKey] = NSNumber(value: cap)
        // 140% of the mean over a 1-second sliding window is a common VBR peak fence that still
        // lets complex scenes breathe. Keeps the bitrate cap honest at the container level.
        let peak = max(Int64(1), Int64(Double(cap) * 1.4))
        compression[kVTCompressionPropertyKey_DataRateLimits as String] =
            [NSNumber(value: peak), NSNumber(value: 1.0)] as NSArray
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
    } else {
        // Tag SDR output explicitly so the HEVC elementary stream carries correct VUI matrix
        // identifiers. Players otherwise guess from resolution.
        settings[AVVideoColorPropertiesKey] = hdrColorProperties(forTransfer: AVVideoTransferFunction_ITU_R_709_2)
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

// MARK: - Pixel buffer format helpers

/// Pixel format for the *output* side of an HEVC encoder (what the pool hands us).
func pixelFormatType(for profile: HEVCProfile) -> OSType {
    switch profile {
    case .main10: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    case .main:   return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
}

/// Pixel format for the *decode* side of a reader (MergeEncoder normalize path).
///
/// We prefer the native biplanar YUV (`420YpCbCr8/10BiPlanarVideoRange`) over 32BGRA:
/// - No CPU-side BGRA swizzle on decode
/// - Same format as the encoder pool → adaptor can stay zero-copy
/// - CoreImage handles YCbCr natively on Metal (YCC→RGB done in a shader)
func decodePixelFormatType(for profile: HEVCProfile) -> OSType {
    switch profile {
    case .main10: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    case .main:   return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
}

// MARK: - Hardware specification

/// Encoder-selection dictionary passed to VideoToolbox. `Require*` makes the writer FAIL
/// rather than silently falling back to software — on Apple Silicon that's always what we want.
let hardwareHEVCEncoderSpecification: [String: Any] = [
    kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
]

// MARK: - Metal-backed CIContext (shared)

/// Process-wide Metal-backed CIContext. Reused across encodes to keep the Metal
/// command queue + shader cache warm. Fall back to the default CPU CIContext if
/// the system reports no Metal device (shouldn't happen on Apple Silicon).
enum SharedCI {
    static let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                .cacheIntermediates: false,
                .highQualityDownsample: true,
                .name: "ByeByeBytes.SharedCI",
            ])
        }
        return CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .cacheIntermediates: false,
        ])
    }()
}

// MARK: - Metadata preservation

/// Copy useful common + quicktime metadata items (creation date, GPS, make/model, rotation hints)
/// from an AVAsset to an AVAssetWriter. AVAssetWriter otherwise drops all of it.
///
/// Failure is non-fatal: metadata is UX-nice but not load-bearing for encode success.
func copyPreservedMetadata(from asset: AVAsset, to writer: AVAssetWriter) async {
    var items: [AVMetadataItem] = []
    if let common = try? await asset.load(.commonMetadata) {
        items.append(contentsOf: common)
    }
    if let quicktime = try? await asset.loadMetadata(for: .quickTimeMetadata) {
        items.append(contentsOf: quicktime)
    }
    if let iTunes = try? await asset.loadMetadata(for: .iTunesMetadata) {
        items.append(contentsOf: iTunes)
    }
    if !items.isEmpty {
        // Merge with anything the writer already carries (defensively).
        writer.metadata = writer.metadata + items
    }
}

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
