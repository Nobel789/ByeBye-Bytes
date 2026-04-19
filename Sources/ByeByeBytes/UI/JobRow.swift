/// One row in the queue list representing a single Job with state-specific affordances.

import SwiftUI
import AppKit

@MainActor
struct JobRow: View {
    let job: Job
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            leadingIcon
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayName)
                    .font(Theme.Font.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(primaryTextColor)

                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingControl
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 10)
        .frame(minHeight: Theme.rowMinHeight)
        .modifier(RowBackground(state: job.state))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if case .done = job.state, let url = job.outputURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Leading icon

    @ViewBuilder
    private var leadingIcon: some View {
        switch job.state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.doneGreen)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.warnAmber)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(Theme.dim)
        case .skipped:
            Image(systemName: "checkmark.seal")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        default:
            Image(systemName: job.kind == .merge ? "rectangle.stack" : "film")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Status line (below filename)

    @ViewBuilder
    private var statusLine: some View {
        switch job.state {
        case .queued:
            Text("Queued")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.dim)

        case .analyzing:
            AnalyzingBar(reduceMotion: reduceMotion)

        case .encoding:
            EncodingBar(progress: job.progress)

        case .done:
            HStack(spacing: 6) {
                if let after = job.bytesAfter {
                    Text(humanSavings(before: job.bytesBefore, after: after))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.doneGreen)
                } else {
                    Text("Done")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.doneGreen)
                }
                Text("· Click to reveal")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.dim)
            }

        case .failed(let msg):
            Text(msg)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.warnAmber)
                .lineLimit(2)

        case .cancelled:
            Text("Cancelled")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.dim)
                .strikethrough(true)

        case .skipped(let reason):
            HStack(spacing: 6) {
                Text("Already optimized")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                Text("· \(reason) · kept original")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    // MARK: Trailing control

    @ViewBuilder
    private var trailingControl: some View {
        switch job.state {
        case .queued, .analyzing, .encoding:
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Theme.subtle)
                    .clipShape(Circle())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
            .help("Cancel")

        case .done:
            Button {
                if let url = job.outputURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text("Reveal")
                }
                .font(Theme.Font.caption)
                .padding(.horizontal, 4)
            }
            .secondaryGlassButton()
            .controlSize(.small)
            .accessibilityLabel("Reveal in Finder")

        case .failed, .cancelled, .skipped:
            EmptyView()
        }
    }

    // MARK: Styling

    private var primaryTextColor: Color {
        switch job.state {
        case .cancelled: return Theme.dim
        case .queued:    return .primary.opacity(0.75)
        default:         return .primary
        }
    }

    private var accessibilityLabel: String {
        let base = job.displayName
        switch job.state {
        case .queued: return "\(base), queued"
        case .analyzing: return "\(base), analyzing"
        case .encoding:
            let pct = Int((job.progress.fraction * 100).rounded())
            return "\(base), encoding \(pct) percent, ETA \(humanETA(job.progress.etaSeconds))"
        case .done:
            if let a = job.bytesAfter {
                return "\(base), done, \(humanSavings(before: job.bytesBefore, after: a))"
            }
            return "\(base), done"
        case .failed(let m): return "\(base), failed: \(m)"
        case .cancelled: return "\(base), cancelled"
        case .skipped(let reason): return "\(base), already optimized, \(reason)"
        }
    }
}

// MARK: - Sub-views

/// Per-state glass background. All rows share a neutral glass surface; state
/// is signalled by a thin colored accent stripe on the leading edge plus the
/// icon + status-line colors. Keeps text legible across appearances.
private struct RowBackground: ViewModifier {
    let state: JobState

    func body(content: Content) -> some View {
        content
            .glassPanel(cornerRadius: Theme.corner)
            .overlay(alignment: .leading) {
                if let color = accentColor {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color)
                        .frame(width: 3)
                        .padding(.vertical, 10)
                        .padding(.leading, 2)
                }
            }
    }

    private var accentColor: Color? {
        switch state {
        case .done:                 return Theme.doneGreen
        case .failed:               return Theme.warnAmber
        case .encoding, .analyzing: return .accentColor
        case .skipped, .cancelled, .queued: return nil
        }
    }
}

private struct EncodingBar: View {
    let progress: JobProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: max(0, min(1, progress.fraction)))
                .progressViewStyle(.linear)
                .tint(.accentColor)
            HStack(spacing: 8) {
                Text("\(Int((progress.fraction * 100).rounded()))%")
                    .font(Theme.Font.mono)
                    .foregroundStyle(.secondary)
                Text("· ETA \(humanETA(progress.etaSeconds))")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.dim)
            }
        }
    }
}

private struct AnalyzingBar: View {
    let reduceMotion: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        if reduceMotion {
            Text("Analyzing…")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
        } else {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.subtle)
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: max(40, geo.size.width * 0.25), height: 4)
                        .offset(x: phase)
                }
                .onAppear {
                    let travel = geo.size.width - max(40, geo.size.width * 0.25)
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                        phase = travel
                    }
                }
            }
            .frame(height: 4)
        }
    }
}
