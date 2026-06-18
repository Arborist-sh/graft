import SwiftUI
import AppKit
import GraftCore

/// The Saplings section — the golden images leaves (and nests) clone from. Lists local
/// images, grows new ones from a `.graft` seed, pulls from a registry, and removes them.
/// Builds/pulls are long + output-heavy, so they run in a terminal where you can watch.
struct SaplingsView: View {
    @ObservedObject var config: ConfigStore
    @AppStorage(Vocabulary.storageKey) private var vocab: Vocabulary = .standard

    @State private var images: [TartVM] = []
    @State private var seeds: [String] = []
    @State private var loading = false
    @State private var pulling = false
    @State private var pendingRemove: String?
    @State private var editingSeed: EditingSeed?
    @State private var status: String?
    /// Host-specific build network for grows on THIS machine (e.g. "bridged:en0"); empty = NAT.
    /// Shared with the Seeds tab via the same key; maps to `grow --network`, never baked into a seed.
    @AppStorage("graft.buildNetwork") private var buildNetwork = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { reload() }
        .sheet(isPresented: $pulling) {
            PullSaplingSheet { ref in config.pullSapling(ref: ref) }
        }
        .sheet(item: $editingSeed, onDismiss: reload) { target in
            SeedEditorSheet(config: config, editing: target.name)
        }
        .confirmationDialog(
            "Remove image “\(pendingRemove ?? "")”?",
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let n = pendingRemove { remove(n) }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("Deletes the local image. Pools/nests cloning from it will fail until it's back.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(Lex.images(vocab)).font(.title2.weight(.semibold))
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            HStack(spacing: 4) {
                Image(systemName: "network").foregroundStyle(.secondary)
                TextField("nat | bridged:en0", text: $buildNetwork)
                    .textFieldStyle(.roundedBorder).frame(width: 130)
            }
            .help("Build-VM network for grows on THIS machine (e.g. bridged:en0 behind a corporate IP allow list). Host-specific — applied as `--network`, never saved into the seed.")
            Menu {
                if seeds.isEmpty {
                    Text("No seeds in your library yet")
                } else {
                    ForEach(seeds, id: \.self) { s in Button(s) { growSeed(s) } }
                }
                Divider()
                Button("From a file…") { growFromFile() }
            } label: { Label("Grow…", systemImage: "hammer") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(!config.graftAvailable)
                .help(config.graftAvailable ? "Build a sapling from one of your seeds" : "Install the graft CLI")
            Button { pulling = true } label: { Label("Pull…", systemImage: "arrow.down.circle") }
                .disabled(!config.graftAvailable)
                .help(config.graftAvailable ? "Pull an image from a registry" : "Install the graft CLI")
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if images.isEmpty {
            empty
        } else {
            List {
                ForEach(images, id: \.name) { vm in
                    let seed = config.seedRecipe(vm.name)
                    HStack(spacing: 12) {
                        Image(systemName: seed != nil ? "circle.hexagongrid.fill" : "leaf")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.name).font(.body).lineLimit(1).truncationMode(.middle)
                            Text(provenance(vm, seed: seed))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if seed != nil {
                            Button("Edit seed") { editingSeed = EditingSeed(name: vm.name) }
                                .help("Open the seed this was grown from")
                        }
                        Button(role: .destructive) { pendingRemove = vm.name } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove image")
                    }
                    .padding(.vertical, 4)
                }
                if !config.graftAvailable {
                    Text("Install the graft CLI to grow or pull saplings (remove works without it).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    /// One-line provenance: a matching library seed (→ grown from it, on what base), else
    /// the registry/local origin from `tart list`, with size when known.
    private func provenance(_ vm: TartVM, seed: ImageRecipe?) -> String {
        if let seed {
            let base = seed.from.isEmpty ? "—" : seed.from
            return "grown from seed · base \(base)"
        }
        let origin = (vm.source ?? "").lowercased() == "oci" ? "pulled image" : "local image"
        guard let size = vm.size, size > 0 else { return origin }
        return "\(origin) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }

    private var empty: some View {
        VStack(spacing: 10) {
            GraftMark(size: 40, color: Color(nsColor: .tertiaryLabelColor))
            Text("No images yet").font(.headline)
            Text(config.graftAvailable
                 ? "Grow one from a .graft seed, or pull a base image from a registry."
                 : "Install the graft CLI, then grow or pull an image.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func reload() {
        loading = true
        seeds = config.seedNames()
        Task { images = await config.saplings(); loading = false }
    }

    /// Grow one of the library seeds (terminal stream); it'll appear here after a Refresh.
    private func growSeed(_ name: String) {
        config.growSeed(name, network: buildNetwork)
        status = "Growing \(name) — watch the terminal, then Refresh."
    }

    /// Escape hatch: grow from a `.graft` file anywhere on disk (not in the library).
    private func growFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a .graft seed (also YAML / JSON)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.growSapling(seedPath: url.path, network: buildNetwork)
        status = "Growing — watch the terminal, then Refresh."
    }

    private func remove(_ name: String) {
        Task { await config.removeSapling(name); reload() }
    }
}

/// Pull an image from a registry by reference.
struct PullSaplingSheet: View {
    let onPull: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ref = ""

    private var valid: Bool { !ref.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pull image").font(.headline)
            TextField("Registry reference", text: $ref,
                      prompt: Text("ghcr.io/cirruslabs/macos-sequoia-xcode:latest"))
                .textFieldStyle(.roundedBorder).frame(width: 420)
            Text("Downloads the image locally — runs in a terminal so you can watch progress.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Pull") { onPull(ref.trimmingCharacters(in: .whitespaces)); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
