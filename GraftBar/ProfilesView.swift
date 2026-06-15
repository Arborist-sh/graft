import SwiftUI
import AppKit
import GraftCore

/// Identifiable wrapper so a profile name can drive a `.sheet(item:)`.
struct EditTarget: Identifiable { let id = UUID(); let name: String }

/// The Profiles section — list every profile, show which is active + a one-line summary,
/// switch the active one (restart-aware, via the runtime controller), create a skeleton
/// profile, or delete one. Pools + secrets for the selected profile live in their own
/// sections.
struct ProfilesView: View {
    @ObservedObject var config: ConfigStore
    @ObservedObject var controller: GraftController

    @State private var creating = false
    @State private var newName = ""
    @State private var pendingDelete: String?
    @State private var editTarget: EditTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Profiles").font(.title2.weight(.semibold))
                Spacer()
                Button { revealProfilesFolder() } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button { newName = ""; creating = true } label: {
                    Label("New profile", systemImage: "plus")
                }
            }
            .padding(16)
            Divider()

            if config.profiles.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(config.profiles, id: \.self, content: row)
                }
                .listStyle(.inset)
            }
        }
        .onAppear { config.reload() }
        .sheet(isPresented: $creating) { createSheet }
        .sheet(item: $editTarget) { target in
            ProfileSettingsSheet(name: target.name, config: config)
        }
        .confirmationDialog(
            "Delete profile “\(pendingDelete ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let n = pendingDelete { config.remove(n) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Removes the profile's config. Any secrets in the Keychain are left untouched.")
        }
    }

    private func row(_ name: String) -> some View {
        let isActive = name == config.active
        return HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.green : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.body.weight(.medium))
                    if isActive {
                        Text("active")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(summary(name)).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if !isActive {
                Button("Use") {
                    controller.useProfile(name)
                    config.reload()
                }
                .disabled(controller.isRunning)
                .help(controller.isRunning ? "Stop the fleet to switch the active profile" : "Make this the active profile")
            }
            Button("Edit") { editTarget = EditTarget(name: name) }
            Button(role: .destructive) { pendingDelete = name } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isActive)
            .help(isActive ? "Can't delete the active profile" : "Delete profile")
        }
        .padding(.vertical, 4)
    }

    /// One-line "backend · N pools · target" summary, read live from the profile JSON.
    private func summary(_ name: String) -> String {
        guard let c = config.config(name) else { return "unreadable (old schema?)" }
        let pools = c.pools.count
        let target = c.github?.target ?? c.pools.first?.github?.target
        let tgt = target.map { " · \($0)" } ?? ""
        return "\(c.provider.typeName) · \(pools) pool\(pools == 1 ? "" : "s")\(tgt)"
    }

    private func revealProfilesFolder() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".graft/profiles")
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            GraftMark(size: 40, color: Color(nsColor: .tertiaryLabelColor))
            Text("No profiles").font(.headline)
            Text("Create one to configure a fleet.").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New profile").font(.headline)
            TextField("Name (e.g. local, work-fleet)", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { if config.create(newName) { creating = false } }
            Text("Creates a local-Tart profile with no pools — add pools + secrets next.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { creating = false }
                Button("Create") { if config.create(newName) { creating = false } }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Edit a profile's backend (Local Tart vs Orchard fleet) + its GitHub App info. Writes
/// back to the profile JSON, preserving pools / secrets / monitor. The Orchard *token* is
/// not here — it lives in the Keychain (Secrets section).
struct ProfileSettingsSheet: View {
    let name: String
    @ObservedObject var config: ConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var loaded: GraftConfig?
    @State private var orchard = false
    @State private var controllerURL = ""
    @State private var serviceAccount = ""
    @State private var maxVMs = ""
    @State private var appID = ""
    @State private var target = ""
    @State private var runnerGroup = "1"

    /// Apps we hold a key for (dropdown source); targets the chosen App can reach.
    @State private var apps: [KeychainSecretStore.StoredApp] = []
    @State private var targets: [String] = []
    @State private var targetsLoading = false
    /// false → GitHub was unreachable (no key / offline / timeout); show the manual hint.
    @State private var targetsReached = true
    @State private var creatingApp = false

    private var valid: Bool {
        guard orchard else { return true }
        return !controllerURL.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: controllerURL) != nil
            && !serviceAccount.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(name) — settings").font(.headline).padding(16)
            Divider()
            Form {
                Section("Backend") {
                    Picker("Provider", selection: $orchard) {
                        Text("Local Tart").tag(false)
                        Text("Orchard fleet").tag(true)
                    }
                    if orchard {
                        TextField("Controller URL", text: $controllerURL, prompt: Text("http://trunk.local:6120"))
                        TextField("Service account", text: $serviceAccount, prompt: Text("graft"))
                        TextField("Max VMs", text: $maxVMs, prompt: Text("optional · default 100"))
                    }
                }
                Section("GitHub") {
                    LabeledContent("App ID") {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                TextField("", text: $appID, prompt: Text("e.g. 4021920"))
                                    .onSubmit { reloadTargets() }
                                Menu("") {
                                    ForEach(apps, id: \.id) { app in
                                        Button(app.name.map { "\($0)  (\(String(app.id)))" } ?? "App \(String(app.id))") {
                                            appID = String(app.id); reloadTargets()
                                        }
                                    }
                                    if !apps.isEmpty { Divider() }
                                    Button { creatingApp = true } label: { Label("Create new App…", systemImage: "sparkles") }
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Keychain Apps, or create a new one")
                            }
                            if let id = Int(appID.trimmingCharacters(in: .whitespaces)),
                               let name = apps.first(where: { $0.id == id })?.name {
                                Text(name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent("Target") {
                        HStack(spacing: 6) {
                            TextField("", text: $target, prompt: Text("repo:owner/name  ·  org:name"))
                            if targetsLoading {
                                ProgressView().controlSize(.small)
                            } else if !targets.isEmpty {
                                Menu("") {
                                    ForEach(targets, id: \.self) { t in
                                        Button(t) { target = t }
                                    }
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Orgs + repos this App can reach")
                            }
                        }
                    }
                    if !targetsLoading, !targetsReached, Int(appID.trimmingCharacters(in: .whitespaces)) != nil {
                        Text("Couldn't reach GitHub for the target list — type it manually, or import the App key in Secrets.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if target.trimmingCharacters(in: .whitespaces).hasPrefix("org:") {
                        TextField("Runner group", text: $runnerGroup, prompt: Text("1"))
                        Text("Org runner-group id (Default = 1). Repos always use the default group.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("The App private key is set in the Secrets section.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid)
            }
            .padding(16)
        }
        .frame(width: 460, height: 520)
        .onAppear(perform: load)
        .sheet(isPresented: $creatingApp) {
            CreateAppSheet { id in
                appID = String(id)
                apps = config.storedApps()
                reloadTargets()
            }
        }
    }

    private func load() {
        guard let c = config.config(name) else { return }
        loaded = c
        if let o = c.orchard {
            orchard = true
            controllerURL = o.controllerURL.absoluteString
            serviceAccount = o.serviceAccount
            maxVMs = o.maxVMs.map(String.init) ?? ""
        }
        if let gh = c.github {
            appID = String(gh.appId)
            target = gh.target
            runnerGroup = String(gh.runnerGroupId)
        }
        apps = config.storedApps()
        reloadTargets()
    }

    /// Refresh the target dropdown for the current App ID (network, off the main actor via
    /// ConfigStore). No-op if the App ID field isn't a number yet.
    private func reloadTargets() {
        guard let id = Int(appID.trimmingCharacters(in: .whitespaces)) else {
            targets = []; targetsReached = true; targetsLoading = false; return
        }
        targetsLoading = true
        Task {
            let result = await config.accessibleTargets(appID: id)
            targetsLoading = false
            targetsReached = result != nil
            targets = result ?? []
        }
    }

    private func save() {
        guard var c = loaded ?? config.config(name) else { return }
        if orchard, let url = URL(string: controllerURL) {
            c.provider = .orchard(OrchardConfig(
                controllerURL: url,
                serviceAccount: serviceAccount.trimmingCharacters(in: .whitespaces),
                token: c.orchard?.token,
                maxVMs: Int(maxVMs.trimmingCharacters(in: .whitespaces))
            ))
        } else {
            c.provider = .tart
        }
        let cleanTarget = target.trimmingCharacters(in: .whitespaces)
        if let id = Int(appID.trimmingCharacters(in: .whitespaces)), !cleanTarget.isEmpty {
            // Runner groups only exist for orgs; repo runners always use the default (1).
            let group = cleanTarget.hasPrefix("org:")
                ? (Int(runnerGroup.trimmingCharacters(in: .whitespaces)) ?? 1)
                : 1
            c.github = GitHubConfig(appId: id, target: cleanTarget, runnerGroupId: group)
        } else {
            c.github = nil
        }
        config.save(c, as: name)
    }
}
