import SwiftUI
import AppKit
import GraftCore

/// The Seeds section — a lightweight editor for `.graft` image recipes. Open/edit/save a
/// seed, start from a template, preview the provisioning script it compiles to (Render), or
/// grow a sapling from it. A `.graft` is YAML/JSON, so this is a plain text editor with the
/// graft CLI wired in for template/render/grow — not a structured form (the schema is big).
struct SeedsView: View {
    @ObservedObject var config: ConfigStore
    @AppStorage(Vocabulary.storageKey) private var vocab: Vocabulary = .standard

    @State private var text = ""
    @State private var path: String?
    @State private var dirty = false
    @State private var rendering = false
    @State private var renderOutput = ""
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            editor
        }
        .sheet(isPresented: $rendering) {
            RenderSheet(script: renderOutput)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(Lex.seeds(vocab)).font(.title2.weight(.semibold))
            if let path {
                Text((path as NSString).lastPathComponent + (dirty ? " •" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            } else if dirty {
                Text("untitled •").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { open() } label: { Label("Open…", systemImage: "folder") }
            Button { newFromTemplate() } label: { Label("New", systemImage: "doc.badge.plus") }
            Button { save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .disabled(text.isEmpty)
            Button { render() } label: { Label("Render", systemImage: "eye") }
                .disabled(text.isEmpty || !config.graftAvailable)
                .help(config.graftAvailable ? "Preview the provisioning script this compiles to" : "Install the graft CLI")
            Button { grow() } label: { Label("Grow", systemImage: "hammer") }
                .buttonStyle(.borderedProminent)
                .disabled(text.isEmpty || !config.graftAvailable)
                .help(config.graftAvailable ? "Save + build a sapling from this seed" : "Install the graft CLI")
        }
        .padding(16)
    }

    @ViewBuilder
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .onChange(of: text) { dirty = true }
                .padding(8)
            if text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open a .graft seed, or hit New for a starter template.")
                        .foregroundStyle(.secondary)
                    if !config.graftAvailable {
                        Text("Install the graft CLI for New / Render / Grow.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(16)
                .allowsHitTesting(false)
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .padding(8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Actions

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Open a .graft seed (also YAML / JSON)"
        guard panel.runModal() == .OK, let url = panel.url,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = contents
        path = url.path
        dirty = false
        status = nil
    }

    private func newFromTemplate() {
        Task {
            let tmpl = await config.seedTemplate()
            text = tmpl.isEmpty ? "name: my-image\nfrom: ghcr.io/cirruslabs/macos-sequoia-xcode:latest\n" : tmpl
            path = nil
            dirty = true
            status = nil
        }
    }

    @discardableResult
    private func save() -> Bool {
        if path == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "image.graft"
            panel.message = "Save the .graft seed"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            path = url.path
        }
        guard let p = path else { return false }
        do { try text.write(toFile: p, atomically: true, encoding: .utf8); dirty = false; status = "Saved."; return true }
        catch { status = "Couldn't save: \(error.localizedDescription)"; return false }
    }

    private func render() {
        // Render the *current* editor content via a temp file, so it works while unsaved.
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("graft-seed-\(UUID().uuidString).graft")
        try? text.write(toFile: tmp, atomically: true, encoding: .utf8)
        Task {
            renderOutput = await config.renderSeed(path: tmp)
            try? FileManager.default.removeItem(atPath: tmp)
            rendering = true
        }
    }

    private func grow() {
        guard save(), let p = path else { return }   // grow builds from a real file
        config.growSapling(seedPath: p)
        status = "Growing — watch the terminal; it'll appear in Saplings when done."
    }
}

/// Read-only preview of the provisioning script a seed compiles to.
struct RenderSheet: View {
    let script: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Compiled provisioning").font(.headline).padding(16)
            Divider()
            ScrollView {
                Text(script.isEmpty ? "(nothing)" : script)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(16)
        }
        .frame(width: 620, height: 460)
    }
}
