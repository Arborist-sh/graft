import Foundation

/// Per-VM boot logs for detached `tart run` processes.
///
/// A detached boot can't report failure through a return value — the process is meant to
/// outlive us — so its stdout/stderr is captured to `~/.graft/logs/<vm>.log` rather than
/// thrown away to `/dev/null`. When a leaf fails to come up, the acquire path reads the
/// tail back so the real `tart` error reaches the operator instead of a bare IP timeout.
public enum BootLog {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".graft/logs")
    }

    /// Log file URL for a VM's detached boot, ensuring the logs directory exists.
    public static func url(for vm: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(vm).log")
    }

    /// Last `lines` lines of a VM's boot log, trimmed — for surfacing a failed boot's cause.
    /// Empty when the log is missing or unreadable.
    public static func tail(for vm: String, lines: Int = 20) -> String {
        let file = directory.appendingPathComponent("\(vm).log")
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        return contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove a VM's boot log once the leaf is torn down, so logs don't accumulate one
    /// file per ephemeral runner over a long-running supervisor's life.
    public static func remove(for vm: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(vm).log"))
    }
}
