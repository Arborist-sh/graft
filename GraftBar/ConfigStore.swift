import SwiftUI
import Foundation
import GraftCore

/// Observable bridge for the config sections (Profiles / Pools / Secrets). Reads + writes
/// the same profile JSON the CLI uses, via `GraftCore.Profiles` — no shelling, no parsing.
/// Kept separate from `GraftController` (which owns the *runtime* daemon state) so the
/// config UI and the dashboard don't entangle.
@MainActor
final class ConfigStore: ObservableObject {
    @Published var profiles: [String] = []
    @Published var active: String?
    /// The profile currently being edited in the Pools / Secrets sections (defaults to
    /// active). Kept here so those sections share one selection.
    @Published var selected: String?

    init() { reload() }

    func reload() {
        profiles = Profiles.names().sorted()
        active = Profiles.activeName()
        if selected == nil || !profiles.contains(selected!) {
            selected = active ?? profiles.first
        }
    }

    /// The parsed config for a profile, or nil if missing/unreadable (e.g. an old-schema file).
    func config(_ name: String) -> GraftConfig? { try? Profiles.load(name) }

    func remove(_ name: String) {
        try? Profiles.remove(name)
        reload()
    }

    func save(_ config: GraftConfig, as name: String) {
        try? Profiles.save(config, as: name)
        reload()
    }

    /// An Orchard provider for a profile, with the controller token resolved from the
    /// Keychain (mirrors the CLI's `Tree.provider`). Nil for non-Orchard profiles. Reading
    /// the token may prompt for Keychain access once if the CLI stored it.
    func orchardProvider(for name: String) -> OrchardProvider? {
        guard let cfg = config(name), var orchard = cfg.orchard else { return nil }
        if (orchard.token ?? "").isEmpty {
            orchard.token = KeychainSecretStore(scope: orchard.scope).orchardToken(account: orchard.serviceAccount)
        }
        return OrchardProvider(config: orchard)
    }

    /// True if the profile is configured for an Orchard fleet (vs local Tart).
    func isOrchard(_ name: String) -> Bool { config(name)?.orchard != nil }

    /// An Orchard service-account token plus the keychain it lives in.
    struct ScopedOrchardAccount: Identifiable, Equatable {
        let account: String
        let scope: KeychainScope
        var id: String { "\(account)|\(scope.rawValue)" }
    }

    /// Service accounts with a stored token across *both* keychains — offered in the profile
    /// editor so you can reuse one instead of re-pasting, each tagged with its scope. Prompt-free.
    func scopedOrchardAccounts() -> [ScopedOrchardAccount] {
        let login = ((try? KeychainSecretStore(scope: .login).storedOrchardAccounts()) ?? [])
            .map { ScopedOrchardAccount(account: $0, scope: .login) }
        let system = ((try? KeychainSecretStore(scope: .system).storedOrchardAccounts()) ?? [])
            .map { ScopedOrchardAccount(account: $0, scope: .system) }
        return (login + system).sorted { $0.account < $1.account }
    }

    /// Local Tart images you can clone a pool from — `tart list` minus digest-pinned
    /// duplicates and graft's own transient VMs (leaves / dev / build boxes). Mirrors the
    /// CLI's `ImagePicker`. Shelled by full path because a GUI app's PATH is minimal, and
    /// run off-main since `tart list` blocks. Empty if tart isn't found.
    func localImages() async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            guard let tart = Self.tartPath else { return [] }
            let out = Self.capture(tart, ["list", "--format", "json"])
            guard let data = out.data(using: .utf8),
                  let vms = try? JSONDecoder().decode([TartVM].self, from: data) else { return [] }
            let names = vms.map(\.name).filter {
                !$0.contains("@sha256:")
                    && !$0.hasPrefix("graft-")
                    && !$0.hasPrefix("orchard-graft-")
            }
            return Array(Set(names)).sorted()
        }.value
    }

    /// Tags available for a registry repository (e.g. `ghcr.io/cirruslabs/macos-tahoe-xcode`),
    /// over the anonymous pull-token flow. Powers the "Browse registry" picker. Returns the
    /// tag list and a nil error on success, or an empty list and a short message to show
    /// inline — never throws into the UI.
    func registryTags(for repository: String) async -> (tags: [String], error: String?) {
        do { return (try await RegistryClient().tags(forRepository: repository), nil) }
        catch { return ([], "\(error)") }
    }

    /// Saplings (golden + pulled base images) as full `TartVM` rows — same filter as
    /// `localImages()` but keeps `source`/`size` for provenance display in the list.
    func saplings() async -> [TartVM] {
        await Task.detached(priority: .userInitiated) { () -> [TartVM] in
            guard let tart = Self.tartPath else { return [] }
            let out = Self.capture(tart, ["list", "--format", "json"])
            guard let data = out.data(using: .utf8),
                  let vms = try? JSONDecoder().decode([TartVM].self, from: data) else { return [] }
            var seen = Set<String>()
            return vms
                .filter { !$0.name.contains("@sha256:") && !$0.name.hasPrefix("graft-") && !$0.name.hasPrefix("orchard-graft-") }
                .filter { seen.insert($0.name).inserted }
                .sorted { $0.name < $1.name }
        }.value
    }

    /// An App key plus the keychain it lives in — the GUI's per-secret unit, mirroring the
    /// CLI's "scope travels with the App" model.
    struct ScopedApp: Identifiable, Equatable {
        let app: KeychainSecretStore.StoredApp
        let scope: KeychainScope
        var id: String { "\(app.id)|\(scope.rawValue)" }
    }

    /// Apps with a stored key across *both* keychains (login + system), each tagged with
    /// where its key lives. Attribute-only reads, so no access prompt. Sorted by App ID.
    func scopedApps() -> [ScopedApp] {
        let login = ((try? KeychainSecretStore(scope: .login).storedApps()) ?? [])
            .map { ScopedApp(app: $0, scope: .login) }
        let system = ((try? KeychainSecretStore(scope: .system).storedApps()) ?? [])
            .map { ScopedApp(app: $0, scope: .system) }
        return (login + system).sorted { $0.app.id < $1.app.id }
    }

    /// Apps with a stored key, each with its display name if we've recorded one. Prompt-free.
    func storedApps() -> [KeychainSecretStore.StoredApp] { scopedApps().map(\.app) }

    /// Which keychain holds an App's key — scan login then system (prompt-free). Nil if
    /// neither has it. Used to read a key from the right place, and to record `github.scope`.
    func scope(forAppID id: Int) -> KeychainScope? {
        for scope in [KeychainScope.login, .system] {
            if ((try? KeychainSecretStore(scope: scope).storedAppIDs()) ?? []).contains(id) { return scope }
        }
        return nil
    }

    /// The recorded display name for an App ID, or nil. Prompt-free.
    func appName(_ id: Int) -> String? {
        scopedApps().first { $0.app.id == id }?.app.name
    }

    /// Backfill display names from GitHub for stored keys (`GET /app`). Reads each key, so
    /// the first run may prompt for Keychain access once per app; after that the name is
    /// cached in the item and reads are silent. Only records a name when GitHub confirms
    /// the key really belongs to that App ID — a mismatch means a wrong/duplicate import,
    /// which it reports (and clears any stale name for) instead of mislabeling.
    /// Returns the count resolved plus any warnings to surface.
    func fetchAppNames(force: Bool = false) async -> (resolved: Int, warnings: [String]) {
        var resolved = 0
        var warnings: [String] = []
        for scoped in scopedApps() where force || scoped.app.name == nil {
            let store = KeychainSecretStore(scope: scoped.scope)
            let client = GitHubAppClient(appID: scoped.app.id, secrets: store)
            guard let info = try? await client.appInfo() else { continue }
            if info.id == scoped.app.id {
                try? await store.setName(info.name, forAppID: scoped.app.id)
                resolved += 1
            } else {
                try? await store.setName(nil, forAppID: scoped.app.id)
                warnings.append("App \(scoped.app.id)'s key actually belongs to App \(info.id) (“\(info.name)”) — it's a wrong/duplicate import; remove it.")
            }
        }
        objectWillChange.send()
        return (resolved, warnings)
    }

    /// Targets (`org:…` / `repo:owner/name`) an App can reach, via the GitHub API. Returns
    /// nil if we couldn't reach GitHub (no key, offline, timeout) so the caller falls back
    /// to manual entry; an empty array means "reached GitHub, nothing accessible". Bounded
    /// by a timeout because it's network I/O behind a dropdown.
    func accessibleTargets(appID: Int, timeout: Double = 8) async -> [String]? {
        let client = GitHubAppClient(appID: appID, secrets: KeychainSecretStore(scope: scope(forAppID: appID) ?? .login))
        return await withTaskGroup(of: [String]?.self) { group in
            group.addTask { try? await client.accessibleTargets() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: Auth check (the GUI's `graft arborist check`)

    /// One step of the auth chain, with its outcome — rendered as a ✓/✗ row.
    struct CheckStep: Identifiable, Sendable {
        let id = UUID()
        let label: String
        let ok: Bool
        var detail: String?
    }

    /// The result of checking one App+target (or one bare key): a titled list of steps.
    struct CheckResult: Identifiable, Sendable {
        let id = UUID()
        let title: String
        var steps: [CheckStep]
        var passed: Bool { steps.allSatisfy(\.ok) }
    }

    /// Verify a profile's GitHub auth end-to-end — the same chain as `graft arborist check`:
    /// read key + sign App JWT → discover the installation → mint an installation token →
    /// (optionally) create and immediately delete a throwaway probe runner. One result per
    /// distinct App+target the profile registers against. Each App's key is read from its
    /// own recorded scope. Network + Keychain I/O, so call off the main interaction.
    func verifyProfile(_ name: String, probe: Bool = true) async -> [CheckResult] {
        guard let cfg = config(name) else {
            return [CheckResult(title: name, steps: [CheckStep(label: "load profile", ok: false, detail: "unreadable")])]
        }
        let targets = cfg.distinctGitHubConfigs()
        guard !targets.isEmpty else {
            return [CheckResult(title: name, steps: [CheckStep(label: "GitHub config", ok: false, detail: "no App/target set")])]
        }
        var results: [CheckResult] = []
        for gh in targets { results.append(await verifyAuth(github: gh, probe: probe)) }
        return results
    }

    /// Verify one GitHub App + target. Builds the client at the config's recorded scope.
    func verifyAuth(github gh: GitHubConfig, probe: Bool = true) async -> CheckResult {
        let client = GitHubAppClient(appID: gh.appId, secrets: KeychainSecretStore(scope: gh.scope))
        var steps: [CheckStep] = []
        let title = "App \(gh.appId) · \(gh.target)"

        let parsed: GitHubTarget
        do { parsed = try gh.parsedTarget() }
        catch { return CheckResult(title: title, steps: [CheckStep(label: "parse target", ok: false, detail: "\(error)")]) }

        do { _ = try await client.makeAppJWT()
            steps.append(CheckStep(label: "read key (\(gh.scope.rawValue) keychain) + sign App JWT", ok: true))
        } catch {
            steps.append(CheckStep(label: "sign App JWT", ok: false, detail: "\(error)")); return CheckResult(title: title, steps: steps)
        }

        do { let id = try await client.installationID(for: parsed)
            steps.append(CheckStep(label: "found App installation", ok: true, detail: "#\(id)"))
        } catch {
            steps.append(CheckStep(label: "discover installation", ok: false, detail: "\(error)")); return CheckResult(title: title, steps: steps)
        }

        do { _ = try await client.installationAccessToken(for: parsed)
            steps.append(CheckStep(label: "minted installation access token", ok: true))
        } catch {
            steps.append(CheckStep(label: "mint installation token", ok: false, detail: "\(error)")); return CheckResult(title: title, steps: steps)
        }

        if probe {
            let probeName = "graft-doctor-" + UUID().uuidString.prefix(8).lowercased()
            do {
                let runner = try await client.generateJITRunner(github: gh, labels: ["self-hosted"], runnerName: probeName)
                steps.append(CheckStep(label: "generated JIT config", ok: true, detail: "runner #\(runner.runnerID)"))
                do { try await client.deleteRunner(id: runner.runnerID, target: parsed)
                    steps.append(CheckStep(label: "deleted probe runner", ok: true, detail: "#\(runner.runnerID)"))
                } catch {
                    steps.append(CheckStep(label: "delete probe runner #\(runner.runnerID) — remove it in GitHub", ok: false, detail: "\(error)"))
                }
            } catch {
                steps.append(CheckStep(label: "generate JIT config", ok: false, detail: "\(error)"))
            }
        }
        return CheckResult(title: title, steps: steps)
    }

    /// Verify a bare App key (no profile/target): read key + sign App JWT, then list where
    /// the App is installed. Confirms the stored key works and the App is installed
    /// somewhere — the "check this secret" counterpart to the profile check.
    func verifyKey(appID: Int, scope: KeychainScope) async -> CheckResult {
        let client = GitHubAppClient(appID: appID, secrets: KeychainSecretStore(scope: scope))
        var steps: [CheckStep] = []
        let title = "App \(appID) · \(scope.rawValue) keychain"
        do { _ = try await client.makeAppJWT()
            steps.append(CheckStep(label: "read key + sign App JWT", ok: true))
        } catch {
            steps.append(CheckStep(label: "read key + sign App JWT", ok: false, detail: "\(error)")); return CheckResult(title: title, steps: steps)
        }
        do {
            let installs = try await client.installations()
            if installs.isEmpty {
                steps.append(CheckStep(label: "installed somewhere", ok: false, detail: "not installed on any org/repo yet"))
            } else {
                steps.append(CheckStep(label: "installed", ok: true, detail: installs.map(\.account.login).joined(separator: ", ")))
            }
        } catch {
            steps.append(CheckStep(label: "list installations", ok: false, detail: "\(error)"))
        }
        return CheckResult(title: title, steps: steps)
    }

    // MARK: Nests (dev boxes)

    /// Dev boxes — Tart VMs named `graft-dev-*`. Mirrors `graft nest ls`. Off-main (shells
    /// `tart list`). Each carries its name + state (running/stopped).
    func nests() async -> [TartVM] {
        await Task.detached(priority: .userInitiated) { () -> [TartVM] in
            guard let tart = Self.tartPath else { return [] }
            let out = Self.capture(tart, ["list", "--format", "json"])
            guard let data = out.data(using: .utf8),
                  let vms = try? JSONDecoder().decode([TartVM].self, from: data) else { return [] }
            return vms.filter { $0.name.hasPrefix("graft-dev-") }.sorted { $0.name < $1.name }
        }.value
    }

    /// Stop a running nest (best-effort).
    func stopNest(_ name: String) async {
        await Task.detached { if let tart = Self.tartPath { _ = Self.capture(tart, ["stop", name]) } }.value
    }

    /// Boot a stopped nest headless (`tart run --no-graphics`, detached) — bring it up
    /// without a window so you can VS Code / Shell into it. Use "Open window" for a screen.
    func startNest(name: String) { Self.launchDetached(Self.tartPath, ["run", name, "--no-graphics"]) }

    /// Remove a nest — stop then delete (mirrors `graft nest rm`), and drop its status file.
    func removeNest(_ name: String) async {
        await Task.detached {
            guard let tart = Self.tartPath else { return }
            _ = Self.capture(tart, ["stop", name])
            _ = Self.capture(tart, ["delete", name])
            NestStatusStore.clear(name)
        }.value
    }

    /// Provisioning status for a nest (creating → booting → cloning → ready), written by
    /// `graft nest`. Nil for boxes made before status tracking, or once cleared.
    func nestStatus(_ name: String) -> NestStatus? { NestStatusStore.read(name) }

    /// Open the VM's graphical screen in a Tart window: `tart run <name>` (with graphics).
    /// Only valid from a stopped box — Tart is one-process-per-VM, so you can't attach a
    /// window to one already running headless under graft.
    func openNestWindow(name: String) { Self.launchDetached(Self.tartPath, ["run", name]) }

    /// Open an interactive shell into a nest in a new terminal window (`graft nest <short>`).
    /// Needs a real TTY, so it runs in Terminal (or iTerm, if installed) rather than a
    /// detached background process. No-op if the graft CLI isn't found.
    func openNestInTerminal(short: String) {
        guard let graft = Self.graftPath else { return }
        // `exec $SHELL` after graft keeps the window alive whether the box shell held or
        // graft exited early — so nothing vanishes and you always land in a usable shell.
        runInTerminal("\(graft) nest \(short); exec $SHELL -il")
    }

    /// Run a command in a real terminal window so the user can watch long / interactive /
    /// output-heavy flows (nest shell, sapling builds, pulls). Writes a temp executable
    /// `.command` script and `open`s it — Terminal runs `.command` files directly. This is
    /// far more reliable than osascript `do script` / iTerm `command` (which mangle a
    /// compound `cmd; exec $SHELL` string and need Automation permission).
    private func runInTerminal(_ command: String) {
        let script = "#!/bin/bash\n\(command)\n"
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("graft-\(UUID().uuidString).command")
        guard (try? script.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: tmp)
        Self.launchDetached("/usr/bin/open", [tmp])
    }

    // MARK: Saplings (images)

    /// Remove a local image/sapling (`tart delete`).
    func removeSapling(_ name: String) async {
        await Task.detached { if let tart = Self.tartPath { _ = Self.capture(tart, ["delete", name]) } }.value
    }

    /// Grow a sapling from a `.graft` seed — `graft sapling grow -f <seed>` in a terminal
    /// (the build streams a lot of output and takes a while).
    /// `network` (host-specific, e.g. "bridged:en0") maps to `--network` — empty = NAT default.
    func growSapling(seedPath: String, network: String = "") {
        guard let graft = Self.graftPath else { return }
        let net = network.trimmingCharacters(in: .whitespaces)
        let netFlag = net.isEmpty ? "" : " --network '\(net)'"
        runInTerminal("\(graft) sapling grow --seed '\(seedPath)'\(netFlag); exec $SHELL -il")
    }

    // MARK: Seed library (~/.graft/seeds)

    /// All seeds in the local library (file stems), sorted.
    func seedNames() -> [String] { Seeds.names() }

    /// Parsed recipe for a seed (for the list summary), or nil if it won't parse.
    func seedRecipe(_ name: String) -> ImageRecipe? { Seeds.recipe(name) }

    /// The raw `.graft` text of a seed (empty if missing).
    func readSeed(_ name: String) -> String { (try? Seeds.read(name)) ?? "" }

    func seedExists(_ name: String) -> Bool { Seeds.exists(name) }
    func seedPath(_ name: String) -> String { Seeds.path(for: name) }

    /// Write a seed, optionally removing a prior file when the name changed (a rename).
    @discardableResult
    func saveSeed(_ body: String, as name: String, renamingFrom old: String? = nil) -> Bool {
        do {
            try Seeds.write(body, as: name)
            if let old, old != name, Seeds.exists(old) { try? Seeds.remove(old) }
            objectWillChange.send()
            return true
        } catch { return false }
    }

    func removeSeed(_ name: String) { try? Seeds.remove(name); objectWillChange.send() }

    /// Duplicate a seed: copy its text under a fresh `<name>-copy` and rewrite the recipe's
    /// `name` to match (identity stays = recipe name). Returns the new name.
    @discardableResult
    func duplicateSeed(_ name: String) -> String? {
        guard let body = try? Seeds.read(name) else { return nil }
        let newName = Seeds.uniqueName(basedOn: name)
        let out: String
        if var r = try? ImageRecipe.parse(body) { r.name = newName; out = (try? r.yamlString()) ?? body }
        else { out = body }   // unparseable: copy verbatim
        return saveSeed(out, as: newName) ? newName : nil
    }

    /// Import an external `.graft` into the library, keyed by its recipe name (or file stem),
    /// disambiguated if that name is taken. Returns the name it landed under.
    @discardableResult
    func importSeed(from url: URL) -> String? {
        guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parsed = try? ImageRecipe.parse(body)
        let preferred = parsed.map { $0.name.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        let name = Seeds.exists(preferred) ? Seeds.uniqueName(basedOn: preferred) : preferred
        let out: String
        if name != preferred, var r = parsed { r.name = name; out = (try? r.yamlString()) ?? body }
        else { out = body }
        return saveSeed(out, as: name) ? name : nil
    }

    /// Grow a sapling from a library seed (terminal stream). `network` → `--network` (host-specific).
    func growSeed(_ name: String, network: String = "") { growSapling(seedPath: Seeds.path(for: name), network: network) }

    // MARK: Seeds (.graft recipes)

    /// A starter `.graft` recipe (`graft sapling template`). Empty if graft isn't found.
    func seedTemplate() async -> String {
        await Task.detached { () -> String in
            guard let graft = Self.graftPath else { return "" }
            return Self.capture(graft, ["sapling", "template"])
        }.value
    }

    /// The provisioning script a seed compiles to (`graft sapling render --seed <path>`),
    /// or the error output if it doesn't parse — handy as a live preview while editing.
    func renderSeed(path: String) async -> String {
        await Task.detached { () -> String in
            guard let graft = Self.graftPath else { return "graft CLI not found" }
            return Self.capture(graft, ["sapling", "render", "--seed", path], mergeStderr: true)
        }.value
    }

    /// Pull an image from a registry — `graft sapling pull <ref>` in a terminal (long download).
    func pullSapling(ref: String) {
        guard let graft = Self.graftPath else { return }
        runInTerminal("\(graft) sapling pull \(ref); exec $SHELL -il")
    }

    /// Boot an image and report what's installed (`graft sapling inspect`). Slow (~1 min —
    /// it boots a throwaway clone), so call it off-main and show a spinner. Returns the
    /// report text (progress + tool versions), or an error string.
    func inspectImage(_ name: String) async -> String {
        await Task.detached { () -> String in
            guard let graft = Self.graftPath else { return "graft CLI not found." }
            let out = Self.capture(graft, ["sapling", "inspect", name], mergeStderr: true)
            return out.isEmpty ? "No output — the image may have failed to boot." : out
        }.value
    }

    /// Whether the `graft` CLI is available — needed to open/create nests (it owns the
    /// boot + Remote-SSH dance). List/stop/remove work without it (pure `tart`).
    var graftAvailable: Bool { Self.graftPath != nil }

    /// Open a nest in VS Code over Remote-SSH: `graft nest <short> --code`. Detached — graft
    /// boots the box if needed, waits for the guest, then launches VS Code.
    func openNestInCode(short: String) {
        Self.launchGraft(["nest", short, "--code"])
    }

    /// Create a new nest from a repo/URL (clone) and open VS Code. An explicit image keeps it
    /// non-interactive (no image picker prompt in a detached run).
    func newNest(target: String, image: String?) {
        var args = ["nest", target]
        if let image, !image.isEmpty { args += ["--image", image] }
        args.append("--code")
        Self.launchGraft(args)
    }

    nonisolated private static let graftPath: String? =
        ["/opt/homebrew/bin/graft", "/usr/local/bin/graft"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Fire-and-forget a `graft` subcommand (detached; we don't wait). Used for the
    /// long-running, self-contained nest open/create flows.
    nonisolated private static func launchGraft(_ args: [String]) { launchDetached(graftPath, args) }

    /// Launch a binary detached (no wait, output discarded) with a sane PATH.
    nonisolated private static func launchDetached(_ path: String?, _ args: [String]) {
        guard let path else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        // Include VS Code's bundled `code` so `graft nest --code` works even if the user
        // never ran "Install 'code' command in PATH".
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Visual Studio Code.app/Contents/Resources/app/bin"
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    nonisolated private static let tartPath: String? =
        ["/opt/homebrew/bin/tart", "/usr/local/bin/tart"].first { FileManager.default.isExecutableFile(atPath: $0) }

    nonisolated private static func capture(_ launchPath: String, _ args: [String], mergeStderr: Bool = false) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = mergeStderr ? pipe : Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
