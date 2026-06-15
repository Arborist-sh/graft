import SwiftUI
import GraftCore

/// The Nests section — your dev boxes (`graft nest`): persistent Tart VMs you clone a repo
/// into or mount a dir on, opened over a shell or VS Code Remote-SSH. graft owns the boot +
/// Remote-SSH dance, so the GUI lists/stops/removes via `tart` directly and delegates
/// open/create to the `graft` CLI. Auto-refreshes so state flips as boxes boot / stop.
struct NestsView: View {
    @ObservedObject var config: ConfigStore
    @AppStorage(Vocabulary.storageKey) private var vocab: Vocabulary = .standard

    @State private var nests: [TartVM] = []
    @State private var loading = false
    @State private var creating = false
    @State private var pendingRemove: String?
    @State private var note: String?
    /// Poll fast (1s) for a window after an action even before the box shows up in `tart list`.
    @State private var fastUntil: Date?
    @State private var ticks = 0

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { reload() }
        .onReceive(tick) { _ in
            ticks += 1
            // 1s while something's actively happening (provisioning, or just after an
            // action); back off to ~5s when everything's idle.
            if isBusy || ticks % 5 == 0 { reload(silent: true) }
        }
        .sheet(isPresented: $creating) {
            NewNestSheet(config: config) { target, image in
                config.newNest(target: target, image: image)
                note = "Creating “\(target)” — VS Code will open when it's ready."
                fastUntil = Date().addingTimeInterval(180)
                reload(silent: true)
            }
        }
        .confirmationDialog(
            "Remove nest “\(short(pendingRemove ?? ""))”?",
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let n = pendingRemove { remove(n) }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("Stops and deletes the box and everything in it. This can't be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(Lex.nests(vocab)).font(.title2.weight(.semibold))
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Button { creating = true } label: { Label("New nest", systemImage: "plus") }
                .disabled(!config.graftAvailable)
                .help(config.graftAvailable ? "Clone a repo into a new dev box" : "Install the graft CLI to create nests")
        }
        .padding(16)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if nests.isEmpty {
            empty
        } else {
            List {
                ForEach(nests, id: \.name) { nest in row(nest) }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                if !config.graftAvailable {
                    Text("Install the graft CLI to open or create nests (list / stop / remove work without it).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ nest: TartVM) -> some View {
        let running = nest.state.lowercased() == "running"
        let s = state(nest)
        return HStack(spacing: 12) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(short(nest.name)).font(.body.weight(.medium))
                HStack(spacing: 5) {
                    if s.busy { ProgressView().controlSize(.small) }
                    Text(s.text).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Circle().fill(s.color).frame(width: 8, height: 8)
            Spacer()
            Button("VS Code") { openCode(nest) }
                .disabled(!config.graftAvailable)
                .help(config.graftAvailable ? "Boot if needed + open VS Code over Remote-SSH" : "Install the graft CLI")
            Button("Shell") { openShell(nest) }
                .disabled(!config.graftAvailable)
                .help(config.graftAvailable ? "Open an interactive shell in a new Terminal/iTerm window" : "Install the graft CLI")
            Button("Window") { config.openNestWindow(name: nest.name) }
                .disabled(running)
                .help(running ? "Stop the nest first — Tart can't attach a window to a running headless VM"
                              : "Boot the box in a Tart window (its macOS screen)")
            if running {
                Button("Stop") { stop(nest.name) }
            }
            Button(role: .destructive) { pendingRemove = nest.name } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove nest")
        }
        .padding(.vertical, 4)
    }

    /// Combine graft's provisioning status with Tart's coarse running/stopped. Active phases
    /// win over Tart's state — while creating/booting the VM is "stopped" to Tart but very
    /// much in progress.
    private func state(_ nest: TartVM) -> (text: String, color: Color, busy: Bool) {
        let running = nest.state.lowercased() == "running"
        switch config.nestStatus(nest.name)?.phase {
        case .creating:     return ("creating image…", .orange, true)
        case .booting:      return ("booting…", .orange, true)
        case .provisioning: return (config.nestStatus(nest.name)?.detail ?? "provisioning…", .orange, true)
        case .failed:       return ("failed — \(config.nestStatus(nest.name)?.detail ?? "")", .red, false)
        case .ready:        return running ? ("ready", .green, false) : ("stopped", .secondary.opacity(0.5), false)
        case .none:         return running ? ("running", .green, false) : ("stopped", .secondary.opacity(0.5), false)
        }
    }

    /// True while any nest is mid-provision, or within the fast-poll window after an action.
    private var isBusy: Bool {
        if let until = fastUntil, Date() < until { return true }
        return nests.contains { nest in
            switch config.nestStatus(nest.name)?.phase {
            case .creating, .booting, .provisioning: return true
            default: return false
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            GraftMark(size: 40, color: Color(nsColor: .tertiaryLabelColor))
            Text("No nests yet").font(.headline)
            Text(config.graftAvailable
                 ? "Create one to clone a repo into a dev box and open it in VS Code."
                 : "Install the graft CLI, then create a dev box here.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if config.graftAvailable {
                Button { creating = true } label: { Label("New nest", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: Actions

    private func short(_ name: String) -> String { name.replacingOccurrences(of: "graft-dev-", with: "") }

    private func reload(silent: Bool = false) {
        if !silent { loading = true }
        Task {
            nests = await config.nests()
            loading = false
        }
    }

    private func openCode(_ nest: TartVM) {
        config.openNestInCode(short: short(nest.name))
        let msg = "Opening “\(short(nest.name))” in VS Code — it'll connect once the box is ready."
        note = msg
        fastUntil = Date().addingTimeInterval(180)
        // Fire-and-forget launch; clear the transient note after a bit so it doesn't stick.
        Task { try? await Task.sleep(nanoseconds: 8_000_000_000); if note == msg { note = nil } }
    }

    private func openShell(_ nest: TartVM) {
        config.openNestInTerminal(short: short(nest.name))
    }

    private func stop(_ name: String) {
        Task { await config.stopNest(name); reload(silent: true) }
    }

    private func remove(_ name: String) {
        Task { await config.removeNest(name); reload(silent: true) }
    }
}

/// Create a new nest: clone a repo (owner/repo or git URL) into a fresh box, on a chosen
/// base image (sapling). graft handles the clone + boot + VS Code; this just collects the
/// inputs so the launch stays non-interactive.
struct NewNestSheet: View {
    @ObservedObject var config: ConfigStore
    let onCreate: (_ target: String, _ image: String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var target = ""
    @State private var image = ""
    @State private var images: [String] = []

    private var valid: Bool { !target.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New nest").font(.headline).padding(16)
            Divider()
            Form {
                TextField("Repo", text: $target, prompt: Text("owner/repo  or  https://github.com/owner/repo"))
                LabeledContent("Image") {
                    HStack(spacing: 6) {
                        TextField("", text: $image, prompt: Text("default · pick a local image"))
                        if !images.isEmpty {
                            Menu("") {
                                ForEach(images, id: \.self) { img in Button(img) { image = img } }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Pick a local image (sapling)")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Text("graft clones the repo into a persistent box on the chosen image, then opens VS Code over Remote-SSH.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    onCreate(target.trimmingCharacters(in: .whitespaces),
                             image.trimmingCharacters(in: .whitespaces).isEmpty ? nil : image)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!valid)
            }
            .padding(16)
        }
        .frame(width: 460)
        .task { images = await config.localImages() }
    }
}
