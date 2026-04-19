/// Persistent user preferences. Currently just the output directory.

import Foundation
import Combine
import AppKit

@MainActor
public final class AppSettings: ObservableObject {
    /// UserDefaults key for the persisted output directory path.
    private static let outputDirKey = "outputDirectoryPath"

    /// Current destination directory for encoded files. Persisted to
    /// UserDefaults whenever reassigned.
    @Published public var outputDirectory: URL {
        didSet { persist() }
    }

    /// Loads the saved output directory if one exists and still points to an
    /// accessible *directory*. Falls back to `defaultDirectory()` if the
    /// stored path is missing, unreadable, or resolves to a regular file.
    public init() {
        if let stored = UserDefaults.standard.string(forKey: Self.outputDirKey),
           Self.isUsableDirectory(atPath: stored) {
            self.outputDirectory = URL(fileURLWithPath: stored, isDirectory: true)
        } else {
            self.outputDirectory = Self.defaultDirectory()
        }
    }

    /// The system Downloads folder, with a hard-coded `~/Downloads` fallback
    /// for the extremely unlikely case that `FileManager` returns no URL.
    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads", isDirectory: true)
    }

    /// True only when the path exists AND is a directory. Guards against a
    /// stored setting that points to a plain file (possible if the user
    /// replaces the folder with a file of the same name on disk).
    private static func isUsableDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }

    /// Returns a friendly short form of the output directory, e.g. "~/Downloads",
    /// "~/Desktop/HEVC", or the bare path outside of $HOME.
    public var displayPath: String {
        let path = outputDirectory.path
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Opens an NSOpenPanel and, on confirm, assigns a new output directory.
    public func promptForDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should ByeBye Bytes save encoded videos?"
        panel.directoryURL = outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    private func persist() {
        UserDefaults.standard.set(outputDirectory.path, forKey: Self.outputDirKey)
    }
}
