import SwiftUI
import AppKit
import GraftCore

/// The Saplings section — the golden images leaves (and nests) clone from. Lists local
/// images, pulls base images from a registry, and removes them. (Growing a sapling from a
/// `.graft` seed lives in the Seeds tab.) Pulls run in a terminal where you can watch.
struct SaplingsView: View {
    @ObservedObject var config: ConfigStore
    @AppStorage(Vocabulary.storageKey) private var vocab: Vocabulary = .standard

    @State private var images: [TartVM] = []
    @State private var loading = false
    @State private var pulling = false
    @State private var pendingRemove: String?
    @State private var editingSeed: EditingSeed?
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { reload() }
        .sheet(isPresented: $pulling) {
            RegistryBrowserSheet(mode: .pull, localImages: Set(images.map(\.name)), config: config) { ref, _ in
                config.pullSapling(ref: ref)
                status = "Pulling \(ref) — watch the terminal, then Refresh."
            }
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
                    Text("Install the graft CLI to pull saplings (remove works without it).")
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
                 ? "Pull a base image from a registry, or grow one over in Seeds."
                 : "Install the graft CLI, then pull an image (or grow one in Seeds).")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func reload() {
        loading = true
        Task { images = await config.saplings(); loading = false }
    }

    private func remove(_ name: String) {
        Task { await config.removeSapling(name); reload() }
    }
}
