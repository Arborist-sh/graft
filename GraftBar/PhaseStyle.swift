import SwiftUI

/// Shared mapping from a slot's `phaseKind` (the stable key the supervisor persists) to a
/// colour, so the menu-bar dropdown and the dashboard window stay in visual sync. Mirrors
/// the CLI live dashboard's glyph colours: green = ready/up, blue = running a job, orange =
/// coming up, grey = parked or tearing down.
enum PhaseStyle {
    static func color(_ kind: String) -> Color {
        switch kind {
        case "ready":                                                              return .green
        case "busy":                                                               return .blue
        case "acquiring", "scheduling", "booting", "provisioning",
             "starting", "connected":                                              return .orange
        case "waiting", "stopping", "deregistering", "retrying":                   return .secondary
        default:                                                                   return .secondary
        }
    }

    /// `graft-d62da19a-…` → `d62da19a` — the bit that distinguishes leaves at a glance.
    static func shortLeaf(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "—" }
        let stripped = name.hasPrefix("graft-") ? String(name.dropFirst("graft-".count)) : name
        return String(stripped.prefix(8))
    }

    /// Compact "time in this phase": `5s` / `3m` / `1h02m`.
    static func age(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h\(String(format: "%02d", (seconds % 3600) / 60))m"
    }
}
