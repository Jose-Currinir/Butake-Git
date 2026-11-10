import SwiftUI
import AppKit

/// Single entry point to bring back the main window, from the Dock, the notch or the floating panel.
/// Closing the window destroys it in SwiftUI; the notch panel stays visible, so AppKit believes the app
/// still has windows and never recreates it on its own.
@MainActor enum MainWindow {
    static let id = "main"
    /// Captured from the SwiftUI environment the first time the window appears; keeps working after it closes.
    static var openAction: OpenWindowAction?

    static var current: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true && !($0 is NSPanel) }
    }

    static func show() {
        NSApp.activate()
        if let window = current {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openAction?(id: id)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app keeps running with the notch after the window closes, like before the single-window scene.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The notch panel counts as a visible window, so the Dock click is handled here explicitly.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if MainWindow.current?.isVisible != true { MainActor.assumeIsolated { MainWindow.show() } }
        return false
    }
}

/// Stores the `openWindow` action so code outside SwiftUI views can reopen the main window.
struct MainWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { MainWindow.openAction = openWindow }
    }
}
