import SwiftUI
import GraftCore

/// The Pools section — view + edit the pools of the selected profile. Reads/writes the
/// profile JSON straight through `ConfigStore` (no shelling). Pick a profile, then add /
/// edit / remove pools; each save rewrites that profile's config.
struct PoolsView: View {
    @ObservedObject var config: ConfigStore
    @State private var cfg: GraftConfig?
    @State private var draft: PoolDraft?
    @State private var images: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear(perform: load)
        .onChange(of: config.selected) { load() }
        .task { images = await config.localImages() }
        .sheet(item: $draft) { d in
            PoolEditorSheet(draft: d, images: images) { apply($0) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Pools").font(.title2.weight(.semibold))
            if !config.profiles.isEmpty {
                Picker("", selection: Binding(
                    get: { config.selected ?? "" },
                    set: { config.selected = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(config.profiles, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            Button { draft = PoolDraft() } label: { Label("Add pool", systemImage: "plus") }
                .disabled(cfg == nil)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if config.selected == nil {
            empty("No profile", "Create a profile first, over in the Profiles tab.")
        } else if cfg == nil {
            empty("Can't read profile", "“\(config.selected ?? "")” may be an old-schema file.")
        } else if cfg?.pools.isEmpty ?? true {
            empty("No pools yet", "Add a pool — a workload's runners (count, image, labels).")
        } else {
            List {
                ForEach(Array((cfg?.pools ?? []).enumerated()), id: \.offset) { idx, pool in
                    poolRow(idx, pool)
                }
            }
            .listStyle(.inset)
        }
    }

    private func poolRow(_ idx: Int, _ pool: PoolConfig) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.grid.2x2").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pool.name).font(.body.weight(.medium))
                    Text(pool.os.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    Text("× \(pool.count)").font(.caption).foregroundStyle(.secondary)
                }
                Text(pool.image).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let labels = pool.labels, !labels.isEmpty {
                    Text(labels.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Edit") { draft = PoolDraft(from: pool, index: idx) }
            Button(role: .destructive) { remove(idx) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove pool")
        }
        .padding(.vertical, 4)
    }

    private func empty(_ title: String, _ note: String) -> some View {
        VStack(spacing: 10) {
            GraftMark(size: 40, color: Color(nsColor: .tertiaryLabelColor))
            Text(title).font(.headline)
            Text(note).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func load() {
        cfg = config.selected.flatMap { config.config($0) }
    }

    private func apply(_ d: PoolDraft) {
        guard var c = cfg, let name = config.selected else { return }
        let pool = d.toPool()
        if let i = d.index, c.pools.indices.contains(i) {
            c.pools[i] = pool
        } else {
            c.pools.append(pool)
        }
        config.save(c, as: name)
        cfg = c
    }

    private func remove(_ idx: Int) {
        guard var c = cfg, let name = config.selected, c.pools.indices.contains(idx) else { return }
        c.pools.remove(at: idx)
        config.save(c, as: name)
        cfg = c
    }
}

/// Editable form state for a pool — a string-backed mirror of `PoolConfig` so optional
/// numeric fields (cpu/memory) can be left blank. `index == nil` means a new pool.
struct PoolDraft: Identifiable {
    let id = UUID()
    var index: Int?
    var name = ""
    var image = ""
    var os: GuestOS = .macOS
    var count = 1
    var labels = ""   // comma-separated
    var cpu = ""      // blank = unset
    var memory = ""   // blank = unset (MB)

    init() {}

    init(from p: PoolConfig, index: Int) {
        self.index = index
        name = p.name
        image = p.image
        os = p.os
        count = p.count
        labels = (p.labels ?? []).joined(separator: ", ")
        cpu = p.cpu.map(String.init) ?? ""
        memory = p.memory.map(String.init) ?? ""
    }

    func toPool() -> PoolConfig {
        let labelList = labels.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return PoolConfig(
            name: name.trimmingCharacters(in: .whitespaces),
            image: image.trimmingCharacters(in: .whitespaces),
            os: os,
            count: max(1, count),
            labels: labelList.isEmpty ? nil : labelList,
            cpu: Int(cpu.trimmingCharacters(in: .whitespaces)),
            memory: Int(memory.trimmingCharacters(in: .whitespaces))
        )
    }
}

/// Add / edit a single pool. Operates on a local copy; hands the result back via `onSave`.
struct PoolEditorSheet: View {
    @State var draft: PoolDraft
    var images: [String] = []
    let onSave: (PoolDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    private var valid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.image.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.index == nil ? "Add pool" : "Edit pool").font(.headline).padding(16)
            Divider()
            Form {
                TextField("Name", text: $draft.name)
                LabeledContent("Image") {
                    HStack(spacing: 6) {
                        TextField("", text: $draft.image, prompt: Text("ghcr.io/cirruslabs/macos-tahoe-xcode:latest"))
                        if !images.isEmpty {
                            Menu {
                                ForEach(images, id: \.self) { img in
                                    Button(img) { draft.image = img }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Pick a local image")
                        }
                    }
                }
                Picker("OS", selection: $draft.os) {
                    Text("macOS").tag(GuestOS.macOS)
                    Text("Linux").tag(GuestOS.linux)
                }
                Stepper("Runners: \(draft.count)", value: $draft.count, in: 1...50)
                TextField("Labels", text: $draft.labels, prompt: Text("comma-separated · optional"))
                TextField("CPU cores", text: $draft.cpu, prompt: Text("optional"))
                TextField("Memory (MB)", text: $draft.memory, prompt: Text("optional"))
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(draft); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid)
            }
            .padding(16)
        }
        .frame(width: 440, height: 480)
    }
}
