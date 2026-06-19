import SwiftUI
import GraftCore

/// Browse a registry for a base image instead of typing the ref by hand: pick a curated
/// cirruslabs base (or paste any `host/owner/name` repository), list its tags over the
/// anonymous pull-token flow, choose one, and hand `repo:tag` back. Optionally kick off the
/// pull right away in a Terminal — otherwise the image is pulled lazily when the pool first
/// clones it.
struct RegistryBrowserSheet: View {
    let os: GuestOS
    /// Images already on disk, so the picker can flag "already pulled".
    let localImages: Set<String>
    @ObservedObject var config: ConfigStore
    /// Hands back the chosen `repo:tag` and whether to pull it now.
    let onUse: (_ ref: String, _ pullNow: Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    private let catalog: [RegistryImage]
    @State private var selectedRepo: String?
    @State private var customRepo = ""
    @State private var tags: [String] = []
    @State private var selectedTag: String?
    @State private var loading = false
    @State private var error: String?
    @State private var pullNow = false

    init(os: GuestOS, localImages: Set<String>, config: ConfigStore,
         onUse: @escaping (_ ref: String, _ pullNow: Bool) -> Void) {
        self.os = os
        self.localImages = localImages
        self.config = config
        self.onUse = onUse
        self.catalog = RegistryCatalog.images(for: os)
    }

    /// The repository to query — the curated selection, or the typed-in ref.
    private var activeRepo: String {
        let custom = customRepo.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? (selectedRepo ?? "") : custom
    }

    private var chosenRef: String? {
        guard !activeRepo.isEmpty, let tag = selectedTag, !tag.isEmpty else { return nil }
        return "\(activeRepo):\(tag)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Browse registry").font(.headline).padding(16)
            Divider()
            HStack(spacing: 0) {
                repoColumn.frame(width: 300)
                Divider()
                tagColumn.frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 460)
    }

    // MARK: Repositories

    private var repoColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Base image").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 10)
            List(selection: $selectedRepo) {
                ForEach(catalog, id: \.repository) { img in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(img.title).font(.body)
                        Text(img.blurb).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    .tag(img.repository)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedRepo) { if selectedRepo != nil { customRepo = "" } }

            VStack(alignment: .leading, spacing: 4) {
                Text("…or a repository ref").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $customRepo, prompt: Text("ghcr.io/owner/name"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: customRepo) {
                        if !customRepo.trimmingCharacters(in: .whitespaces).isEmpty { selectedRepo = nil }
                    }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }

    // MARK: Tags

    private var tagColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tag").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button {
                    Task { await loadTags() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(activeRepo.isEmpty || loading)
                    .help("Fetch tags")
            }
            .padding(.horizontal, 12).padding(.top, 10)

            if let error {
                contentNote("Couldn't list tags", error, systemImage: "exclamationmark.triangle")
            } else if activeRepo.isEmpty {
                contentNote("Pick a base image", "Choose one on the left, or type a repository ref.", systemImage: "shippingbox")
            } else if tags.isEmpty && !loading {
                contentNote("No tags", "This repository reported no tags.", systemImage: "tag")
            } else {
                List(selection: $selectedTag) {
                    ForEach(tags, id: \.self) { tag in
                        HStack {
                            Text(tag)
                            if localImages.contains("\(activeRepo):\(tag)") {
                                Text("on disk").font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                            }
                            Spacer()
                        }
                        .tag(tag)
                    }
                }
                .listStyle(.inset)
            }
        }
        // Re-fetch whenever the active repository changes (selection or typed ref).
        .task(id: activeRepo) { await loadTags() }
    }

    private func contentNote(_ title: String, _ note: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(title).font(.subheadline.weight(.medium))
            Text(note).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Toggle("Pull now in Terminal", isOn: $pullNow)
                .toggleStyle(.checkbox)
                .help("Start the pull immediately; otherwise it's pulled when the pool first clones it.")
            Spacer()
            if let ref = chosenRef {
                Text(ref).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Button("Cancel") { dismiss() }
            Button("Use image") {
                if let ref = chosenRef { onUse(ref, pullNow) }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosenRef == nil)
        }
        .padding(16)
    }

    // MARK: Loading

    private func loadTags() async {
        let repo = activeRepo
        guard !repo.isEmpty else { tags = []; error = nil; return }
        loading = true
        error = nil
        selectedTag = nil
        let result = await config.registryTags(for: repo)
        // The active repo may have changed while we were awaiting — drop a stale result.
        guard repo == activeRepo else { return }
        if let message = result.error {
            tags = []
            error = message
        } else {
            tags = result.tags
            selectedTag = result.tags.first
        }
        loading = false
    }
}
