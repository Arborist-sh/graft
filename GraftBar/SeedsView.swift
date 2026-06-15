import SwiftUI
import AppKit
import GraftCore

/// The Seeds section — edit `.graft` image recipes either as a structured **Form** (every
/// field, with add/remove blocks + a custom-script block) or as **Raw** YAML. The Form
/// round-trips through `ImageRecipe`, so a form-save rewrites clean YAML (comments not
/// preserved — Raw mode is the lossless escape hatch). Render previews the compiled
/// provisioning script; Grow builds the sapling.
struct SeedsView: View {
    @ObservedObject var config: ConfigStore
    @AppStorage(Vocabulary.storageKey) private var vocab: Vocabulary = .standard

    enum Mode: String { case form, raw }

    @State private var mode: Mode = .form
    @State private var text = ""
    @State private var form = RecipeForm()
    @State private var path: String?
    @State private var dirty = false
    @State private var rendering = false
    @State private var renderOutput = ""
    @State private var status: String?
    @State private var images: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                if mode == .form { formEditor } else { rawEditor }
            }
        }
        .task { images = await config.localImages() }
        .sheet(isPresented: $rendering) { RenderSheet(script: renderOutput) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(Lex.seeds(vocab)).font(.title2.weight(.semibold))
            Picker("", selection: Binding(get: { mode }, set: { switchMode(to: $0) })) {
                Text("Form").tag(Mode.form)
                Text("Raw").tag(Mode.raw)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            if let path {
                Text((path as NSString).lastPathComponent + (dirty ? " •" : "")).font(.caption).foregroundStyle(.secondary)
            } else if dirty {
                Text("untitled •").font(.caption).foregroundStyle(.secondary)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button { open() } label: { Label("Open…", systemImage: "folder") }
            Button { newFromTemplate() } label: { Label("New", systemImage: "doc.badge.plus") }
            Button { save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
            Button { render() } label: { Label("Render", systemImage: "eye") }
                .disabled(!config.graftAvailable)
            Button { grow() } label: { Label("Grow", systemImage: "hammer") }
                .buttonStyle(.borderedProminent).disabled(!config.graftAvailable)
        }
        .padding(16)
    }

    // MARK: Raw editor

    private var rawEditor: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .onChange(of: text) { dirty = true }
            .padding(8)
    }

    // MARK: Form editor

    private var formEditor: some View {
        Form {
            Section("Base") {
                TextField("Name", text: $form.name, prompt: Text("my-image"))
                LabeledContent("From") {
                    HStack(spacing: 6) {
                        TextField("", text: $form.from, prompt: Text("ghcr.io/cirruslabs/macos-sequoia-xcode:latest"))
                        if !images.isEmpty {
                            Menu("") { ForEach(images, id: \.self) { img in Button(img) { form.from = img } } }
                                .menuStyle(.borderlessButton).fixedSize().help("Pick a local image")
                        }
                    }
                }
                TextField("Description", text: $form.description, prompt: Text("optional"))
            }

            Section("Toolchain") {
                TextField("Xcode", text: $form.xcode, prompt: Text("e.g. 16.2"))
                TextField("Node", text: $form.node, prompt: Text("e.g. 20"))
                TextField("Ruby", text: $form.ruby, prompt: Text("e.g. 3.3.0"))
                TextField("Python", text: $form.python, prompt: Text("e.g. 3.12"))
                TextField("Java", text: $form.java, prompt: Text("e.g. 21"))
                TextField("Rust", text: $form.rust, prompt: Text("e.g. stable"))
                TextField("Package manager", text: $form.packageManager, prompt: Text("pnpm | yarn | bun"))
                TextField("CocoaPods", text: $form.cocoapods, prompt: Text("e.g. 1.15.2"))
                Toggle("Go", isOn: $form.go)
                Toggle("Fastlane", isOn: $form.fastlane)
                Toggle("Xcode first-launch", isOn: $form.xcodeFirstLaunch)
                StringListEditor(title: "Homebrew", items: $form.brew, prompt: "package")
                StringListEditor(title: "Gems", items: $form.gems, prompt: "gem")
                StringListEditor(title: "npm (global)", items: $form.npm, prompt: "package")
            }

            Section("Simulators") {
                StringListEditor(title: "Runtimes", items: $form.simulatorRuntimes, prompt: "iOS 18.2")
                StringListEditor(title: "Warm", items: $form.warmSimulators, prompt: "iPhone 16")
            }

            Section {
                TextEditor(text: $form.runScript)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.25)))
                TextField("Script file", text: $form.script, prompt: Text("path to a .sh (relative to the seed)"))
            } header: {
                Text("Custom script")
            } footer: {
                Text("`run:` — shell commands run after the compiled steps (one per line). `script:` runs a file first.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Caches") {
                Toggle("Warm CocoaPods spec repo", isOn: $form.podRepoWarm)
                Toggle("Cleanup (smaller image)", isOn: $form.cleanup)
                StringListEditor(title: "Prefetch", items: $form.prefetch, prompt: "command")
                StringListEditor(title: "Verify", items: $form.verify, prompt: "assertion (must exit 0)")
                RepoEditor(repos: $form.repos)
            }

            Section("System") {
                TextField("Git user", text: $form.gitUser, prompt: Text("optional"))
                TextField("Git email", text: $form.gitEmail, prompt: Text("optional"))
                TextField("Timezone", text: $form.timezone, prompt: Text("e.g. America/New_York"))
                TextField("Hostname", text: $form.hostname, prompt: Text("optional"))
                Toggle("Disable Spotlight", isOn: $form.disableSpotlight)
                Toggle("Disable sleep", isOn: $form.disableSleep)
                StringListEditor(title: "Known hosts", items: $form.knownHosts, prompt: "github.com")
                KVEditor(title: "Env", rows: $form.env)
                KVEditor(title: "Write files", rows: $form.write)
                KVEditor(title: "Labels", rows: $form.labels)
            }

            Section("VM shape & build") {
                TextField("CPU cores", text: $form.cpu, prompt: Text("optional"))
                TextField("Memory (MB)", text: $form.memory, prompt: Text("optional"))
                TextField("Disk (GB)", text: $form.disk, prompt: Text("optional · grow-only"))
                TextField("Display", text: $form.display, prompt: Text("WIDTHxHEIGHT"))
                Picker("Guest OS", selection: $form.os) {
                    Text("Default (macOS)").tag(GuestOS?.none)
                    Text("macOS").tag(GuestOS?.some(.macOS))
                    Text("Linux").tag(GuestOS?.some(.linux))
                }
                TextField("Build network", text: $form.network, prompt: Text("nat | bridged:en0 | softnet"))
            }
        }
        .formStyle(.grouped)
        .onChange(of: form) { dirty = true }
    }

    // MARK: Mode + sync

    private func switchMode(to new: Mode) {
        guard new != mode else { return }
        if new == .raw {
            syncFormToText()
            mode = .raw
        } else {
            if loadFormFromText() { mode = .form; status = nil }
            else { status = "Can't show the form — fix the YAML in Raw first."; mode = .raw }
        }
    }

    private func syncFormToText() {
        if let yaml = try? form.toRecipe().yamlString() { text = yaml }
    }

    @discardableResult
    private func loadFormFromText() -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { form = RecipeForm(); return true }
        guard let r = try? ImageRecipe.parse(text) else { return false }
        form = RecipeForm(from: r)
        return true
    }

    /// Make `text` current for save/render/grow regardless of mode.
    private func canonicalText() -> String {
        if mode == .form { syncFormToText() }
        return text
    }

    // MARK: Actions

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Open a .graft seed (also YAML / JSON)"
        guard panel.runModal() == .OK, let url = panel.url, let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = contents; path = url.path; dirty = false; status = nil
        if mode == .form, !loadFormFromText() {
            mode = .raw; status = "Opened in Raw — the form couldn't parse this YAML."
        }
    }

    private func newFromTemplate() {
        Task {
            let tmpl = await config.seedTemplate()
            text = tmpl.isEmpty ? "name: my-image\nfrom: ghcr.io/cirruslabs/macos-sequoia-xcode:latest\n" : tmpl
            path = nil; dirty = true; status = nil
            if mode == .form { _ = loadFormFromText() }
        }
    }

    @discardableResult
    private func save() -> Bool {
        let body = canonicalText()
        if path == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "image.graft"; panel.message = "Save the .graft seed"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            path = url.path
        }
        guard let p = path else { return false }
        do { try body.write(toFile: p, atomically: true, encoding: .utf8); dirty = false; status = "Saved."; return true }
        catch { status = "Couldn't save: \(error.localizedDescription)"; return false }
    }

    private func render() {
        let body = canonicalText()
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("graft-seed-\(UUID().uuidString).graft")
        try? body.write(toFile: tmp, atomically: true, encoding: .utf8)
        Task {
            renderOutput = await config.renderSeed(path: tmp)
            try? FileManager.default.removeItem(atPath: tmp)
            rendering = true
        }
    }

    private func grow() {
        guard save(), let p = path else { return }
        config.growSapling(seedPath: p)
        status = "Growing — watch the terminal; it'll appear in Saplings when done."
    }
}

// MARK: - Reusable editors

/// A growable list of single-line strings (brew packages, sim runtimes, prefetch, …).
struct StringListEditor: View {
    let title: String
    @Binding var items: [String]
    var prompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Button { items.append("") } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
            }
            ForEach(items.indices, id: \.self) { idx in
                HStack(spacing: 6) {
                    TextField(prompt, text: $items[idx])
                    Button { items.remove(at: idx) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A growable list of key/value rows (env, write, labels).
struct KVEditor: View {
    let title: String
    @Binding var rows: [KVRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Button { rows.append(KVRow()) } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
            }
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField("key", text: $row.key).frame(width: 150)
                    TextField("value", text: $row.value)
                    Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Precache repos — clone a repo at build time to warm global caches, source discarded.
struct RepoEditor: View {
    @Binding var repos: [RepoRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Precache repos").font(.subheadline)
                Spacer()
                Button { repos.append(RepoRow()) } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
            }
            ForEach($repos) { $repo in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TextField("repo URL", text: $repo.url)
                        TextField("ref", text: $repo.ref).frame(width: 90)
                        Button { repos.removeAll { $0.id == repo.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    TextField("ssh-key (guest path, for private repos)", text: $repo.sshKey)
                    TextEditor(text: $repo.run)
                        .font(.system(size: 11, design: .monospaced)).frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.2)))
                }
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
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
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            Divider()
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(16)
        }
        .frame(width: 620, height: 460)
    }
}
