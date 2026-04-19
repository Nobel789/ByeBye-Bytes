/// Availability-gated Liquid Glass helpers. On macOS 26 (Tahoe) these use
/// the native `.glassEffect` and `.glass*` button styles so surfaces pick up
/// dark/tinted/clear variants automatically. On earlier macOS they fall back
/// to the classic material and bordered button styles so the app still ships.

import SwiftUI

extension View {
    /// Prominent glass card — drop zone panel, decision banner.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = Theme.corner) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
        }
    }

    /// Lighter glass — active job rows, footer, strips.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 0) -> some View {
        if #available(macOS 26.0, *) {
            if cornerRadius > 0 {
                self.glassEffect(.regular,
                                 in: RoundedRectangle(cornerRadius: cornerRadius,
                                                      style: .continuous))
            } else {
                self.glassEffect(.regular, in: Rectangle())
            }
        } else {
            if cornerRadius > 0 {
                self.background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                )
            } else {
                self.background(.regularMaterial)
            }
        }
    }

    /// Tinted glass — state-coloured backgrounds (done green, failed amber).
    @ViewBuilder
    func tintedGlass(_ tint: Color, cornerRadius: CGFloat = Theme.corner) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint), in: shape)
        } else {
            self.background(shape.fill(tint.opacity(0.18)))
                .overlay(shape.fill(.ultraThinMaterial).opacity(0.5))
        }
    }

    /// Prominent Liquid-Glass button style with legacy fallback.
    @ViewBuilder
    func primaryGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Secondary Liquid-Glass button style with legacy fallback.
    @ViewBuilder
    func secondaryGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// A container that lets multiple `.glassEffect` surfaces blend correctly on
/// Tahoe. On older macOS it's a transparent pass-through.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}
