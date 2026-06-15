import SwiftUI
import AppKit

/// Graft — the desktop + menu-bar companion to the `graft` daemon. A full **Dashboard
/// window** (mission control) plus a **menu-bar extra** for quick start/stop, both driven
/// by one shared `GraftController`.
@main
struct GraftBarApp: App {
    @StateObject private var controller = GraftController()

    var body: some Scene {
        // The main window — a sidebar app (Dashboard + config sections). Single window
        // (reopen from the Dock or Window menu); shares the controller with the menu-bar
        // extra below.
        Window("Graft", id: "dashboard") {
            RootView(controller: controller)
        }
        .defaultSize(width: 860, height: 520)

        // Quick controls without leaving whatever you're doing.
        MenuBarExtra {
            MenuContentView(controller: controller)
        } label: {
            if let icon = Self.menuIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "leaf")
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// The graft mark as a template image — macOS tints it for the light/dark bar.
    static let menuIcon: NSImage? = {
        guard
            let url = Bundle.main.url(forResource: "GraftTemplate", withExtension: "pdf"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
