import Foundation

/// Minimal timestamped logging. `info` → stdout, `warn` → stderr. launchd captures
/// both into the configured log file for the daemon; in manual mode they go to the
/// terminal.
public enum Log {
    public static func info(_ message: String) { write(message, to: FileHandle.standardOutput) }
    public static func warn(_ message: String) { write("⚠ " + message, to: FileHandle.standardError) }

    private static func write(_ message: String, to handle: FileHandle) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        handle.write(Data("[\(timestamp)] \(message)\n".utf8))
    }
}
