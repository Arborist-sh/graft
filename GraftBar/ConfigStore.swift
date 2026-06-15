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
