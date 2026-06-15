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

    /// Backfill display names from GitHub for any stored key that lacks one (`GET /app`).
    /// Reads each key, so the first run may prompt for Keychain access once per app; after
    /// that the name is cached in the item and reads are silent. Returns how many resolved.
    @discardableResult
    func fetchAppNames() async -> Int {
        let store = KeychainSecretStore(scope: .login)
        var resolved = 0
        for app in storedApps() where app.name == nil {
            let client = GitHubAppClient(appID: app.id, secrets: store)
            if let info = try? await client.appInfo() {
                try? await store.setName(info.name, forAppID: app.id)
                resolved += 1
            }
        }
        if resolved > 0 { objectWillChange.send() }
        return resolved
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

    nonisolated private static let tartPath: String? =
        ["/opt/homebrew/bin/tart", "/usr/local/bin/tart"].first { FileManager.default.isExecutableFile(atPath: $0) }

    nonisolated private static func capture(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
