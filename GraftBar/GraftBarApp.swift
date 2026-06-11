import SwiftUI
import AppKit

/// Graft Bar — the menu-bar companion to the `graft` daemon. Menu-bar only
/// (LSUIElement, no dock icon); built window-ready so a dashboard window can be
/// added later as another Scene.
@main
struct GraftBarApp: App {
    @StateObject private var controller = GraftController()

    var body: some Scene {
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
