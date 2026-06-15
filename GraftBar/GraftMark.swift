import SwiftUI
import AppKit

/// The graft mark as a tintable SwiftUI image — the same vector art (`GraftTemplate.pdf`)
/// the menu-bar icon uses, so the brand is consistent everywhere. Rendered as a template
/// so it takes `color` and adapts to light/dark. Falls back to an SF Symbol if the bundled
/// asset is ever missing.
struct GraftMark: View {
    var size: CGFloat = 34
    var color: Color = .secondary

    var body: some View {
        Group {
            if let mark = Self.template {
                Image(nsImage: mark)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Image(systemName: "leaf")
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(color)
    }

    private static let template: NSImage? = {
        guard let url = Bundle.main.url(forResource: "GraftTemplate", withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }()
}
