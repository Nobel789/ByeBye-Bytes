/// Visual theme constants: palette, spacing, and typography shared across views.

import SwiftUI

public enum Theme {
    public static let corner: CGFloat = 14
    public static let pad: CGFloat = 16
    public static let rowMinHeight: CGFloat = 56
    public static let buttonMinHeight: CGFloat = 32

    public static let idleBg = Color(nsColor: .windowBackgroundColor)
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
