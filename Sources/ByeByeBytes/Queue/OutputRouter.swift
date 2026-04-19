import Foundation

/// Pure utility for picking a non-colliding output URL in a given directory.
/// Guarantees uniqueness by appending "-1", "-2", ... to the stem
/// until `FileManager.fileExists` returns false.
public enum OutputRouter {

    private static let outputExtension = "hevc.mp4"

    /// Unique URL for a single-source encode.
    public static func outputURL(forSingle sourceURL: URL, in directory: URL? = nil) -> URL {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        return uniqueURL(stem: stem, in: directory ?? defaultDirectory)
    }

    /// Unique URL for a merge of N clips.
    public static func outputURL(forMerge sources: [URL], in directory: URL? = nil) -> URL {
        let stem = "merged-\(sources.count)clips"
        return uniqueURL(stem: stem, in: directory ?? defaultDirectory)
    }

    // MARK: - Internals

    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    private static func uniqueURL(stem: String, in dir: URL) -> URL {
        let fm = FileManager.default
        let base = dir.appendingPathComponent("\(stem).\(outputExtension)")
        if !fm.fileExists(atPath: base.path) {
            return base
        }
        var suffix = 1
        while true {
            let candidate = dir.appendingPathComponent("\(stem)-\(suffix).\(outputExtension)")
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}
