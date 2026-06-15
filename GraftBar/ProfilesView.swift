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
                    TextField("App ID", text: $appID, prompt: Text("e.g. 4021920"))
                    TextField("Target", text: $target, prompt: Text("repo:owner/name  or  org:name"))
                    TextField("Runner group", text: $runnerGroup, prompt: Text("1"))
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
        if let id = Int(appID.trimmingCharacters(in: .whitespaces)),
           !target.trimmingCharacters(in: .whitespaces).isEmpty {
            c.github = GitHubConfig(
                appId: id,
                target: target.trimmingCharacters(in: .whitespaces),
                runnerGroupId: Int(runnerGroup.trimmingCharacters(in: .whitespaces)) ?? 1
            )
        } else {
            c.github = nil
        }
        config.save(c, as: name)
    }
}
