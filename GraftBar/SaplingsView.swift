import SwiftUI
import AppKit
import GraftCore

/// The Saplings section — the golden images leaves (and nests) clone from. Lists local
/// images, grows new ones from a `.graft` seed, pulls from a registry, and removes them.
/// Builds/pulls are long + output-heavy, so they run in a terminal where you can watch.
struct SaplingsView: View {
    @ObservedObject var config: ConfigStore
    @AppStorage(Vocabulary.storageKey) private var vocab: Vocabulary = .standard

    @State private var images: [String] = []
    @State private var loading = false
    @State private var pulling = false
    @State private var pendingRemove: String?

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
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Button { grow() } label: { Label("Grow…", systemImage: "hammer") }
                .disabled(!config.graftAvailable)
                .help(config.graftAvailable ? "Build a sapling from a .graft seed" : "Install the graft CLI")
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
                ForEach(images, id: \.self) { name in
                    HStack(spacing: 12) {
                        Image(systemName: "leaf").foregroundStyle(.green)
                        Text(name).font(.body).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { pendingRemove = name } label: { Image(systemName: "trash") }
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
        Task { images = await config.localImages(); loading = false }
    }

    private func grow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a .graft seed (also YAML / JSON)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.growSapling(seedPath: url.path)
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
