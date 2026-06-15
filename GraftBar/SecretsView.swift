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

    @State private var apps: [KeychainSecretStore.StoredApp] = []
    @State private var importing = false
    @State private var creatingApp = false
    @State private var fetchingNames = false
    @State private var settingToken = false
    @State private var pendingRemove: Int?
    @State private var status: String?

    private var store: KeychainSecretStore { KeychainSecretStore(scope: .login) }

    /// The Orchard service account for the selected profile, if it's an Orchard profile.
    private var orchardAccount: String? {
        config.selected.flatMap { config.config($0)?.orchard?.serviceAccount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Secrets").font(.title2.weight(.semibold))
                Spacer()
                Text("login keychain").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    githubKeys
                    if let account = orchardAccount { orchardToken(account: account) }
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: refresh)
        .sheet(isPresented: $importing) {
            ImportKeySheet { id, pem in importKey(id: id, pem: pem) }
        }
        .sheet(isPresented: $creatingApp) {
            CreateAppSheet { id in status = "Created App \(id) — its key is stored."; refresh() }
        }
        .sheet(isPresented: $settingToken) {
            if let account = orchardAccount {
                SetTokenSheet(account: account) { token in setToken(token, account: account) }
            }
        }
        .confirmationDialog(
            "Remove the key for App \(String(pendingRemove ?? 0))?",
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { if let id = pendingRemove { removeKey(id) }; pendingRemove = nil }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        }
    }

    // MARK: GitHub App keys

    private var githubKeys: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("GitHub App keys", systemImage: "key").font(.headline)
                Spacer()
                if apps.contains(where: { $0.name == nil }) {
                    Button { fetchNames() } label: {
                        if fetchingNames { ProgressView().controlSize(.small) }
                        else { Label("Fetch names", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(fetchingNames)
                    .help("Look up display names from GitHub for keys that don't have one")
                }
                Button { creatingApp = true } label: { Label("Create App…", systemImage: "sparkles") }
                Button { importing = true } label: { Label("Import key…", systemImage: "plus") }
            }
            if apps.isEmpty {
                Text("No GitHub App private keys stored. Create a new App, or import an existing key.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(apps, id: \.id) { app in
                    HStack {
                        Image(systemName: "key.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name ?? "App \(String(app.id))").font(.body.weight(.medium))
                            Text(app.name != nil ? "App \(String(app.id))" : "no name yet")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { pendingRemove = app.id } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    // MARK: Orchard token

    private func orchardToken(account: String) -> some View {
        let present = store.orchardToken(account: account) != nil
        return VStack(alignment: .leading, spacing: 8) {
            Label("Orchard token", systemImage: "lock").font(.headline)
            HStack {
                Image(systemName: present ? "checkmark.seal.fill" : "xmark.seal")
                    .foregroundStyle(present ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("service account: \(account)").font(.body.weight(.medium))
                    Text(present ? "token stored" : "no token set")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(present ? "Replace…" : "Set token…") { settingToken = true }
                if present {
                    Button(role: .destructive) { clearToken(account: account) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: Actions

    private func refresh() {
        apps = config.storedApps()
    }

    private func fetchNames() {
        fetchingNames = true
        Task {
            let n = await config.fetchAppNames()
            refresh()
            status = n > 0 ? "Resolved \(n) name\(n == 1 ? "" : "s") from GitHub." : "No names to resolve (or GitHub unreachable)."
            fetchingNames = false
        }
    }

    private func importKey(id: Int, pem: String) {
        do {
            try store.store(pem: pem, forAppID: id)
            status = "Stored key for App \(id)."
            refresh()
        } catch {
            status = "Couldn't store key: \(error.localizedDescription)"
        }
    }

    private func removeKey(_ id: Int) {
        do { try store.remove(appID: id); status = "Removed key for App \(id)."; refresh() }
        catch { status = "Couldn't remove key: \(error.localizedDescription)" }
    }

    private func setToken(_ token: String, account: String) {
        do { try store.storeOrchardToken(token, account: account); status = "Saved Orchard token." }
        catch { status = "Couldn't save token: \(error.localizedDescription)" }
    }

    private func clearToken(account: String) {
        do { try store.removeOrchardToken(account: account); status = "Cleared Orchard token." }
        catch { status = "Couldn't clear token: \(error.localizedDescription)" }
    }
}

/// Import a GitHub App private key: App ID + the PEM (pasted, or read from a .pem file).
struct ImportKeySheet: View {
    let onImport: (Int, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var appIDText = ""
    @State private var pem = ""

    private var valid: Bool { Int(appIDText.trimmingCharacters(in: .whitespaces)) != nil && !pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import GitHub App key").font(.headline)
            HStack {
                Text("App ID").frame(width: 70, alignment: .leading)
                TextField("e.g. 4021920", text: $appIDText).frame(width: 160)
            }
            HStack {
                Text("Private key").font(.subheadline)
                Spacer()
                Button("Choose .pem…") { chooseFile() }
            }
            TextEditor(text: $pem)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            Text("Pasted here or read from a file — stored in your login Keychain, never written to disk by graft.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") {
                    if let id = Int(appIDText.trimmingCharacters(in: .whitespaces)) { onImport(id, pem); dismiss() }
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
        if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) {
            pem = text
        }
    }
}

/// Create a brand-new GitHub App via the manifest flow. Opens the browser to GitHub's
/// one-click create page (pre-filled with the permissions runners need), catches the
/// redirect on a loopback server, and stores the returned private key in the Keychain —
/// no manual App ID copy, no .pem download. The user's only manual steps are clicking
/// "Create" and (after) "Install" on github.com.
struct CreateAppSheet: View {
    /// Called with the new App's ID once it's created and its key stored. Lets the caller
    /// refresh its key list and/or select the new App.
    let onCreated: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var useOrg = false
    @State private var org = ""
    @State private var name = ""
    @State private var running = false
    @State private var status: String?
    @State private var created: AppManifestFlow.Created?

    private var store: KeychainSecretStore { KeychainSecretStore(scope: .login) }
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
                if let status {
                    Section { Text(status).font(.callout) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if running { ProgressView().controlSize(.small); Text("Waiting for GitHub…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if created != nil {
                    Button("Install App…") { openInstall() }
                        .buttonStyle(.borderedProminent)
                    Button("Done") { finish() }
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
                try store.store(pem: result.pem, forAppID: result.appID)
                created = result
                status = "✓ Created “\(result.name)” (App \(result.appID)) and stored its key. Now install it."
            } catch {
                status = "Failed: \(error.localizedDescription)"
            }
            running = false
        }
    }

    private func openInstall() {
        if let c = created, let url = URL(string: c.installURL) { NSWorkspace.shared.open(url) }
    }

    private func finish() {
        if let c = created { onCreated(c.appID) }
        dismiss()
    }
}

/// Set/replace the Orchard service-account token (entered securely).
struct SetTokenSheet: View {
    let account: String
    let onSet: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Orchard token").font(.headline)
            Text("for service account “\(account)”").font(.caption).foregroundStyle(.secondary)
            SecureField("token", text: $token).frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSet(token); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
