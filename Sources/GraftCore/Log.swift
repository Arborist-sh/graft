import Foundation

/// Minimal timestamped logging. `info` → stdout, `warn` → stderr. launchd captures
/// both into the configured log file for the daemon; in manual mode they go to the
/// terminal.
///
/// When `sink` is set (by the live dashboard in an interactive `graft run`), lines
/// route there instead so the dashboard can print them *above* its live spinner
/// region. nil (default, and always in daemon/non-TTY mode) writes straight out.
public enum Log {
    nonisolated(unsafe) public static var sink: (@Sendable (_ line: String, _ isWarn: Bool) -> Void)?

    public static func info(_ message: String) { emit(message, isWarn: false) }
    public static func warn(_ message: String) { emit("⚠ " + message, isWarn: true) }

    /// Passthrough without a graft timestamp — for echoing a subprocess's own output
    /// (e.g. runner logs) that already carries its own formatting. Still routes via
    /// `sink` so it lands above the live dashboard instead of corrupting it.
    public static func raw(_ line: String) {
        if let sink { sink(line, false) }
        else { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
    }

    private static func emit(_ message: String, isWarn: Bool) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)"
        if let sink {
            sink(line, isWarn)
        } else {
            (isWarn ? FileHandle.standardError : FileHandle.standardOutput).write(Data((line + "\n").utf8))
        }
    }
}
