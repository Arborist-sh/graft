import Foundation

/// Daemon liveness via the pidfile at `~/.graft/state/graft.pid`. Shared by the
/// CLI (`graft run`/`status`/`stop`) and the menu-bar app so both agree on whether
/// a supervisor is running.
public enum Daemon {
    public static var pidfileURL: URL {
        StateManager.defaultDirectory.appendingPathComponent("graft.pid")
    }

    public static func writePidfile() throws {
        try FileManager.default.createDirectory(
            at: StateManager.defaultDirectory,
            withIntermediateDirectories: true
        )
        try String(getpid()).write(to: pidfileURL, atomically: true, encoding: .utf8)
    }

    public static func removePidfile() {
        try? FileManager.default.removeItem(at: pidfileURL)
    }

    /// PID of the running supervisor, or nil if the pidfile is absent/stale.
    public static func runningPID() -> Int32? {
        guard
            let contents = try? String(contentsOf: pidfileURL, encoding: .utf8),
            let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return kill(pid, 0) == 0 ? pid : nil
    }

    public static var isRunning: Bool { runningPID() != nil }
}
