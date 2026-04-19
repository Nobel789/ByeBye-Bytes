/// Scrollable queue of JobRows with an inline multi-drop decision bar and a compact "drop more" strip.

import SwiftUI

@MainActor
struct QueueView: View {
    @ObservedObject var queue: JobQueue
    let isDropTargeted: Bool
    let onPick: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let pending = queue.pendingMultiDropURLs, pending.count > 1 {
                MultiDropDecisionBar(count: pending.count) {
                    queue.confirmBatch()
                } onMerge: {
                    queue.confirmMerge()
                }
                .padding(.horizontal, Theme.pad)
                .padding(.top, Theme.pad)
            }

            GlassGroup {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(queue.jobs) { job in
                            JobRow(job: job) {
                                queue.cancel(id: job.id)
                            }
                        }
                    }
                    .padding(Theme.pad)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            DropMoreStrip(isTargeted: isDropTargeted, onPick: onPick)
        }
    }
}

// MARK: - Inline decision bar

@MainActor
private struct MultiDropDecisionBar: View {
    let count: Int
    let onBatch: () -> Void
    let onMerge: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("You dropped \(count) files")
                    .font(Theme.Font.title)
                Text("Encode each as its own file, or merge into one?")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onMerge) {
                Text("Merge into one")
                    .padding(.horizontal, 14)
                    .frame(minHeight: Theme.buttonMinHeight)
            }
            .secondaryGlassButton()

            Button(action: onBatch) {
                Text("Encode each")
                    .padding(.horizontal, 14)
                    .frame(minHeight: Theme.buttonMinHeight)
            }
            .primaryGlassButton()
            .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.pad)
        .glassCard()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

// MARK: - Bottom "drop more" strip

private struct DropMoreStrip: View {
    let isTargeted: Bool
    let onPick: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .foregroundStyle(tint)
                Text("Drop or click to add more videos")
                    .font(Theme.Font.caption)
                    .foregroundStyle(tint)
                Spacer()
                Text("⌘O")
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, Theme.pad)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .glassPanel()
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Theme.subtle),
            alignment: .top
        )
        .background(isTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    private var tint: Color {
        if isTargeted || isHovering { return Color.accentColor }
        return Theme.dim
    }
}
