import Foundation
import AVFoundation
import CoreMedia
import CoreAudioTypes

/// Pure, deterministic planner: takes a SourceProfile (or several) and decides an EncodeRecipe.
/// No AVFoundation I/O here — everything is driven off the already-probed profile.
public enum SettingsResolver {

    // MARK: - Public API

    /// Chooses between remuxing an already-HEVC source and a full re-encode
    /// based on the source's container codec and observed bitrate.
    public static func resolve(single profile: SourceProfile) -> EncodeRecipe {
        // Already HEVC and within a sane bitrate envelope for its resolution? Remux, save time.
        if profile.videoCodec == kCMVideoCodecType_HEVC,
           bitrateIsReasonableHEVC(profile.videoBitrate, for: profile.videoSize) {
            return remuxRecipe(for: profile)
        }
        return reencodeRecipe(for: profile)
    }

    /// Picks a merge recipe. Falls through to `resolve(single:)` for a
    /// single-source list, picks the fast composition path when every input
    /// shares resolution/fps/codec/bit-depth/HDR, and otherwise normalizes
    /// to the largest common canvas. Requires at least one profile.
    public static func resolve(merge profiles: [SourceProfile]) -> EncodeRecipe {
        precondition(!profiles.isEmpty, "resolve(merge:) requires at least one source")

        if profiles.count == 1 {
            return resolve(single: profiles[0])
        }

        // Fast path: all sources are structurally identical -> AVMutableComposition concat.
        if canMergeFast(profiles) {
            let first = profiles[0]
            let hevcProfile: HEVCProfile = (first.bitDepth >= 10 || first.isHDR) ? .main10 : .main
            return EncodeRecipe(
                strategy: .mergeFast,
                hevcProfile: hevcProfile,
                quality: 0.70,
                bitrateCap: nil,
                gopSeconds: 2.0,
                preserveHDR: first.isHDR,
                audioPassthrough: audioIsPassthroughEligible(first),
                audioBitrate: audioBitrate(forChannels: first.audioChannels),
                audioChannels: min(max(first.audioChannels, 2), 6)
            )
        }

        // Slow path: normalize to the largest canvas.
        let maxWidth  = profiles.map { $0.videoSize.width  }.max() ?? 1920
        let maxHeight = profiles.map { $0.videoSize.height }.max() ?? 1080
        let targetSize = CGSize(width: maxWidth, height: maxHeight)

        let maxFps = profiles.map { $0.frameRate }.max() ?? 30
        let targetFrameRate = Int(max(1, (maxFps).rounded()))

        let anyWide = profiles.contains { $0.bitDepth >= 10 || $0.isHDR }
        let anyHDR  = profiles.contains { $0.isHDR }
        let hevcProfile: HEVCProfile = anyWide ? .main10 : .main

        // Bitrate cap: weighted by duration across sources; fall back to a formula if unknown.
        let cap = mergedBitrateCap(profiles: profiles, targetSize: targetSize, fps: Float(targetFrameRate))

        // Audio: if every source already passes the passthrough gate AND shares channel count,
        // we could in theory passthrough, but merging with re-encode is safer — force re-encode.
        let maxChannels = profiles.map { $0.audioChannels }.max() ?? 2
        let outChannels = min(max(maxChannels, 2), 6)

        return EncodeRecipe(
            strategy: .mergeNormalize(targetSize: targetSize, targetFrameRate: targetFrameRate),
            hevcProfile: hevcProfile,
            quality: 0.70,
            bitrateCap: cap,
            gopSeconds: 2.0,
            preserveHDR: anyHDR,
            audioPassthrough: false,
            audioBitrate: audioBitrate(forChannels: outChannels),
            audioChannels: outChannels
        )
    }

    // MARK: - Single-source recipes

    private static func remuxRecipe(for profile: SourceProfile) -> EncodeRecipe {
        let hevcProfile: HEVCProfile = (profile.bitDepth >= 10 || profile.isHDR) ? .main10 : .main
        return EncodeRecipe(
            strategy: .remux,
            hevcProfile: hevcProfile,
            quality: 0.70,      // unused on remux but kept valid
            bitrateCap: nil,
            gopSeconds: 2.0,
            preserveHDR: profile.isHDR,
            audioPassthrough: audioIsPassthroughEligible(profile),
            audioBitrate: audioBitrate(forChannels: profile.audioChannels),
            audioChannels: min(max(profile.audioChannels, profile.hasAudio ? 1 : 0), 6)
        )
    }

    private static func reencodeRecipe(for profile: SourceProfile) -> EncodeRecipe {
        let hevcProfile: HEVCProfile = (profile.bitDepth >= 10 || profile.isHDR) ? .main10 : .main

        let cap: Int64? = {
            guard let src = profile.videoBitrate else {
                // Source bitrate unknown — run pure quality mode; VT will pick a rate.
                return nil
            }
            // H.264 -> HEVC: HEVC is ~45% more efficient at equal quality, so 0.55× is a safe cap.
            // HEVC -> HEVC: we're re-encoding (out-of-range bitrate), so trim 15% to guarantee savings.
            if profile.videoCodec == kCMVideoCodecType_H264 {
                return Int64(Double(src) * 0.55)
            } else if profile.videoCodec == kCMVideoCodecType_HEVC {
                return Int64(Double(src) * 0.85)
            } else {
                // Unknown source codec — fall back to the H.264-style ratio off a default target.
                let target = defaultBitrate(for: profile.videoSize, fps: profile.frameRate)
                return Int64(Double(target))
            }
        }()

        return EncodeRecipe(
            strategy: .reencode,
            hevcProfile: hevcProfile,
            quality: 0.70,              // visually-lossless zone for VT HEVC
            bitrateCap: cap,
            gopSeconds: 2.0,
            preserveHDR: profile.isHDR,
            audioPassthrough: audioIsPassthroughEligible(profile),
            audioBitrate: audioBitrate(forChannels: profile.audioChannels),
            audioChannels: min(max(profile.audioChannels, profile.hasAudio ? 1 : 0), 6)
        )
    }

    // MARK: - Bitrate heuristics

    /// Reasonable HEVC bitrate envelope by resolution tier. Values in bits/sec.
    /// Tiers picked from common streaming ladders (Apple HLS authoring spec + Netflix public tables):
    ///   -  720p: 1.5 – 8 Mbps
    ///   - 1080p: 3   – 15 Mbps
    ///   -   4K : 10  – 60 Mbps
    /// Sources between tiers interpolate to the next-higher tier.
    public static func reasonableHEVCBitrate(for size: CGSize) -> ClosedRange<Int64> {
        let pixels = Int(size.width) * Int(size.height)
        // Thresholds (pixels): 720p ≈ 921_600, 1080p ≈ 2_073_600, 4K ≈ 8_294_400.
        if pixels <= 1_280 * 720 {
            return 1_500_000 ... 8_000_000
        } else if pixels <= 1_920 * 1_080 {
            return 3_000_000 ... 15_000_000
        } else if pixels <= 2_560 * 1_440 {
            // QHD sits between 1080p and 4K — widen the band.
            return 5_000_000 ... 25_000_000
        } else {
            // 4K and above.
            return 10_000_000 ... 60_000_000
        }
    }

    /// Very simple baseline: pixels × fps × 0.08 bits-per-pixel-per-frame. Tuned for H.264.
    /// HEVC recipes multiply this down with the 0.55 factor elsewhere.
    public static func defaultBitrate(for size: CGSize, fps: Float) -> Int64 {
        let pixels = Double(Int(size.width) * Int(size.height))
        let safeFps = fps > 0 ? Double(fps) : 30.0
        let raw = pixels * safeFps * 0.08
        return Int64(max(raw, 500_000))     // don't go below 500 kbps
    }

    private static func bitrateIsReasonableHEVC(_ bitrate: Int64?, for size: CGSize) -> Bool {
        guard let bitrate else {
            // Unknown bitrate on an HEVC source — trust it; remux is still the cheap win.
            return true
        }
        return reasonableHEVCBitrate(for: size).contains(bitrate)
    }

    private static func mergedBitrateCap(profiles: [SourceProfile], targetSize: CGSize, fps: Float) -> Int64? {
        // Duration-weighted mean of known source bitrates, then apply 0.55 H.264→HEVC haircut
        // if ANY source is H.264 (worst case wins).
        var weightedSum: Double = 0
        var totalSeconds: Double = 0
        var anyKnown = false
        var anyH264 = false

        for p in profiles {
            let secs = CMTimeGetSeconds(p.duration)
            guard secs.isFinite, secs > 0 else { continue }
            totalSeconds += secs
            if let b = p.videoBitrate {
                weightedSum += Double(b) * secs
                anyKnown = true
            }
            if p.videoCodec == kCMVideoCodecType_H264 { anyH264 = true }
        }

        if !anyKnown || totalSeconds <= 0 {
            // Nothing to go on — let VT run in quality mode.
            return nil
        }

        let mean = weightedSum / totalSeconds
        let ratio: Double = anyH264 ? 0.55 : 0.85
        let capped = mean * ratio

        // Clamp to the reasonable HEVC band for the output resolution so we never over-shoot.
        let band = reasonableHEVCBitrate(for: targetSize)
        let clamped = min(max(Int64(capped), band.lowerBound), band.upperBound)
        return clamped
    }

    // MARK: - Merge fast-path eligibility

    private static func canMergeFast(_ profiles: [SourceProfile]) -> Bool {
        guard let first = profiles.first else { return false }
        // Frame-rate match is tolerated to 0.01 fps — container fps can drift slightly.
        let fpsTolerance: Float = 0.01
        for p in profiles.dropFirst() {
            if p.videoSize != first.videoSize { return false }
            if abs(p.frameRate - first.frameRate) > fpsTolerance { return false }
            if p.videoCodec != first.videoCodec { return false }
            if p.bitDepth != first.bitDepth { return false }
            // HDR mismatch would require a colorimetry conversion — don't try to pass-through.
            if p.isHDR != first.isHDR { return false }
        }
        return true
    }

    // MARK: - Audio helpers

    /// AAC up through 5.1 is universally supported in MP4 and already well-compressed.
    private static func audioIsPassthroughEligible(_ profile: SourceProfile) -> Bool {
        guard profile.hasAudio, let codec = profile.audioCodec else { return false }
        return codec == kAudioFormatMPEG4AAC && profile.audioChannels <= 6 && profile.audioChannels > 0
    }

    /// 192 kbps stereo baseline; bump to 256 kbps when we have to carry more than two channels.
    public static func audioBitrate(forChannels channels: Int) -> Int {
        return channels > 2 ? 256_000 : 192_000
    }
}
