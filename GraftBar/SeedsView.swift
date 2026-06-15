import SwiftUI
import AppKit
import GraftCore

/// The Seeds section — build a `.graft` image recipe as a **builder** (start with name/from,
/// "+ Add" only the components you want — Add toolchain → Python, add as many custom scripts
/// or sims as you like) or edit the **Raw** YAML. The Form round-trips through `ImageRecipe`,
/// so a form-save rewrites clean YAML (Raw is the lossless escape hatch). Render previews the
/// compiled provisioning script; Grow builds the sapling.
struct SeedsView: View {
    @ObservedObject var config: ConfigStore
    /// Persists the editor's content across section switches (the view itself is destroyed
    /// when you navigate away, so its @State would reset — this holds the snapshot).
    let store: SeedEditorModel
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
    @State private var inspecting = false
    @State private var showInspect = false
    @State private var inspectOutput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group { if mode == .form { formEditor } else { rawEditor } }
        }
        .task { images = await config.localImages() }
        .onAppear { restore() }
        .onDisappear { snapshot() }
        .sheet(isPresented: $rendering) { RenderSheet(script: renderOutput) }
        .sheet(isPresented: $showInspect) { InspectSheet(image: form.from, report: inspectOutput) }
    }

    /// Restore the editor from the persisted snapshot when returning to this section.
    private func restore() {
        guard store.loaded else { return }
        mode = store.mode; text = store.text; form = store.form
        path = store.path; dirty = store.dirty; status = store.status
    }

    /// Snapshot the editor when leaving the section, so coming back resumes where you were.
    private func snapshot() {
        store.mode = mode; store.text = text; store.form = form
        store.path = path; store.dirty = dirty; store.status = status
        store.loaded = true
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(Lex.seeds(vocab)).font(.title2.weight(.semibold))
            Picker("", selection: Binding(get: { mode }, set: { switchMode(to: $0) })) {
                Text("Builder").tag(Mode.form); Text("Raw").tag(Mode.raw)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            if let path { Text((path as NSString).lastPathComponent + (dirty ? " •" : "")).font(.caption).foregroundStyle(.secondary) }
            else if dirty { Text("untitled •").font(.caption).foregroundStyle(.secondary) }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button { open() } label: { Label("Open…", systemImage: "folder") }
            Button { newDoc() } label: { Label("New", systemImage: "doc.badge.plus") }
            Button { save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
            Button { render() } label: { Label("Render", systemImage: "eye") }.disabled(!config.graftAvailable)
            Button { grow() } label: { Label("Grow", systemImage: "hammer") }
                .buttonStyle(.borderedProminent).disabled(!config.graftAvailable)
        }
        .padding(16)
    }

    private var rawEditor: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .onChange(of: text) { dirty = true }
            .padding(8)
    }

    // MARK: Builder

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
                        Button { inspect() } label: {
                            if inspecting { ProgressView().controlSize(.small) } else { Image(systemName: "magnifyingglass") }
                        }
                        .buttonStyle(.borderless)
                        .disabled(inspecting || !config.graftAvailable || form.from.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Boot this image and see what's already installed (~1 min)")
                    }
                }
            }

            ForEach(Comp.Category.allCases, id: \.self) { cat in
                let comps = Comp.allCases.filter { $0.category == cat && form.active.contains($0) }
                if !comps.isEmpty {
                    Section(cat.rawValue) { ForEach(comps) { comp in compView(comp) } }
                }
            }

            Section { addMenu }
        }
        .formStyle(.grouped)
        .onChange(of: form) { dirty = true }
    }

    private var addMenu: some View {
        Menu {
            ForEach(Comp.Category.allCases, id: \.self) { cat in
                let avail = Comp.allCases.filter { $0.category == cat && !form.active.contains($0) }
                if !avail.isEmpty {
                    Menu(cat.rawValue) { ForEach(avail) { comp in Button(comp.title) { add(comp) } } }
                }
            }
        } label: { Label("Add component", systemImage: "plus.circle.fill") }
    }

    @ViewBuilder
    private func compView(_ comp: Comp) -> some View {
        switch comp {
        case .xcode: fieldRow(comp, $form.xcode, "e.g. 16.2", suggestions: Self.versions(comp))
        case .node: fieldRow(comp, $form.node, "e.g. 20", suggestions: Self.versions(comp))
        case .ruby: fieldRow(comp, $form.ruby, "e.g. 3.3.0", suggestions: Self.versions(comp))
        case .python: fieldRow(comp, $form.python, "e.g. 3.12", suggestions: Self.versions(comp))
        case .java: fieldRow(comp, $form.java, "e.g. 21", suggestions: Self.versions(comp))
        case .rust: fieldRow(comp, $form.rust, "e.g. stable", suggestions: Self.versions(comp))
        case .packageManager: fieldRow(comp, $form.packageManager, "pnpm | yarn | bun", suggestions: Self.versions(comp))
        case .cocoapods: fieldRow(comp, $form.cocoapods, "e.g. 1.15.2", suggestions: Self.versions(comp))
        case .go, .fastlane, .xcodeFirstLaunch, .podRepoWarm, .cleanup, .disableSpotlight, .disableSleep:
            flagRow(comp)
        case .brew: StringListEditor(title: comp.title, items: $form.brew, prompt: "package", onRemoveBlock: { form.remove(comp) })
        case .gems: StringListEditor(title: comp.title, items: $form.gems, prompt: "gem", onRemoveBlock: { form.remove(comp) })
        case .npm: StringListEditor(title: comp.title, items: $form.npm, prompt: "package", onRemoveBlock: { form.remove(comp) })
        case .simulatorRuntimes: StringListEditor(title: comp.title, items: $form.simulatorRuntimes, prompt: "iOS 18.2", onRemoveBlock: { form.remove(comp) })
        case .warmSimulators: StringListEditor(title: comp.title, items: $form.warmSimulators, prompt: "iPhone 16", onRemoveBlock: { form.remove(comp) })
        case .knownHosts: StringListEditor(title: comp.title, items: $form.knownHosts, prompt: "github.com", onRemoveBlock: { form.remove(comp) })
        case .prefetch: StringListEditor(title: comp.title, items: $form.prefetch, prompt: "command", onRemoveBlock: { form.remove(comp) })
        case .verify: StringListEditor(title: comp.title, items: $form.verify, prompt: "assertion (exit 0)", onRemoveBlock: { form.remove(comp) })
        case .scripts: ScriptsEditor(scripts: $form.scripts, onRemoveBlock: { form.remove(comp) })
        case .scriptFile: fieldRow(comp, $form.scriptFile, "path to a .sh (relative to the seed)")
        case .repos: RepoEditor(repos: $form.repos, onRemoveBlock: { form.remove(comp) })
        case .env: KVEditor(title: comp.title, rows: $form.env, onRemoveBlock: { form.remove(comp) })
        case .write: KVEditor(title: comp.title, rows: $form.write, onRemoveBlock: { form.remove(comp) })
        case .labels: KVEditor(title: comp.title, rows: $form.labels, onRemoveBlock: { form.remove(comp) })
        case .git:
            blockGroup(comp) { TextField("Git user", text: $form.gitUser); TextField("Git email", text: $form.gitEmail) }
        case .timezone: fieldRow(comp, $form.timezone, "America/New_York")
        case .hostname: fieldRow(comp, $form.hostname, "optional")
        case .description: fieldRow(comp, $form.description, "optional")
        case .vmShape:
            blockGroup(comp) {
                TextField("CPU cores", text: $form.cpu, prompt: Text("optional"))
                TextField("Memory (MB)", text: $form.memory, prompt: Text("optional"))
                TextField("Disk (GB)", text: $form.disk, prompt: Text("grow-only"))
                TextField("Display", text: $form.display, prompt: Text("WIDTHxHEIGHT"))
            }
        case .os:
            LabeledContent(comp.title) {
                HStack(spacing: 6) {
                    Picker("", selection: $form.os) { Text("macOS").tag(GuestOS.macOS); Text("Linux").tag(GuestOS.linux) }
                        .labelsHidden().fixedSize()
                    Spacer(); removeX(comp)
                }
            }
        case .network: fieldRow(comp, $form.network, "nat | bridged:en0 | softnet")
        }
    }

    // MARK: Builder helpers

    private func fieldRow(_ comp: Comp, _ binding: Binding<String>, _ prompt: String, suggestions: [String] = []) -> some View {
        LabeledContent(comp.title) {
            HStack(spacing: 6) {
                TextField("", text: binding, prompt: Text(prompt))
                if !suggestions.isEmpty {
                    Menu("") { ForEach(suggestions, id: \.self) { v in Button(v) { binding.wrappedValue = v } } }
                        .menuStyle(.borderlessButton).fixedSize().help("Common versions")
                }
                removeX(comp)
            }
        }
    }

    /// Curated common versions for the dropdown — still freely typeable for anything else.
    /// (Static, not live: the real catalogs live in the guest's xcodes/fnm/rbenv/pyenv.)
    static func versions(_ comp: Comp) -> [String] {
        switch comp {
        case .xcode: ["16.2", "16.1", "16.0", "15.4", "15.3"]
        case .node: ["22", "20", "18", "latest"]
        case .ruby: ["3.4.1", "3.3.6", "3.2.6", "3.1.6"]
        case .python: ["3.13", "3.12", "3.11", "3.10"]
        case .java: ["21", "17", "11"]
        case .rust: ["stable", "nightly", "beta"]
        case .cocoapods: ["1.16.2", "1.15.2", "1.14.3"]
        case .packageManager: ["pnpm", "yarn", "bun"]
        default: []
        }
    }

    private func flagRow(_ comp: Comp) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(comp.title); Spacer(); removeX(comp)
        }
    }

    private func blockGroup<Content: View>(_ comp: Comp, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(comp.title).font(.subheadline.weight(.medium)); Spacer(); removeX(comp) }
            content()
        }
        .padding(.vertical, 2)
    }

    private func removeX(_ comp: Comp) -> some View {
        Button { form.remove(comp) } label: { Image(systemName: "minus.circle.fill") }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove \(comp.title)")
    }

    private func add(_ c: Comp) {
        form.active.insert(c)
        switch c {
        case .brew where form.brew.isEmpty: form.brew = [""]
        case .gems where form.gems.isEmpty: form.gems = [""]
        case .npm where form.npm.isEmpty: form.npm = [""]
        case .simulatorRuntimes where form.simulatorRuntimes.isEmpty: form.simulatorRuntimes = [""]
        case .warmSimulators where form.warmSimulators.isEmpty: form.warmSimulators = [""]
        case .knownHosts where form.knownHosts.isEmpty: form.knownHosts = [""]
        case .prefetch where form.prefetch.isEmpty: form.prefetch = [""]
        case .verify where form.verify.isEmpty: form.verify = [""]
        case .scripts where form.scripts.isEmpty: form.scripts = [ScriptRow()]
        case .repos where form.repos.isEmpty: form.repos = [RepoRow()]
        case .env where form.env.isEmpty: form.env = [KVRow()]
        case .write where form.write.isEmpty: form.write = [KVRow()]
        case .labels where form.labels.isEmpty: form.labels = [KVRow()]
        default: break
        }
    }

    // MARK: Mode + sync

    private func switchMode(to new: Mode) {
        guard new != mode else { return }
        if new == .raw { syncFormToText(); mode = .raw }
        else if loadFormFromText() { mode = .form; status = nil }
        else { status = "Can't show the builder — fix the YAML in Raw first." }
    }

    private func syncFormToText() { if let yaml = try? form.toRecipe().yamlString() { text = yaml } }

    @discardableResult
    private func loadFormFromText() -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { form = RecipeForm(); return true }
        guard let r = try? ImageRecipe.parse(text) else { return false }
        form = RecipeForm(from: r); return true
    }

    private func canonicalText() -> String { if mode == .form { syncFormToText() }; return text }

    // MARK: Actions

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Open a .graft seed (also YAML / JSON)"
        guard panel.runModal() == .OK, let url = panel.url, let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = contents; path = url.path; dirty = false; status = nil
        if mode == .form, !loadFormFromText() { mode = .raw; status = "Opened in Raw — the builder couldn't parse this YAML." }
    }

    private func newDoc() {
        text = ""; path = nil; dirty = false; status = nil
        form = RecipeForm()
        if mode == .raw { text = "name: my-image\nfrom: ghcr.io/cirruslabs/macos-sequoia-xcode:latest\n" }
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

    private func inspect() {
        let img = form.from.trimmingCharacters(in: .whitespaces)
        guard !img.isEmpty else { return }
        inspecting = true
        Task {
            inspectOutput = await config.inspectImage(img)
            inspecting = false
            showInspect = true
        }
    }
}

/// What's installed in a base image (from `graft sapling inspect`).
struct InspectSheet: View {
    let image: String
    let report: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's in \(image)").font(.headline).padding(16).lineLimit(1).truncationMode(.middle)
            Divider()
            ScrollView {
                Text(report.isEmpty ? "(nothing)" : report)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            Divider()
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(16)
        }
        .frame(width: 560, height: 440)
    }
}

// MARK: - Reusable editors

struct StringListEditor: View {
    let title: String
    @Binding var items: [String]
    var prompt: String = ""
    var onRemoveBlock: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Button { items.append("") } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
                if let onRemoveBlock {
                    Button(action: onRemoveBlock) { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            ForEach(items.indices, id: \.self) { idx in
                HStack(spacing: 6) {
                    TextField("", text: $items[idx], prompt: Text(prompt))
                    Button { items.remove(at: idx) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct KVEditor: View {
    let title: String
    @Binding var rows: [KVRow]
    var onRemoveBlock: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Button { rows.append(KVRow()) } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
                if let onRemoveBlock {
                    Button(action: onRemoveBlock) { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField("", text: $row.key, prompt: Text("key")).frame(width: 150)
                    TextField("", text: $row.value, prompt: Text("value"))
                    Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Multiple custom-script blocks (the `run:` list) — add as many as you want.
struct ScriptsEditor: View {
    @Binding var scripts: [ScriptRow]
    var onRemoveBlock: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Custom scripts").font(.subheadline.weight(.medium))
                Spacer()
                Button { scripts.append(ScriptRow()) } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
                if let onRemoveBlock {
                    Button(action: onRemoveBlock) { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            ForEach($scripts) { $row in
                HStack(alignment: .top, spacing: 6) {
                    TextEditor(text: $row.body)
                        .font(.system(size: 11, design: .monospaced)).frame(height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.2)))
                    Button { scripts.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct RepoEditor: View {
    @Binding var repos: [RepoRow]
    var onRemoveBlock: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Precache repos").font(.subheadline.weight(.medium))
                Spacer()
                Button { repos.append(RepoRow()) } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
                if let onRemoveBlock {
                    Button(action: onRemoveBlock) { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            ForEach($repos) { $repo in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TextField("", text: $repo.url, prompt: Text("repo URL"))
                        TextField("", text: $repo.ref, prompt: Text("ref")).frame(width: 90)
                        Button { repos.removeAll { $0.id == repo.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    TextField("", text: $repo.sshKey, prompt: Text("ssh-key (guest path, for private repos)"))
                    TextEditor(text: $repo.run)
                        .font(.system(size: 11, design: .monospaced)).frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.2)))
                }
                .padding(8).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
    }
}

/// Holds the Seeds editor's content between visits. Owned by RootView (@StateObject) so it
/// outlives the view, which is recreated each time you navigate back to the section.
final class SeedEditorModel: ObservableObject {
    var loaded = false
    var mode: SeedsView.Mode = .form
    var text = ""
    var form = RecipeForm()
    var path: String?
    var dirty = false
    var status: String?
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
