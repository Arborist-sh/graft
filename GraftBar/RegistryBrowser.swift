import SwiftUI
import GraftCore

/// Browse the registry catalog for a base image, Miller-column style: **Sources** (one row
/// per owner/namespace) → **Images** (the repos saved under that source) → **Versions** (the
/// tags of the selected repo). The catalog is yours — saved at `~/.graft/registries.json`,
/// seeded with the cirruslabs bases but fully editable: add a repository, remove any entry.
/// Pick a tag and hand `repo:tag` back, optionally pulling it now in a Terminal.
///
/// Note: a registry won't enumerate its repositories for us, so the Images column shows the
/// repos *you've added* under a source — not an auto-discovered list.
struct RegistryBrowserSheet: View {
    /// Where the sheet is used — it only changes the footer + a couple of affordances.
    enum Mode {
        /// Pool editor: pick a `repo:tag`, with an optional "pull now". Shows local images.
        case pickForPool
        /// Saplings: pull the chosen image to disk now. Hides the local source (you're
        /// downloading new images) and shows every OS (no pool to scope to).
        case pull
    }

    let mode: Mode
    /// Catalog OS scope, or nil to show every OS (pull mode has no pool to scope to).
    let osFilter: GuestOS?
    /// Images already on disk, so the picker can flag "already pulled".
    let localImages: Set<String>
    @ObservedObject var config: ConfigStore
    /// Hands back the chosen `repo:tag` and whether to pull it now.
    let onUse: (_ ref: String, _ pullNow: Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var catalog: [RegistryImage] = []
    @State private var selectedOwner: String?     // an `ownerKey`, e.g. "ghcr.io/cirruslabs"
    @State private var selectedRepo: String?
    @State private var selectedTag: String?
    @State private var tags: [String] = []
    @State private var loadedRepo: String?   // which repo `tags` belong to (vs `selectedRepo`)
    @State private var loading = false
    @State private var error: String?
    @State private var skeletonPulse = false
    @State private var newRepo = ""
    @State private var addError: String?
    @State private var showAddSource = false
    @State private var pullNow = false

    init(mode: Mode = .pickForPool, os: GuestOS? = nil, localImages: Set<String>,
         config: ConfigStore, onUse: @escaping (_ ref: String, _ pullNow: Bool) -> Void) {
        self.mode = mode
        self.osFilter = os
        self.localImages = localImages
        self.config = config
        self.onUse = onUse
    }

    /// Sentinel `ownerKey` for the synthetic "on this Mac" source of local images.
    private static let localKey = "\u{0001}local"

    /// Catalog entries in scope: filtered to `osFilter` when set (an entry with no OS shows
    /// for any pool), otherwise everything (pull mode).
    private var visible: [RegistryImage] {
        catalog.filter { img in
            guard let osFilter else { return true }
            return img.os == nil || img.os == osFilter
        }
    }

    /// Local on-disk images, surfaced as their own source — but only when picking for a pool.
    /// Pulling is about *new* images, so the local source is hidden there.
    private var localEntries: [RegistryImage] {
        guard mode == .pickForPool else { return [] }
        return localImages.sorted().map { RegistryImage(repository: $0, title: $0) }
    }

    private var isLocalSource: Bool { selectedOwner == Self.localKey }

    /// One row per source: the local images first, then each catalog owner (sorted by owner
    /// then host). Images within a source keep catalog order — which is curated newest-first,
    /// so the list reads newest → oldest rather than alphabetically.
    private var sources: [(key: String, owner: String, host: String, images: [RegistryImage])] {
        var result: [(key: String, owner: String, host: String, images: [RegistryImage])] = []
        if !localEntries.isEmpty {
            result.append((key: Self.localKey, owner: "local", host: "on this Mac", images: localEntries))
        }
        let catalogSources = Dictionary(grouping: visible, by: \.ownerKey)
            .map { key, imgs in (key: key, owner: imgs[0].owner, host: imgs[0].host, images: imgs) }
            .sorted { ($0.owner, $0.host) < ($1.owner, $1.host) }
        result.append(contentsOf: catalogSources)
        return result
    }

    /// The images under the selected source, in catalog (newest-first) order.
    private var imagesForOwner: [RegistryImage] {
        guard let key = selectedOwner else { return [] }
        if key == Self.localKey { return localEntries }
        return visible.filter { $0.ownerKey == key }
    }

    private var chosenRef: String? {
        guard let repo = selectedRepo else { return nil }
        if isLocalSource { return repo }   // a local image's name is already a complete ref
        guard let tag = selectedTag, !tag.isEmpty else { return nil }
        return "\(repo):\(tag)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Browse registry").font(.headline).padding(16)
            Divider()
            HStack(spacing: 0) {
                sourcesColumn.frame(width: 210)
                Divider()
                imagesColumn.frame(width: 240)
                Divider()
                versionsColumn.frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 500)
        .onAppear { catalog = config.registryCatalog() }
        .onChange(of: selectedOwner) {
            // Dropping to a new source clears a now-irrelevant image selection.
            if let repo = selectedRepo, !imagesForOwner.contains(where: { $0.repository == repo }) {
                clearImageSelection()
            }
        }
    }

    // MARK: Sources (owners)

    private var sourcesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("Sources")
            if sources.isEmpty {
                contentNote("No sources", "Add a repository below to get started.", systemImage: "shippingbox")
            } else {
                List(selection: $selectedOwner) {
                    ForEach(sources, id: \.key) { source in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.owner.isEmpty ? source.host : source.owner).font(.body)
                            Text(source.host).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(source.key)
                    }
                }
                .listStyle(.inset)
            }
            // Adding a repo creates a source — a foot-of-column button that pops a small
            // field, kept out of the Sources → Images → Versions browse flow.
            Divider()
            Button {
                newRepo = ""; addError = nil; showAddSource = true
            } label: {
                Label("Add source", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 8)
            .popover(isPresented: $showAddSource, arrowEdge: .bottom) { addSourcePopover }
        }
    }

    // MARK: Images

    private var imagesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("Images")
            if selectedOwner == nil {
                contentNote("Pick a source", "Choose one on the left.", systemImage: "square.stack.3d.up")
            } else {
                List(selection: $selectedRepo) {
                    ForEach(imagesForOwner) { img in
                        imageRow(img).tag(img.repository)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func imageRow(_ img: RegistryImage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Local images show their full name (it's the literal ref); catalog images
                // show the short image name with a blurb.
                Text(isLocalSource ? img.repository : img.imageName).font(.body)
                    .lineLimit(1).truncationMode(.middle)
                // Flag a catalog image whose ref is already cached locally (any tag of it).
                if !isLocalSource, isDownloaded(img.repository) { onDiskBadge }
                Spacer(minLength: 0)
            }
            if !isLocalSource, !img.blurb.isEmpty {
                Text(img.blurb).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if !isLocalSource {
                Button("Remove from list", role: .destructive) { removeRepo(img) }
            }
        }
    }

    /// A small "on disk" pill, shown where an image/version is already cached locally.
    private var onDiskBadge: some View {
        Text("on disk").font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .help("Already downloaded locally")
    }

    /// Whether `repository` is cached locally under any tag (`tart list` keeps the full
    /// `repo:tag` ref). Used to flag catalog images that are already on disk.
    private func isDownloaded(_ repository: String) -> Bool {
        localImages.contains { $0 == repository || $0.hasPrefix("\(repository):") }
    }

    private var addSourcePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a repository").font(.subheadline.weight(.medium))
            Text("Browse and pull from any registry repository — it's saved to your catalog.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("", text: $newRepo, prompt: Text("ghcr.io/owner/name"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(addRepo)
            if let addError {
                Text(addError).font(.caption2).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { showAddSource = false }
                Button("Add") { addRepo() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newRepo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: Versions (tags)

    private var versionsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                columnHeader("Versions")
                Spacer()
                if loading { ProgressView().controlSize(.small).padding(.trailing, 12).padding(.top, 8) }
                else if selectedRepo != nil && !isLocalSource {
                    Button { Task { await loadTags() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Fetch tags")
                        .padding(.trailing, 12).padding(.top, 6)
                }
            }
            if selectedRepo == nil {
                contentNote("Pick an image", "Choose one in the middle to see its versions.", systemImage: "tag")
            } else if isLocalSource {
                contentNote("On disk", "Local images are used as-is — there's no registry version to pick.", systemImage: "internaldrive")
            } else if loading || loadedRepo != selectedRepo {
                // Loading, or the tags we have belong to a previously-selected image — show a
                // skeleton instead of stale versions.
                versionsSkeleton
            } else if let error {
                contentNote("Couldn't list tags", error, systemImage: "exclamationmark.triangle")
            } else if tags.isEmpty {
                contentNote("No versions", "This repository reported no tags.", systemImage: "tag")
            } else {
                List(selection: $selectedTag) {
                    ForEach(tags, id: \.self) { tag in
                        HStack {
                            Text(tag)
                            if let repo = selectedRepo, localImages.contains("\(repo):\(tag)") {
                                onDiskBadge
                            }
                            Spacer()
                        }
                        .tag(tag)
                    }
                }
                .listStyle(.inset)
            }
        }
        .task(id: selectedRepo) { await loadTags() }
    }

    // MARK: Bits

    private func columnHeader(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
    }

    /// Placeholder rows shown while versions load — redacted bars, gently pulsing, laid out
    /// like the real tag list so the column doesn't jump when results arrive.
    private var versionsSkeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach([54, 40, 64, 36, 48, 58, 42], id: \.self) { width in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: CGFloat(width), height: 12)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(skeletonPulse ? 0.45 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                skeletonPulse = true
            }
        }
    }

    private func contentNote(_ title: String, _ note: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 24)).foregroundStyle(.tertiary)
            Text(title).font(.subheadline.weight(.medium))
            Text(note).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
    }

    private var footer: some View {
        HStack {
            if mode == .pickForPool {
                Toggle("Pull now in Terminal", isOn: $pullNow)
                    .toggleStyle(.checkbox)
                    .help("Start the pull immediately; otherwise it's pulled when the pool first clones it.")
            }
            Spacer()
            if let ref = chosenRef {
                Text(ref).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Button("Cancel") { dismiss() }
            Button(mode == .pull ? "Pull" : "Use image") {
                if let ref = chosenRef { onUse(ref, mode == .pull ? true : pullNow) }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosenRef == nil)
        }
        .padding(16)
    }

    // MARK: Mutation

    /// Add the typed repository to the saved catalog (validated, tag stripped), persist, and
    /// navigate to it so its versions load. A duplicate just navigates to the existing entry.
    private func addRepo() {
        let ref = newRepo.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { return }
        guard let (host, name) = try? RegistryClient.split(ref) else {
            addError = "Use a host/owner/name ref like ghcr.io/owner/name"
            return
        }
        let repo = "\(host)/\(name)"
        addError = nil
        newRepo = ""
        showAddSource = false
        if !catalog.contains(where: { $0.repository == repo }) {
            catalog.append(.userAdded(repo))
            config.saveRegistryCatalog(catalog)
        }
        let added = RegistryImage.userAdded(repo)
        selectedOwner = added.ownerKey
        selectedRepo = repo
    }

    private func removeRepo(_ img: RegistryImage) {
        catalog.removeAll { $0.repository == img.repository }
        config.saveRegistryCatalog(catalog)
        if selectedRepo == img.repository { clearImageSelection() }
        // If that was the source's last image, drop the (now-empty) source selection too.
        if let key = selectedOwner, !visible.contains(where: { $0.ownerKey == key }) {
            selectedOwner = nil
        }
    }

    private func clearImageSelection() {
        selectedRepo = nil
        selectedTag = nil
        tags = []
        error = nil
    }

    // MARK: Loading

    private func loadTags() async {
        // Local images have no registry tags to fetch — they're used as-is.
        guard let repo = selectedRepo, !isLocalSource else { tags = []; error = nil; loading = false; return }
        loading = true
        error = nil
        selectedTag = nil
        let result = await config.registryTags(for: repo)
        // The selection may have changed while we were awaiting — drop a stale result.
        guard repo == selectedRepo else { return }
        loadedRepo = repo
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
