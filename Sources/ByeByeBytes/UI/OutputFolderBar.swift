/// Persistent footer showing where encodes will be saved, with a Change button.

import SwiftUI
import AppKit

@MainActor
struct OutputFolderBar: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.dim)

            Text("Save to")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.dim)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([settings.outputDirectory])
            } label: {
                Text(settings.displayPath)
                    .font(Theme.Font.mono)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
            .accessibilityLabel("Output folder: \(settings.displayPath). Activate to reveal in Finder.")

            Spacer(minLength: 8)

            Button("Change…") {
                settings.promptForDirectory()
            }
            .secondaryGlassButton()
            .controlSize(.small)
            .accessibilityLabel("Change output folder")
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 10)
        .glassPanel()
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.primary.opacity(0.06)),
            alignment: .top
        )
    }
}
