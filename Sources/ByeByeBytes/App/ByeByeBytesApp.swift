/// App entry point: owns shared AppSettings + JobQueue and hosts RootView.

import SwiftUI

@main
struct ByeByeBytesApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var queue: JobQueue

    /// We initialize both state objects from a single `AppSettings` instance
    /// so `JobQueue` holds the *same* reference the UI observes — otherwise
    /// a user-changed output directory wouldn't flow through to new jobs.
    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _queue = StateObject(wrappedValue: JobQueue(settings: s))
    }

    var body: some Scene {
        WindowGroup("ByeBye Bytes") {
            RootViewHost {
                RootView(queue: queue, settings: settings)
                    .frame(minWidth: 620, minHeight: 480)
            }
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// Availability-gated host that sets a window-level material background on
/// macOS 15+ (where `containerBackground(.windowBackground, for: .window)`
/// is available) and passes through on 14.
private struct RootViewHost<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(.windowBackground, for: .window)
        } else {
            content
        }
    }
}
