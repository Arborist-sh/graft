import SwiftUI
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
}
