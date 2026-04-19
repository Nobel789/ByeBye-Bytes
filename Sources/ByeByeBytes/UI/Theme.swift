/// Visual theme constants (palette, spacing, typography) plus a reduce-motion helper.

import SwiftUI

public enum Theme {
    public static let corner: CGFloat = 14
    public static let pad: CGFloat = 16
    public static let rowMinHeight: CGFloat = 56
    public static let buttonMinHeight: CGFloat = 32

    public static let idleBg = Color(nsColor: .windowBackgroundColor)
    public static let activeBg = Color(nsColor: .controlBackgroundColor)
    public static let subtle = Color.secondary.opacity(0.12)
    public static let dim = Color.secondary.opacity(0.6)

    public static let doneGreen = Color(red: 0.36, green: 0.72, blue: 0.46)
    public static let warnAmber = Color(red: 0.92, green: 0.66, blue: 0.24)

    public enum Font {
        public static let display = SwiftUI.Font.system(size: 22, weight: .semibold, design: .rounded)
        public static let title = SwiftUI.Font.system(size: 16, weight: .semibold)
        public static let body = SwiftUI.Font.system(size: 13)
        public static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        public static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
    }
}

/// Reads `\.accessibilityReduceMotion` and exposes the bool to a closure-based view builder.
public struct ReduceMotionReader<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: (Bool) -> Content

    public init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    public var body: some View {
        content(reduceMotion)
    }
}
