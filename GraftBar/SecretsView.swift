import SwiftUI
import GraftCore
import AppKit

/// The Secrets section — manage the credentials graft keeps in the macOS Keychain: the
/// GitHub App private key(s) and (for Orchard profiles) the service-account token. The
/// *user* supplies the secret (paste or pick a file); this just stores it via
/// `KeychainSecretStore`. Note: Keychain ACLs bind to the binary's signature, so reading
/// keys the CLI stored (or vice-versa) may prompt for access once ("Always Allow").
struct SecretsView: View {
    @ObservedObject var config: ConfigStore

    @AppStorage(Vocabulary.storageKey) private var vocab: Vocabulary = .standard
    @State private var apps: [ConfigStore.ScopedApp] = []
    @State private var importing = false
    @State private var creatingApp = false
    @State private var fetchingNames = false
    @State private var pendingRemove: ConfigStore.ScopedApp?
    @State private var status: String?
    /// Auth-check (the GUI's `arborist check`) for a single key.
    @State private var checkResults: [ConfigStore.CheckResult]?
    @State private var checkingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Lex.secrets(vocab)).font(.title2.weight(.semibold))
                Spacer()
                Text("login + system keychains").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    githubKeys
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: refresh)
        .sheet(isPresented: $importing) {
            ImportKeySheet { id, pem, name, scope in importKey(id: id, pem: pem, name: name, scope: scope) }
        }
        .sheet(isPresented: $creatingApp) {
            CreateAppSheet { id, scope in status = "Created App \(id) — key stored in the \(scope.rawValue) keychain."; refresh() }
        }
        .sheet(isPresented: Binding(get: { checkResults != nil }, set: { if !$0 { checkResults = nil } })) {
            AuthCheckSheet(title: "Key check", results: checkResults ?? [])
        }
        .confirmationDialog(
            "Remove the key for App \(String(pendingRemove?.app.id ?? 0))?",
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { if let p = pendingRemove { removeKey(p) }; pendingRemove = nil }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("Removes it from the \(pendingRemove?.scope.rawValue ?? "login") keychain.")
        }
    }

    // MARK: GitHub App keys

    private var githubKeys: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("GitHub App keys", systemImage: "key").font(.headline)
                Spacer()
                if !apps.isEmpty {
                    Button { fetchNames() } label: {
                        if fetchingNames { ProgressView().controlSize(.small) }
                        else { Label("Fetch names", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(fetchingNames)
                    .help("Look up / re-check display names from GitHub")
                }
                Button { creatingApp = true } label: { Label("Create App…", systemImage: "sparkles") }
                Button { importing = true } label: { Label("Import key…", systemImage: "plus") }
            }
            if apps.isEmpty {
                Text("No GitHub App private keys stored. Create a new App, or import an existing key.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(apps) { scoped in
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(scoped.app.name ?? "App \(String(scoped.app.id))").font(.body.weight(.medium))
                            Text(scoped.app.name != nil ? "App \(String(scoped.app.id))" : "no name yet")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(scoped.scope.rawValue)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            checkingID = scoped.id
                            Task { let r = await config.verifyKey(appID: scoped.app.id, scope: scoped.scope); checkResults = [r]; checkingID = nil }
                        } label: {
                            if checkingID == scoped.id { ProgressView().controlSize(.small) }
                            else { Text("Test") }
                        }
                        .disabled(checkingID != nil)
                        .help("Verify this key signs an App JWT and the App is installed")
                        Button(role: .destructive) { pendingRemove = scoped } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    // MARK: Actions

    private func refresh() {
        apps = config.scopedApps()
    }

    private func fetchNames() {
        fetchingNames = true
        Task {
            let (n, warnings) = await config.fetchAppNames(force: true)
            refresh()
            if !warnings.isEmpty {
                status = "⚠️ " + warnings.joined(separator: "  ")
            } else {
                status = n > 0 ? "Resolved \(n) name\(n == 1 ? "" : "s") from GitHub." : "No names to resolve (or GitHub unreachable)."
            }
            fetchingNames = false
        }
    }

    private func importKey(id: Int, pem: String, name: String?, scope: KeychainScope) {
        do {
            try KeychainSecretStore(scope: scope).store(pem: pem, forAppID: id, name: name)
            status = "Stored key for \(name ?? "App \(String(id))") in the \(scope.rawValue) keychain."
            refresh()
        } catch {
            status = "Couldn't store key: \(error.localizedDescription)"
        }
    }

    private func removeKey(_ scoped: ConfigStore.ScopedApp) {
        do {
            try KeychainSecretStore(scope: scoped.scope).remove(appID: scoped.app.id)
            status = "Removed key for App \(scoped.app.id) from the \(scoped.scope.rawValue) keychain."
            refresh()
        } catch { status = "Couldn't remove key: \(error.localizedDescription)" }
    }
}

/// Import a GitHub App private key. Picking the .pem GitHub gave you auto-detects the App
/// ID + name from its filename (`‹slug›.‹date›.private-key.pem` → public GET /apps/{slug}),
/// so you usually just choose the file and hit Import. The App ID stays editable for keys
/// you pasted or renamed. (GitHub never exposes an existing key over the API, so the file
/// is the one thing that must come from you.)
struct ImportKeySheet: View {
    let onImport: (Int, String, String?, KeychainScope) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var appIDText = ""
    @State private var pem = ""
    @State private var detectedName: String?
    @State private var looking = false
    @State private var note: String?
    @State private var scope: KeychainScope = .login

    private var valid: Bool { Int(appIDText.trimmingCharacters(in: .whitespaces)) != nil && !pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import GitHub App key").font(.headline)
            HStack {
                Text("App ID").frame(width: 70, alignment: .leading)
                TextField("e.g. 4021920", text: $appIDText).frame(width: 160)
                    .onChange(of: appIDText) { detectedName = nil }
                if looking { ProgressView().controlSize(.small) }
                if let detectedName { Text(detectedName).font(.callout.weight(.medium)).foregroundStyle(.secondary) }
            }
            HStack {
                Text("Private key").font(.subheadline)
                Spacer()
                Button("Choose .pem…") { chooseFile() }
            }
            TextEditor(text: $pem)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Store the key in").font(.subheadline)
                KeychainScopePicker(scope: $scope)
            }
            Text(note ?? "Choose the .pem GitHub gave you — graft auto-detects the App ID + name. Stored in the Keychain, never written to disk by graft.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") {
                    if let id = Int(appIDText.trimmingCharacters(in: .whitespaces)) { onImport(id, pem, detectedName, scope); dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        pem = text
        guard let slug = Self.slug(fromFilename: url.lastPathComponent) else {
            note = "Loaded the key — enter the App ID (couldn't read it from the file name)."
            return
        }
        looking = true
        note = "Looking up “\(slug)” on GitHub…"
        Task {
            if let info = try? await GitHubAppClient.publicAppInfo(slug: slug) {
                appIDText = String(info.id)
                detectedName = info.name
                note = "Detected \(info.name) (App \(String(info.id))) from the file name."
            } else {
                note = "Loaded the key — couldn't auto-detect the App, enter the App ID manually."
            }
            looking = false
        }
    }

    /// Pull the App slug out of GitHub's key filename: `‹slug›.‹YYYY-MM-DD›.private-key.pem`.
    static func slug(fromFilename name: String) -> String? {
        guard name.hasSuffix(".pem") else { return nil }
        var s = String(name.dropLast(4))                              // .pem
        if s.hasSuffix(".private-key") { s = String(s.dropLast(12)) } // .private-key
        if let r = s.range(of: #"\.\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            s = String(s[s.startIndex..<r.lowerBound])                // .YYYY-MM-DD
        }
        return s.isEmpty ? nil : s
    }
}

/// Create a brand-new GitHub App via the manifest flow. Opens the browser to GitHub's
/// one-click create page (pre-filled with the permissions runners need), catches the
/// redirect on a loopback server, and stores the returned private key in the Keychain —
/// no manual App ID copy, no .pem download. The user's only manual steps are clicking
/// "Create" and (after) "Install" on github.com.
struct CreateAppSheet: View {
    /// Called with the new App's ID and the keychain its key was stored in, once it's
    /// created. Lets the caller refresh its key list and/or select the new App.
    let onCreated: (Int, KeychainScope) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var useOrg = false
    @State private var org = ""
    @State private var name = ""
    @State private var scope: KeychainScope = .login
    @State private var running = false
    @State private var status: String?
    @State private var created: AppManifestFlow.Created?
    @State private var awaitingInstall = false
    @State private var installed = false

    private var store: KeychainSecretStore { KeychainSecretStore(scope: scope) }
    private var orgValid: Bool { !useOrg || !org.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Create GitHub App").font(.headline).padding(16)
            Divider()
            Form {
                Section {
                    Picker("Create under", selection: $useOrg) {
                        Text("Your account").tag(false)
                        Text("Organization").tag(true)
                    }
                    if useOrg {
                        TextField("Organization", text: $org, prompt: Text("org login (you must be an owner)"))
                    }
                    TextField("App name", text: $name, prompt: Text("optional · must be globally unique"))
                } footer: {
                    Text("graft pre-fills the permissions runners need and turns webhooks off. You'll click “Create GitHub App” in your browser, then install it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if created == nil {
                    Section("Store the key in") { KeychainScopePicker(scope: $scope) }
                }
                if let status {
                    Section { Text(status).font(.callout) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if running { ProgressView().controlSize(.small); Text("Waiting for GitHub…").font(.caption).foregroundStyle(.secondary) }
                else if awaitingInstall { ProgressView().controlSize(.small); Text("Waiting for installation…").font(.caption).foregroundStyle(.secondary) }
                else if installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text("Installed").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if created != nil {
                    if !installed {
                        Button("Install App…") { openInstall() }
                            .buttonStyle(.borderedProminent)
                            .disabled(awaitingInstall)
                    }
                    if installed {
                        Button("Done") { finish() }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Done") { finish() }
                    }
                } else {
                    Button("Cancel") { dismiss() }
                    Button("Create") { create() }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || !orgValid)
                }
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    private func create() {
        running = true
        status = "Opening your browser — click “Create GitHub App”, then return here."
        let account: AppManifestFlow.Account =
            useOrg ? .org(org.trimmingCharacters(in: .whitespaces)) : .user
        let appName = name.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let result = try await AppManifestFlow.run(account: account, name: appName.isEmpty ? nil : appName) { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                try store.store(pem: result.pem, forAppID: result.appID, name: result.name)
                created = result
                status = "✓ Created “\(result.name)” (App \(String(result.appID))) and stored its key. Now install it."
            } catch {
                status = "Failed: \(error.localizedDescription)"
            }
            running = false
        }
    }

    private func openInstall() {
        guard let c = created, let url = URL(string: c.installURL) else { return }
        NSWorkspace.shared.open(url)
        startInstallWatch()
    }

    /// After opening the install page, poll GitHub until the App shows up as installed
    /// somewhere (a brand-new App starts with zero installations), so we can confirm the
    /// step actually completed instead of leaving the user guessing.
    private func startInstallWatch() {
        guard let c = created else { return }
        awaitingInstall = true
        Task {
            let client = GitHubAppClient(appID: c.appID, secrets: store)
            let deadline = Date().addingTimeInterval(300)
            while awaitingInstall, Date() < deadline {
                if let installs = try? await client.installations(), !installs.isEmpty {
                    let where_ = installs.map(\.account.login).joined(separator: ", ")
                    installed = true
                    awaitingInstall = false
                    status = "✓ Installed on \(where_)."
                    return
                }
                // 1s poll — at most ~300 hits over the 5-min window, trivial against the
                // App JWT's ~5k/hr budget; makes the "installed" flip feel instant.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            awaitingInstall = false
        }
    }

    private func finish() {
        awaitingInstall = false
        if let c = created { onCreated(c.appID, scope) }
        dismiss()
    }
}

/// Pick where a key is stored: the login keychain, the system keychain, or a custom
/// keychain by path. Mirrors the CLI wizard's storage prompt. Binds a `KeychainScope`.
struct KeychainScopePicker: View {
    @Binding var scope: KeychainScope

    private enum Mode { case login, system, file }
    @State private var mode: Mode = .login
    @State private var path = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $mode) {
                Text("Login").tag(Mode.login)
                Text("System").tag(Mode.system)
                Text("Other…").tag(Mode.file)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: mode) { syncOut() }
            if mode == .file {
                TextField("Keychain path", text: $path, prompt: Text("/path/to/Custom.keychain"))
                    .onChange(of: path) { syncOut() }
            }
            if mode == .system {
                Text("Writing the system keychain needs admin rights — macOS will prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            switch scope {
            case .login: mode = .login
            case .system: mode = .system
            case .file(let p): mode = .file; path = p
            }
        }
    }

    private func syncOut() {
        switch mode {
        case .login: scope = .login
        case .system: scope = .system
        case .file: scope = .file(path)
        }
    }
}
