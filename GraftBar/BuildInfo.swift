import Foundation

/// App version + build metadata read from the bundle Info.plist. `CFBundleShortVersionString`
/// comes from `MARKETING_VERSION`; `GitCommit` is stamped in by a build phase (empty in
/// builds made outside a git checkout).
enum BuildInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var commit: String {
        (Bundle.main.infoDictionary?["GitCommit"] as? String) ?? ""
    }

    /// "v0.1.6 · a1b2c3d" — drops the commit if it wasn't stamped.
    static var footer: String {
        let suffix = commit.isEmpty ? "" : " · \(commit)"
        return "v\(version)\(suffix)"
    }
}
