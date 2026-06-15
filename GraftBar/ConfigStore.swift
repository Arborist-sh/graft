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

    /// Create a fresh profile from a defaulted (local Tart, no pools) config. Returns false
    /// if the name is empty or already taken.
    @discardableResult
    func create(_ name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !Profiles.exists(clean) else { return false }
        do { try Profiles.save(GraftConfig(), as: clean); reload(); return true }
        catch { return false }
    }

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
            let scope = KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login
            orchard.token = KeychainSecretStore(scope: scope).orchardToken(account: orchard.serviceAccount)
        }
        return OrchardProvider(config: orchard)
    }

    /// True if the profile is configured for an Orchard fleet (vs local Tart).
    func isOrchard(_ name: String) -> Bool { config(name)?.orchard != nil }

    /// Service-account names that already have an Orchard token in the Keychain — offered
    /// in the profile editor so you can reuse one instead of re-pasting. Prompt-free.
    func storedOrchardAccounts() -> [String] {
        (try? KeychainSecretStore(scope: .login).storedOrchardAccounts()) ?? []
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

    /// GitHub App IDs we hold a private key for, in the login Keychain — the natural set
    /// of App IDs to offer in the profile editor. Attribute-only read, so no access prompt.
    func storedAppIDs() -> [Int] {
        ((try? KeychainSecretStore(scope: .login).storedAppIDs()) ?? []).sorted()
    }

    /// Apps with a stored key, each with its display name if we've recorded one. Prompt-free.
    func storedApps() -> [KeychainSecretStore.StoredApp] {
        (try? KeychainSecretStore(scope: .login).storedApps()) ?? []
    }

    /// The recorded display name for an App ID, or nil. Prompt-free.
    func appName(_ id: Int) -> String? {
        storedApps().first { $0.id == id }?.name
    }

    /// Backfill display names from GitHub for stored keys (`GET /app`). Reads each key, so
    /// the first run may prompt for Keychain access once per app; after that the name is
    /// cached in the item and reads are silent. Only records a name when GitHub confirms
    /// the key really belongs to that App ID — a mismatch means a wrong/duplicate import,
    /// which it reports (and clears any stale name for) instead of mislabeling.
    /// Returns the count resolved plus any warnings to surface.
    func fetchAppNames(force: Bool = false) async -> (resolved: Int, warnings: [String]) {
        let store = KeychainSecretStore(scope: .login)
        var resolved = 0
        var warnings: [String] = []
        for app in storedApps() where force || app.name == nil {
            let client = GitHubAppClient(appID: app.id, secrets: store)
            guard let info = try? await client.appInfo() else { continue }
            if info.id == app.id {
                try? await store.setName(info.name, forAppID: app.id)
                resolved += 1
            } else {
                try? await store.setName(nil, forAppID: app.id)
                warnings.append("App \(app.id)'s key actually belongs to App \(info.id) (“\(info.name)”) — it's a wrong/duplicate import; remove it.")
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
        let client = GitHubAppClient(appID: appID, secrets: KeychainSecretStore(scope: .login))
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

    /// Run a command in a new Terminal (or iTerm) window. For long, output-heavy, or
    /// interactive flows (nest shell, sapling builds, pulls) the user needs to watch live.
    private func runInTerminal(_ command: String) {
        let iterm = FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
        let app = iterm ? "iTerm" : "Terminal"
        let open = iterm
            ? "tell application \"iTerm\" to create window with default profile command \"\(command)\""
            : "tell application \"Terminal\" to do script \"\(command)\""
        Self.launchDetached("/usr/bin/osascript", ["-e", open, "-e", "tell application \"\(app)\" to activate"])
    }

    // MARK: Saplings (images)

    /// Remove a local image/sapling (`tart delete`).
    func removeSapling(_ name: String) async {
        await Task.detached { if let tart = Self.tartPath { _ = Self.capture(tart, ["delete", name]) } }.value
    }

    /// Grow a sapling from a `.graft` seed — `graft sapling grow -f <seed>` in a terminal
    /// (the build streams a lot of output and takes a while).
    func growSapling(seedPath: String) {
        guard let graft = Self.graftPath else { return }
        runInTerminal("\(graft) sapling grow --seed '\(seedPath)'; exec $SHELL -il")
    }

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
