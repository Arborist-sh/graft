import Foundation

/// A host directory shared into a guest VM via Tart's `--dir`. On macOS guests the
/// share appears at `/Volumes/My Shared Files/<name>`. Read-write by default; mark
/// `readOnly` for shared caches that must not be mutated by concurrent runners.
public struct Mount: Codable, Sendable, Equatable {
    /// Mount tag — the folder name under `/Volumes/My Shared Files/` in the guest.
    public let name: String
    /// Host path (may be relative or use `~`; resolved to absolute for the arg).
    public let source: String
    public let readOnly: Bool

    public init(name: String, source: String, readOnly: Bool = false) {
        self.name = name
        self.source = source
        self.readOnly = readOnly
    }

    enum CodingKeys: String, CodingKey { case name, source, readOnly }

    /// `readOnly` is optional in recipes — omit it for the read-write default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        source = try c.decode(String.self, forKey: .source)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }

    /// Where this mount lands inside a macOS guest.
    public var guestPath: String { "/Volumes/My Shared Files/\(name)" }

    /// The value for `tart run --dir=…` → `name:<abs-host-path>[:ro]`. The path is
    /// `~`-expanded and made absolute (relative paths resolve against the cwd).
    public var tartDirArg: String {
        let expanded = (source as NSString).expandingTildeInPath
        let absolute = URL(fileURLWithPath: expanded).path
        return readOnly ? "\(name):\(absolute):ro" : "\(name):\(absolute)"
    }

    /// Parse a CLI `--mount` spec: `path`, `name:path`, `path:ro`, or `name:path:ro`.
    /// A bare path derives the name from the last path component.
    public init(spec: String) throws {
        var parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var ro = false
        if parts.count > 1, parts.last == "ro" {
            ro = true
            parts.removeLast()
        }
        switch parts.count {
        case 1:
            let path = parts[0]
            guard !path.isEmpty else { throw GraftError("invalid --mount '\(spec)' — empty path") }
            let derived = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .lastPathComponent
            self.init(name: derived.isEmpty ? "mount" : derived, source: path, readOnly: ro)
        case 2:
            guard !parts[0].isEmpty, !parts[1].isEmpty else {
                throw GraftError("invalid --mount '\(spec)' — expected name:path[:ro]")
            }
            self.init(name: parts[0], source: parts[1], readOnly: ro)
        default:
            throw GraftError("invalid --mount '\(spec)' — expected path, name:path, or name:path:ro")
        }
    }
}
