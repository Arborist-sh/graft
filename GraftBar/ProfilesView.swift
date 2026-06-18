import SwiftUI
import AppKit
import GraftCore

/// Identifiable wrapper so a profile name can drive a `.sheet(item:)`. `isNew` opens the
/// same settings sheet in create mode (editable name, Save creates the profile).
struct EditTarget: Identifiable { let id = UUID(); let name: String; var isNew = false }

/// The Profiles section — list every profile, show which is active + a one-line summary,
/// switch the active one (restart-aware, via the runtime controller), create a skeleton
/// profile, or delete one. Pools + secrets for the selected profile live in their own
/// sections.
struct ProfilesView: View {
    @ObservedObject var config: ConfigStore
    @ObservedObject var controller: GraftController
    @AppStorage(Vocabulary.storageKey) private var vocab: Vocabulary = .standard

    @State private var pendingDelete: String?
    @State private var editTarget: EditTarget?
    /// Auth-check (the GUI's `arborist check`) state, keyed by the profile being checked.
    @State private var checkResults: [ConfigStore.CheckResult]?
    @State private var checkTitle = ""
    @State private var checkingProfile: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Lex.profiles(vocab)).font(.title2.weight(.semibold))
                Spacer()
                Button { revealProfilesFolder() } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button { editTarget = EditTarget(name: "", isNew: true) } label: {
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
        .sheet(item: $editTarget) { target in
            ProfileSettingsSheet(name: target.name, isNew: target.isNew, config: config)
        }
        .sheet(isPresented: Binding(get: { checkResults != nil }, set: { if !$0 { checkResults = nil } })) {
            AuthCheckSheet(title: checkTitle, results: checkResults ?? [])
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
            Button {
                checkingProfile = name
                Task {
                    let results = await config.verifyProfile(name)
                    checkTitle = "\(name) — auth check"
                    checkResults = results
                    checkingProfile = nil
                }
            } label: {
                if checkingProfile == name { ProgressView().controlSize(.small) } else { Text("Check") }
            }
            .disabled(checkingProfile != nil)
            .help("Verify GitHub App auth end-to-end (creates + deletes a probe runner)")
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
            Button { editTarget = EditTarget(name: "", isNew: true) } label: {
                Label("New profile", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Edit a profile's backend (Local Tart vs Orchard fleet) + its GitHub App info. Writes
/// back to the profile JSON, preserving pools / secrets / monitor. The Orchard *token* is
/// not here — it lives in the Keychain (Secrets section).
struct ProfileSettingsSheet: View {
    let name: String
    /// Create mode: editable name, Save creates a new profile. Editing: name is fixed.
    var isNew = false
    @ObservedObject var config: ConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var profileName = ""
    @State private var loaded: GraftConfig?
    @State private var pools: [PoolConfig] = []
    @State private var poolDraft: PoolDraft?
    @State private var importing = false
    @State private var orchard = false
    @State private var controllerURL = ""
    @State private var serviceAccount = ""
    @State private var maxVMs = ""
    /// Which keychain the Orchard service-account token lives in — follows the chosen
    /// account, recorded as `orchard.scope` on save.
    @State private var orchardScope: KeychainScope = .login
    @State private var appID = ""
    @State private var target = ""
    @State private var runnerGroup = "1"
    /// Which keychain the chosen App's key lives in — follows the App, recorded on save.
    @State private var scope: KeychainScope = .login

    /// Apps we hold a key for, across both keychains (dropdown source, each tagged with its
    /// scope); targets the chosen App can reach.
    @State private var scopedApps: [ConfigStore.ScopedApp] = []
    @State private var targets: [String] = []
    @State private var targetsLoading = false
    /// false → GitHub was unreachable (no key / offline / timeout); show the manual hint.
    @State private var targetsReached = true
    @State private var creatingApp = false
    @State private var addingAccount = false
    @State private var tokenPresent = false
    /// Service accounts holding a token in either keychain (reuse dropdown), each tagged
    /// with its scope.
    @State private var orchardAccounts: [ConfigStore.ScopedOrchardAccount] = []
    /// Auth-check (the GUI's `arborist check`) state.
    @State private var checkResults: [ConfigStore.CheckResult]?
    @State private var checking = false

    /// The profile's name: editable when creating, fixed when editing.
    private var finalName: String { (isNew ? profileName : name).trimmingCharacters(in: .whitespaces) }

    private var valid: Bool {
        if isNew {
            guard !finalName.isEmpty, !config.profiles.contains(finalName) else { return false }
        }
        guard orchard else { return true }
        return !controllerURL.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: controllerURL) != nil
            && !serviceAccount.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New profile" : "\(name) — settings").font(.headline).padding(16)
            Divider()
            Form {
                if isNew {
                    Section("Profile") {
                        TextField("Name", text: $profileName, prompt: Text("e.g. local, work-fleet"))
                        if !finalName.isEmpty, config.profiles.contains(finalName) {
                            Text("A profile named “\(finalName)” already exists.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Section("Backend") {
                    Picker("Provider", selection: $orchard) {
                        Text("Local Tart").tag(false)
                        Text("Orchard fleet").tag(true)
                    }
                    if orchard {
                        TextField("Controller URL", text: $controllerURL, prompt: Text("http://trunk.local:6120"))
                        LabeledContent("Service account") {
                            Menu {
                                ForEach(orchardAccounts) { acct in
                                    Button { serviceAccount = acct.account; orchardScope = acct.scope; refreshTokenPresence() } label: {
                                        let label = "\(acct.account)  (\(acct.scope.rawValue))"
                                        if acct.account == serviceAccount && acct.scope == orchardScope {
                                            Label(label, systemImage: "checkmark")
                                        } else { Text(label) }
                                    }
                                }
                                if !orchardAccounts.isEmpty { Divider() }
                                Button { addingAccount = true } label: { Label("Add account…", systemImage: "plus") }
                            } label: {
                                Text(serviceAccount.isEmpty ? "Choose…" : serviceAccount)
                            }
                            .fixedSize()
                        }
                        if !serviceAccount.trimmingCharacters(in: .whitespaces).isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: tokenPresent ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(tokenPresent ? Color.green : .orange)
                                Text(tokenPresent ? "token stored for “\(serviceAccount)”"
                                                  : "no token for “\(serviceAccount)” — Add account to set it")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        TextField("Max VMs", text: $maxVMs, prompt: Text("optional · default 100"))
                        Text("Pick an account you already have a token for, or **Add account** with the name + token your Orchard admin gave you. The token lives in the Keychain, never the profile file.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("GitHub") {
                    LabeledContent("App ID") {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                TextField("", text: $appID, prompt: Text("e.g. 4021920"))
                                    .onSubmit { syncScopeToApp(); reloadTargets() }
                                Menu("") {
                                    ForEach(scopedApps) { scoped in
                                        Button(appLabel(scoped)) {
                                            appID = String(scoped.app.id); scope = scoped.scope; reloadTargets()
                                        }
                                    }
                                    if !scopedApps.isEmpty { Divider() }
                                    Button { creatingApp = true } label: { Label("Create new App…", systemImage: "sparkles") }
                                    Button { importing = true } label: { Label("Import a .pem…", systemImage: "square.and.arrow.down") }
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Keychain Apps (login + system), create a new one, or import a .pem")
                            }
                            appKeyCaption
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
                    Text("Create or import the key right here, or manage keys in the Secrets section.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Pools") {
                    if pools.isEmpty {
                        Text("No pools yet — add at least one (a workload's runners: image, count, labels).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(pools.enumerated()), id: \.offset) { idx, pool in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(pool.name).font(.body.weight(.medium))
                                        Text("\(pool.os.rawValue) · ×\(pool.count)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(pool.image).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Button("Edit") { poolDraft = PoolDraft(from: pool, index: idx) }
                                Button(role: .destructive) { pools.remove(at: idx) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    Button { poolDraft = PoolDraft() } label: { Label("Add pool", systemImage: "plus") }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button {
                    guard let gh = currentGitHub() else { return }
                    checking = true
                    Task { let r = await config.verifyAuth(github: gh); checkResults = [r]; checking = false }
                } label: {
                    if checking { ProgressView().controlSize(.small) } else { Label("Verify auth", systemImage: "checkmark.shield") }
                }
                .disabled(checking || currentGitHub() == nil)
                .help("Check the App→installation→token chain end-to-end (creates + deletes a probe runner)")
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid)
            }
            .padding(16)
        }
        .frame(width: 460, height: 600)
        .onAppear(perform: load)
        .sheet(isPresented: $creatingApp) {
            CreateAppSheet { id, newScope in
                appID = String(id)
                scope = newScope
                scopedApps = config.scopedApps()
                reloadTargets()
            }
        }
        .sheet(isPresented: $importing) {
            ImportKeySheet { id, pem, keyName, newScope in importKey(id: id, pem: pem, name: keyName, scope: newScope) }
        }
        .sheet(isPresented: $addingAccount) {
            AddOrchardAccountSheet(defaultScope: orchardScope) { name, token, scope in addAccount(name: name, token: token, scope: scope) }
        }
        .sheet(item: $poolDraft) { d in
            PoolEditorSheet(draft: d, config: config) { applyPool($0) }
        }
        .sheet(isPresented: Binding(get: { checkResults != nil }, set: { if !$0 { checkResults = nil } })) {
            AuthCheckSheet(title: "\(finalName.isEmpty ? "new profile" : finalName) — auth check", results: checkResults ?? [])
        }
    }

    /// Store an imported .pem in the chosen keychain and select that App (mirrors the App
    /// step of the CLI wizard's bundled flow).
    private func importKey(id: Int, pem: String, name: String?, scope newScope: KeychainScope) {
        try? KeychainSecretStore(scope: newScope).store(pem: pem, forAppID: id, name: name)
        appID = String(id)
        scope = newScope
        scopedApps = config.scopedApps()
        reloadTargets()
    }

    /// Apply a pool draft to the local list (the whole profile is written on Save).
    private func applyPool(_ d: PoolDraft) {
        let pool = d.toPool()
        if let i = d.index, pools.indices.contains(i) { pools[i] = pool } else { pools.append(pool) }
    }

    /// Build a GitHubConfig from the current fields, or nil if App ID/target aren't ready.
    private func currentGitHub() -> GitHubConfig? {
        let cleanTarget = target.trimmingCharacters(in: .whitespaces)
        guard let id = Int(appID.trimmingCharacters(in: .whitespaces)), !cleanTarget.isEmpty else { return nil }
        let group = cleanTarget.hasPrefix("org:") ? (Int(runnerGroup.trimmingCharacters(in: .whitespaces)) ?? 1) : 1
        return GitHubConfig(appId: id, target: cleanTarget, runnerGroupId: group, scope: scope)
    }

    /// Dropdown label for an App: "name (id) — scope" (or "App id — scope" with no name).
    private func appLabel(_ scoped: ConfigStore.ScopedApp) -> String {
        let base = scoped.app.name.map { "\($0)  (\(String(scoped.app.id)))" } ?? "App \(String(scoped.app.id))"
        return "\(base) — \(scoped.scope.rawValue)"
    }

    /// Caption under the App ID: confirm the key (and where it lives), or warn it's missing.
    @ViewBuilder private var appKeyCaption: some View {
        if let id = Int(appID.trimmingCharacters(in: .whitespaces)) {
            if let match = scopedApps.first(where: { $0.app.id == id }) {
                Text("\(match.app.name.map { "\($0) · " } ?? "")key in \(match.scope.rawValue) keychain")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("⚠ no stored key for App \(id) — use Create or Import in the menu above")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// When an App ID is typed by hand, point `scope` at wherever its key actually lives.
    private func syncScopeToApp() {
        if let id = Int(appID.trimmingCharacters(in: .whitespaces)), let s = config.scope(forAppID: id) { scope = s }
    }

    private func load() {
        scopedApps = config.scopedApps()
        orchardAccounts = config.scopedOrchardAccounts()
        // Create mode starts from local-Tart defaults with no pools to fill in.
        guard !isNew, let c = config.config(name) else { return }
        loaded = c
        pools = c.pools
        if let o = c.orchard {
            orchard = true
            controllerURL = o.controllerURL.absoluteString
            serviceAccount = o.serviceAccount
            maxVMs = o.maxVMs.map(String.init) ?? ""
            orchardScope = o.scope
        }
        if let gh = c.github {
            appID = String(gh.appId)
            target = gh.target
            runnerGroup = String(gh.runnerGroupId)
            scope = gh.scope
        }
        reloadTargets()
        refreshTokenPresence()
    }

    // MARK: Orchard token (kept in the Keychain, keyed by service account + its scope)

    private var tokenStore: KeychainSecretStore { KeychainSecretStore(scope: orchardScope) }

    private func refreshTokenPresence() {
        let account = serviceAccount.trimmingCharacters(in: .whitespaces)
        tokenPresent = !account.isEmpty && tokenStore.hasOrchardToken(account: account)
    }

    /// Add (or replace) a service account: store its token in the chosen keychain under
    /// `name`, record that scope, and select it. Replacing is just re-adding (store is
    /// delete-then-add).
    private func addAccount(name: String, token: String, scope: KeychainScope) {
        let account = name.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty else { return }
        orchardScope = scope
        try? KeychainSecretStore(scope: scope).storeOrchardToken(token, account: account)
        serviceAccount = account
        orchardAccounts = config.scopedOrchardAccounts()
        refreshTokenPresence()
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
        // Editing preserves the rest of the config (monitor, etc.); creating starts fresh.
        var c = isNew ? GraftConfig(provider: .tart) : (loaded ?? config.config(name) ?? GraftConfig())
        if orchard, let url = URL(string: controllerURL) {
            c.provider = .orchard(OrchardConfig(
                controllerURL: url,
                serviceAccount: serviceAccount.trimmingCharacters(in: .whitespaces),
                token: c.orchard?.token,
                maxVMs: Int(maxVMs.trimmingCharacters(in: .whitespaces)),
                scope: orchardScope
            ))
        } else {
            c.provider = .tart
        }
        // `scope` follows the chosen App (set when picked from the dropdown or typed), so
        // the recorded keychain always matches where the key actually lives.
        c.github = currentGitHub()
        c.pools = pools
        guard !finalName.isEmpty else { return }
        config.save(c, as: finalName)
        config.selected = finalName   // point the Pools/Secrets sections at it
    }
}

/// Add (or replace) an Orchard service account: the **name** and **token** your Orchard
/// admin gave you, captured together (a new account is meaningless without both). The
/// token goes to the Keychain keyed by the name; graft never mints accounts (§ control-plane
/// design doc) — it only stores what the admin issued.
struct AddOrchardAccountSheet: View {
    let defaultScope: KeychainScope
    let onAdd: (_ name: String, _ token: String, _ scope: KeychainScope) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var token = ""
    @State private var scope: KeychainScope = .login

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add service account").font(.headline)
            Text("Both come from your Orchard admin — the account they created on the trunk, and its token.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Account name", text: $name, prompt: Text("e.g. graft"))
                SecureField("Token", text: $token)
                Section("Store the token in") { KeychainScopePicker(scope: $scope) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { onAdd(name, token, scope); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { scope = defaultScope }
    }
}

/// Renders the result(s) of an auth check (the GUI's `graft arborist check`) — one section
/// per App+target, each a list of ✓/✗ steps. Shared by Profiles, the profile editor, and
/// Secrets. The header seal is green only when every step of every result passed.
struct AuthCheckSheet: View {
    let title: String
    let results: [ConfigStore.CheckResult]
    @Environment(\.dismiss) private var dismiss

    private var allPassed: Bool { !results.isEmpty && results.allSatisfy(\.passed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: allPassed ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(allPassed ? Color.green : .red)
                Text(title).font(.headline)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(result.title).font(.subheadline.weight(.semibold))
                            ForEach(result.steps) { step in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: step.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(step.ok ? Color.green : .red)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(step.label)
                                        if let detail = step.detail {
                                            Text(detail).font(.caption).foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent) }
                .padding(16)
        }
        .frame(width: 480, height: 440)
    }
}
