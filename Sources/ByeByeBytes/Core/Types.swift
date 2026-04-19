import Foundation
import AVFoundation
import CoreMedia

// MARK: - Source analysis

public struct SourceProfile: Sendable, Equatable {
    public let url: URL
    public let fileSize: Int64
    public let duration: CMTime
    public let videoSize: CGSize
    public let frameRate: Float
    public let videoCodec: CMVideoCodecType
    public let videoBitrate: Int64?     // bits/sec, best-effort
    public let bitDepth: Int            // 8 or 10
    public let isHDR: Bool
    public let colorPrimaries: String?  // AVFoundation string values
    public let transferFunction: String?
    public let yCbCrMatrix: String?
    public let hasAudio: Bool
    public let audioCodec: AudioFormatID?
    public let audioChannels: Int
    public let audioSampleRate: Double

    public init(url: URL, fileSize: Int64, duration: CMTime, videoSize: CGSize,
                frameRate: Float, videoCodec: CMVideoCodecType, videoBitrate: Int64?,
                bitDepth: Int, isHDR: Bool, colorPrimaries: String?,
                transferFunction: String?, yCbCrMatrix: String?, hasAudio: Bool,
                audioCodec: AudioFormatID?, audioChannels: Int, audioSampleRate: Double) {
        self.url = url
        self.fileSize = fileSize
        self.duration = duration
        self.videoSize = videoSize
        self.frameRate = frameRate
        self.videoCodec = videoCodec
        self.videoBitrate = videoBitrate
        self.bitDepth = bitDepth
        self.isHDR = isHDR
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.hasAudio = hasAudio
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.audioSampleRate = audioSampleRate
    }
}

// MARK: - Encode plan

public enum HEVCProfile: Sendable {
    case main        // 8-bit SDR
    case main10      // 10-bit / HDR
}

public enum EncodeStrategy: Sendable {
    /// Already HEVC at acceptable bitrate -> stream-copy into MP4 with hvc1 tag.
    case remux
    /// Single-source full re-encode (AVAssetReader/Writer, hardware HEVC).
    case reencode
    /// Two or more sources sharing identical params -> AVMutableComposition (no re-encode).
    case mergeFast
    /// Two or more sources needing normalization (resize + pad + fps) -> reader/writer concat.
    case mergeNormalize(targetSize: CGSize, targetFrameRate: Int)
}

public struct EncodeRecipe: Sendable {
    public let strategy: EncodeStrategy
    public let hevcProfile: HEVCProfile
    public let quality: Float           // VideoToolbox Quality key, 0.0-1.0
    public let bitrateCap: Int64?       // bits/sec ceiling; nil for pure quality mode
    public let gopSeconds: Double       // keyframe interval; 2.0 default
    public let preserveHDR: Bool

    public let audioPassthrough: Bool
    public let audioBitrate: Int        // bps; used when re-encoding
    public let audioChannels: Int

    public init(strategy: EncodeStrategy, hevcProfile: HEVCProfile, quality: Float,
                bitrateCap: Int64?, gopSeconds: Double, preserveHDR: Bool,
                audioPassthrough: Bool, audioBitrate: Int, audioChannels: Int) {
        self.strategy = strategy
        self.hevcProfile = hevcProfile
        self.quality = quality
        self.bitrateCap = bitrateCap
        self.gopSeconds = gopSeconds
        self.preserveHDR = preserveHDR
        self.audioPassthrough = audioPassthrough
        self.audioBitrate = audioBitrate
        self.audioChannels = audioChannels
    }
}

// MARK: - Job model

public enum JobState: Sendable, Equatable {
    case queued
    case analyzing
    case encoding
    case done
    /// Encoded successfully but the result wasn't meaningfully smaller; we
    /// discarded the output and left the source untouched. The associated
    /// string is a short human explanation, e.g. "already well-compressed".
    case skipped(String)
    case failed(String)
    case cancelled
}

public enum JobKind: Sendable, Equatable {
    case single
    case merge
}

public struct JobProgress: Sendable, Equatable {
    public var fraction: Double         // 0.0...1.0
    public var etaSeconds: TimeInterval?
    public init(fraction: Double = 0, etaSeconds: TimeInterval? = nil) {
        self.fraction = fraction
        self.etaSeconds = etaSeconds
    }
}

public struct Job: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var kind: JobKind
    public var sources: [URL]
    public var displayName: String
    public var state: JobState
    public var progress: JobProgress
    public var outputURL: URL?
    public var bytesBefore: Int64
    public var bytesAfter: Int64?
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(id: UUID = UUID(), kind: JobKind, sources: [URL], displayName: String,
                state: JobState = .queued, progress: JobProgress = .init(),
                outputURL: URL? = nil, bytesBefore: Int64, bytesAfter: Int64? = nil,
                startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.sources = sources
        self.displayName = displayName
        self.state = state
        self.progress = progress
        self.outputURL = outputURL
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

// MARK: - Encoder contract

public protocol Encoder: Sendable {
    /// Runs the encode; reports progress 0...1. Returns output URL on success.
    func encode(
        sources: [URL],
        recipe: EncodeRecipe,
        outputURL: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL
}

public enum EncoderError: Error, LocalizedError {
    case unsupportedInput(String)
    case assetLoadFailed(URL)
    case writerSetupFailed(String)
    case readerSetupFailed(String)
    case encodeFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput(let s): return "Unsupported input: \(s)"
        case .assetLoadFailed(let u):  return "Couldn't open \(u.lastPathComponent)"
        case .writerSetupFailed(let s): return "Writer setup failed: \(s)"
        case .readerSetupFailed(let s): return "Reader setup failed: \(s)"
        case .encodeFailed(let s):     return "Encode failed: \(s)"
        case .cancelled:               return "Cancelled"
        }
    }
}
