/// Empty-state drop affordance.

import SwiftUI

struct DropZoneView: View {
    let isTargeted: Bool
    let onPick: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var float: CGFloat = 0
    @State private var isHovering = false

    var body: some View {
        ZStack {
            // Subtle tinted radial wash so the empty window feels alive.
            RadialGradient(
                colors: [Color.accentColor.opacity(isTargeted ? 0.22 : 0.10), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 540
            )
            .ignoresSafeArea()

            GlassGroup {
                Button(action: onPick) {
                    VStack(spacing: 22) {
                        hero
                        copyBlock
                        clickHint
                        featurePills
                    }
                    .frame(maxWidth: 520)
                    .padding(Theme.pad * 2)
                    .glassCard(cornerRadius: Theme.corner * 1.75)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner * 1.75, style: .continuous)
                            .strokeBorder(
                                strokeColor,
                                style: StrokeStyle(
                                    lineWidth: isTargeted ? 2.5 : (isHovering ? 1.6 : 1.0),
                                    dash: isTargeted ? [] : [7, 5]
                                )
                            )
                    )
                    .shadow(color: .black.opacity(isHovering ? 0.14 : 0.10),
                            radius: isHovering ? 34 : 28, y: 10)
                    .scaleEffect(isHovering && !reduceMotion ? 1.01 : 1.0)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHovering = hovering
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .padding(Theme.pad * 2)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isTargeted)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop one or more videos, or click to choose files. Multiple videos can be merged into one.")
        .accessibilityAddTraits(.isButton)
    }

    private var strokeColor: Color {
        if isTargeted { return Color.accentColor }
        if isHovering { return Color.accentColor.opacity(0.45) }
        return Color.primary.opacity(0.08)
    }

    // MARK: Sections

    private var hero: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(isTargeted ? 0.28 : 0.14))
                .frame(width: 140, height: 140)
                .blur(radius: 18)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 84, height: 58)
                    .offset(x: -16, y: 10)
                    .rotationEffect(.degrees(-6))

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(width: 84, height: 58)
                    .offset(x: 0, y: 2)
                    .rotationEffect(.degrees(2))

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.75)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 84, height: 58)
                    .overlay(
                        Image(systemName: "arrow.down")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: 14, y: -6)
                    .rotationEffect(.degrees(8))
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 8, y: 3)
            }
            .offset(y: float)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    float = -4
                }
            }
        }
        .frame(height: 150)
    }

    private var copyBlock: some View {
        VStack(spacing: 10) {
            Text("Drop videos here")
                .font(Theme.Font.display)
                .foregroundStyle(.primary)

            VStack(spacing: 4) {
                Text("**One** video → a smaller H.265 copy.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.primary.opacity(0.85))
                Text("**Two or more** → encode each, or merge into one.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.primary.opacity(0.85))
            }
            .multilineTextAlignment(.center)
        }
    }

    private var clickHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "cursorarrow.click")
                .font(.system(size: 10, weight: .semibold))
            Text("…or click anywhere to choose files")
                .font(Theme.Font.caption)
        }
        .foregroundStyle(Theme.dim)
    }

    private var featurePills: some View {
        HStack(spacing: 8) {
            Pill(icon: "cpu", text: "Apple Silicon")
            Pill(icon: "bolt.fill", text: "Hardware HEVC")
            Pill(icon: "slider.horizontal.3", text: "No settings")
        }
    }
}

// MARK: - Pill

private struct Pill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassPanel(cornerRadius: 999)
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
