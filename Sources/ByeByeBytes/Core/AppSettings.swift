/// Persistent user preferences. Currently just the output directory.

import Foundation
import Combine
import AppKit

@MainActor
public final class AppSettings: ObservableObject {
    private static let outputDirKey = "outputDirectoryPath"

    @Published public var outputDirectory: URL {
        didSet { persist() }
    }

    public init() {
        if let stored = UserDefaults.standard.string(forKey: Self.outputDirKey),
           FileManager.default.isWritableFile(atPath: stored) || FileManager.default.fileExists(atPath: stored) {
            self.outputDirectory = URL(fileURLWithPath: stored, isDirectory: true)
        } else {
            self.outputDirectory = Self.defaultDirectory()
        }
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads", isDirectory: true)
    }

    public func resetToDefault() {
        outputDirectory = Self.defaultDirectory()
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
