import Foundation

/// Tracks encode progress and computes a smoothed ETA.
///
/// Uses an exponential moving average (alpha = 0.3) over the raw
/// `(elapsed / fraction) - elapsed` estimate to damp out jitter from
/// encoder progress callbacks that don't arrive on a perfectly uniform
/// cadence.
///
/// ETA is suppressed (nil) while `fraction < 0.02` — too little signal
/// to produce a trustworthy number, and a wildly wrong ETA early on is
/// worse than no ETA.
public struct ProgressReporter: Sendable {

    private static let etaAlpha: Double = 0.3
    private static let minFractionForETA: Double = 0.02

    private let totalWeight: Double
    private var startTime: Date?
    private var smoothedETA: TimeInterval?
    private var lastFraction: Double = 0

    public init(totalWeight: Double = 1.0) {
        self.totalWeight = max(totalWeight, 0.0001)
    }

    /// Feed a new raw progress fraction (0...1, pre-weighting).
    /// Returns a `JobProgress` whose `fraction` is scaled by `totalWeight`
    /// and whose `etaSeconds` is the smoothed remaining time.
    public mutating func update(fraction: Double) -> JobProgress {
        let clamped = min(max(fraction, 0), 1)
        lastFraction = clamped

        let now = Date()
        if startTime == nil {
            startTime = now
        }

        let scaledFraction = clamped * totalWeight

        guard clamped >= Self.minFractionForETA, let start = startTime else {
            return JobProgress(fraction: scaledFraction, etaSeconds: nil)
        }

        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 0 else {
            return JobProgress(fraction: scaledFraction, etaSeconds: nil)
        }

        let rawETA = (elapsed / clamped) - elapsed
        if let prior = smoothedETA {
            smoothedETA = (Self.etaAlpha * rawETA) + ((1 - Self.etaAlpha) * prior)
        } else {
            smoothedETA = rawETA
        }

        return JobProgress(fraction: scaledFraction, etaSeconds: smoothedETA)
    }
}
