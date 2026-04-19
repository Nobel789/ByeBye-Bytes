/// Scrollable queue of JobRows with an inline multi-drop decision bar and a compact "drop more" strip.

import SwiftUI

@MainActor
struct QueueView: View {
    @ObservedObject var queue: JobQueue
    let isDropTargeted: Bool
    let onPick: () -> Void

    /// True when at least one job has reached a terminal state that the
    /// "Clear" affordance can remove.
    private var hasCompleted: Bool {
        queue.jobs.contains { job in
            switch job.state {
            case .done, .failed, .cancelled, .skipped: return true
            case .queued, .analyzing, .encoding:       return false
            }
        }
    }

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

            DropMoreStrip(
                isTargeted: isDropTargeted,
                hasCompleted: hasCompleted,
                onPick: onPick,
                onClear: { queue.clearCompleted() }
            )
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
    let hasCompleted: Bool
    let onPick: () -> Void
    let onClear: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Left portion: the primary drop/click affordance. Own Button so
            // the Clear pill on the right can be tapped without triggering it.
            Button(action: onPick) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .foregroundStyle(tint)
                    Text("Drop or click to add more videos")
                        .font(Theme.Font.caption)
                        .foregroundStyle(tint)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add more videos")
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            if hasCompleted {
                Button(action: onClear) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                        Text("Clear")
                    }
                    .font(Theme.Font.caption)
                }
                .secondaryGlassButton()
                .controlSize(.small)
                .help("Clear finished jobs and return to the drop zone")
                .accessibilityLabel("Clear finished jobs")
            }

            Text("⌘O")
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 10)
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
