import SwiftUI
import AppKit
import GraftCore

/// The Seeds section — a library of `.graft` image recipes kept in `~/.graft/seeds/`.
/// Browse them, create / duplicate / grow / delete, and edit one in a modal. Editing
/// is the `SeedEditorSheet` (Builder ↔ Raw). A seed's identity is its recipe `name`
/// (the file is `<name>.graft`). See [[seed-registry-idea]] for where this is headed.
struct SeedsView: View {
    @ObservedObject var config: ConfigStore
    @AppStorage(Vocabulary.storageKey) private var vocab: Vocabulary = .standard

    @State private var seeds: [String] = []
    @State private var editing: EditingSeed?
    @State private var pendingDelete: String?
    @State private var status: String?
    /// Host-specific build network applied to grows on THIS machine (e.g. "bridged:en0").
    /// Empty = NAT default. Per-machine (the interface name isn't portable), so it lives in
    /// app prefs and maps to `grow --network` — deliberately NOT baked into the shareable seed.
    @AppStorage("graft.buildNetwork") private var buildNetwork = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear(perform: reload)
        .sheet(item: $editing, onDismiss: reload) { target in
            SeedEditorSheet(config: config, editing: target.name)
        }
        .confirmationDialog(
            "Delete seed “\(pendingDelete ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let n = pendingDelete { config.removeSeed(n); reload() }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Removes ~/.graft/seeds/\(pendingDelete ?? "").graft. Saplings already grown from it are untouched.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(Lex.seeds(vocab)).font(.title2.weight(.semibold))
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "network").foregroundStyle(.secondary)
                TextField("nat | bridged:en0", text: $buildNetwork)
                    .textFieldStyle(.roundedBorder).frame(width: 130)
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .help("Build network for grows on THIS machine — passed as `--network`.\n\n• Leave empty for the default (NAT).\n• Use bridged:<iface> (e.g. bridged:en8) when NAT is blocked, e.g. behind a corporate VPN / IP allow list, so the build VM rides your network.\n\nHost-specific: it's saved in app prefs, never baked into the shareable seed.")
            }
            Button { importSeed() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
            Button { editing = EditingSeed(name: nil) } label: { Label("New seed", systemImage: "plus") }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if seeds.isEmpty {
            VStack(spacing: 12) {
                GraftMark(size: 44, color: Color(nsColor: .tertiaryLabelColor))
                Text("No seeds yet").font(.headline)
                Text("A seed is a .graft recipe that builds a golden image.\nCreate one, or import an existing .graft.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { editing = EditingSeed(name: nil) } label: { Label("New seed", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            List {
                ForEach(seeds, id: \.self, content: row)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ name: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.hexagongrid").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium))
                Text(summary(name)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Edit") { editing = EditingSeed(name: name) }
            Button("Duplicate") {
                if let n = config.duplicateSeed(name) { reload(); status = "Duplicated → \(n)" }
            }
            Button("Grow") {
                config.growSeed(name, network: buildNetwork)
                status = "Growing \(name) — watch the terminal; it'll appear in Saplings when done."
            }
            .disabled(!config.graftAvailable)
            .help(config.graftAvailable ? "Build this seed into a sapling" : "graft CLI not found")
            Button(role: .destructive) { pendingDelete = name } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete seed")
        }
        .padding(.vertical, 4)
    }

    /// One-line "from IMAGE · N components" summary, parsed live from the seed.
    private func summary(_ name: String) -> String {
        guard let r = config.seedRecipe(name) else { return "unparseable .graft (open to fix in Raw)" }
        let n = RecipeForm(from: r).active.count
        let from = r.from.isEmpty ? "no base" : r.from
        return "\(from)  ·  \(n) component\(n == 1 ? "" : "s")"
    }

    private func reload() { seeds = config.seedNames() }

    private func importSeed() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Import a .graft seed into your library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let name = config.importSeed(from: url) { reload(); status = "Imported → \(name)" }
        else { status = "Couldn't import that file." }
    }
}

/// `.sheet(item:)` wrapper — `name == nil` means a brand-new seed.
struct EditingSeed: Identifiable { let id = UUID(); let name: String? }

/// Edit one seed in a modal: a **Builder** (start with name/from, "+ Add" only the
/// components you want) or the **Raw** YAML. Round-trips through `ImageRecipe`, so a
/// form-save rewrites clean YAML (Raw is the lossless escape hatch). Saves into the
/// library keyed by the recipe `name`; changing the name renames the file.
struct SeedEditorSheet: View {
    @ObservedObject var config: ConfigStore
    /// The seed being edited; nil for a new one.
    let editing: String?
    @Environment(\.dismiss) private var dismiss

    enum Mode: String { case form, raw }

    @State private var mode: Mode = .form
    @State private var text = ""
    @State private var form = RecipeForm()
    /// The name we loaded under — to rename the file if the recipe name changes on save.
    @State private var originalName: String?
    @State private var dirty = false
    @State private var status: String?
    @State private var images: [String] = []

    @State private var rendering = false
    @State private var renderOutput = ""
    @State private var inspecting = false
    @State private var showInspect = false
    @State private var inspectOutput = ""
    @State private var confirmDiscard = false
    @State private var savingAs = false
    @State private var saveAsName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group { if mode == .form { formEditor } else { rawEditor } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .task { images = await config.localImages() }
        .onAppear(perform: load)
        .sheet(isPresented: $rendering) { RenderSheet(script: renderOutput) }
        .sheet(isPresented: $showInspect) { InspectSheet(image: form.from, report: inspectOutput) }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .alert("Save as", isPresented: $savingAs) {
            TextField("New seed name", text: $saveAsName)
            Button("Save") { saveAs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves a copy under a new name.")
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            Text(editing == nil ? "New seed" : (originalName ?? editing!))
                .font(.headline)
            Picker("", selection: Binding(get: { mode }, set: { switchMode(to: $0) })) {
                Text("Builder").tag(Mode.form); Text("Raw").tag(Mode.raw)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            if dirty { Text("•").foregroundStyle(.secondary) }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button { render() } label: { Label("Render", systemImage: "eye") }
                .disabled(!config.graftAvailable)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Save as…") { saveAsName = ""; savingAs = true }
                .disabled(currentName() == nil)
            Spacer()
            Button("Cancel") { if dirty { confirmDiscard = true } else { dismiss() } }
            Button("Save") { if save() { dismiss() } }
                .buttonStyle(.borderedProminent)
                .disabled(currentName() == nil)
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

    /// The seed's identity (recipe name) from current state, or nil if unset / unparseable.
    private func currentName() -> String? {
        let raw: String
        if mode == .form { raw = form.name }
        else { guard let r = try? ImageRecipe.parse(text) else { return nil }; raw = r.name }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Load / save

    private func load() {
        guard let editing else { form = RecipeForm(); mode = .form; return }
        originalName = editing
        text = config.readSeed(editing)
        if loadFormFromText() { mode = .form }
        else { mode = .raw; status = "Opened in Raw — the builder couldn't parse this YAML." }
    }

    @discardableResult
    private func save() -> Bool {
        guard let name = currentName() else { status = "Give the seed a name first."; return false }
        if name != originalName, config.seedExists(name) {
            status = "A seed named “\(name)” already exists."; return false
        }
        guard config.saveSeed(canonicalText(), as: name, renamingFrom: originalName) else {
            status = "Couldn't save."; return false
        }
        originalName = name; dirty = false; status = "Saved."
        return true
    }

    /// Save a copy under a new name, leaving the original untouched, and switch to it.
    private func saveAs() {
        let name = saveAsName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard !config.seedExists(name) else { status = "A seed named “\(name)” already exists."; return }
        if mode == .form { form.name = name } // keep identity = recipe name
        else if var r = try? ImageRecipe.parse(text) { r.name = name; text = (try? r.yamlString()) ?? text }
        guard config.saveSeed(canonicalText(), as: name) else { status = "Couldn't save."; return }
        originalName = name; dirty = false; status = "Saved as \(name)."
    }

    // MARK: Render / inspect

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
