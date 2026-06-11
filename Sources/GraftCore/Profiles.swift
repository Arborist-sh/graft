import Foundation

/// Named config profiles under `~/.graft/profiles/<name>.json`, with an active
/// pointer (`~/.graft/profiles/.active`). Each profile is a full `GraftConfig`, so
/// switching profiles swaps the entire setup (e.g. personal vs. work).
public enum Profiles {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".graft/profiles")
    }

    private static var activePointer: URL {
        directory.appendingPathComponent(".active")
    }

    public static func path(for name: String) -> String {
        directory.appendingPathComponent("\(name).json").path
    }

    /// All profile names, sorted.
    public static func names() -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: path(for: name))
    }

    public static func activeName() -> String? {
        guard let contents = try? String(contentsOf: activePointer, encoding: .utf8) else { return nil }
        let name = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public static func setActive(_ name: String) throws {
        guard exists(name) else { throw GraftError("no profile named '\(name)'") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try name.write(to: activePointer, atomically: true, encoding: .utf8)
    }

    public static func clearActive() {
        try? FileManager.default.removeItem(at: activePointer)
    }

    public static func load(_ name: String) throws -> GraftConfig {
        guard exists(name) else { throw GraftError("no profile named '\(name)'") }
        return try GraftConfig.load(from: path(for: name))
    }

    public static func save(_ config: GraftConfig, as name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try GraftConfig.encoder.encode(config)
        try data.write(to: URL(fileURLWithPath: path(for: name)), options: .atomic)
    }

    public static func remove(_ name: String) throws {
        guard exists(name) else { throw GraftError("no profile named '\(name)'") }
        try FileManager.default.removeItem(at: URL(fileURLWithPath: path(for: name)))
        if activeName() == name { clearActive() }
    }
}
