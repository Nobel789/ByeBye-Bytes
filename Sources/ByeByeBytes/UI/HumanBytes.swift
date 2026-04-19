/// Formatting helpers for byte counts and ETA durations.

import Foundation

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useKB, .useMB, .useGB]
    f.includesUnit = true
    return f
}()

public func humanBytes(_ n: Int64) -> String {
    byteFormatter.string(fromByteCount: max(0, n))
}

public func humanETA(_ seconds: TimeInterval?) -> String {
    guard let s = seconds, s.isFinite, s >= 0 else { return "—" }
    if s < 1 { return "<1s" }
    let total = Int(s.rounded())
    if total < 60 { return "\(total)s" }
    let m = total / 60
    let rem = total % 60
    if m < 60 { return rem == 0 ? "\(m)m" : "\(m)m \(rem)s" }
    let h = m / 60
    let mRem = m % 60
    return mRem == 0 ? "\(h)h" : "\(h)h \(mRem)m"
}

public func humanSavings(before: Int64, after: Int64) -> String {
    let b = humanBytes(before)
    let a = humanBytes(after)
    let pct: Int
    if before > 0 {
        let saved = Double(before - after) / Double(before)
        pct = Int((saved * 100).rounded())
    } else {
        pct = 0
    }
    return "\(b) → \(a), saved \(pct)%"
}
