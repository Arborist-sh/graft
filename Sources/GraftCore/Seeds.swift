import Foundation

/// The local seed library — `.graft` image recipes under `~/.graft/seeds/<name>.graft`.
/// A seed is the declarative recipe (YAML) that `graft sapling grow` compiles into a
/// sapling; analogy is exact — seed : sapling :: Dockerfile : image. Identity is the
/// recipe's `name` (the file is `<name>.graft`). This is the local cache a future
/// registry (`graft seed pull <ref>`) would populate; a ref resolves down to a name here.
public enum Seeds {
    public static let fileExtension = "graft"

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".graft/seeds")
    }

    public static func path(for name: String) -> String {
        directory.appendingPathComponent("\(name).\(fileExtension)").path
    }

    /// All seed names (file stems), sorted.
    public static func names() -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return items
            .filter { $0.pathExtension == fileExtension }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: path(for: name))
    }

    /// The raw `.graft` text of a seed.
    public static func read(_ name: String) throws -> String {
        guard exists(name) else { throw GraftError("no seed named '\(name)'") }
        return try String(contentsOf: URL(fileURLWithPath: path(for: name)), encoding: .utf8)
    }

    /// The parsed recipe, or nil if the seed doesn't parse (e.g. hand-edited YAML).
    public static func recipe(_ name: String) -> ImageRecipe? {
        (try? read(name)).flatMap { try? ImageRecipe.parse($0) }
    }

    public static func write(_ body: String, as name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try body.write(toFile: path(for: name), atomically: true, encoding: .utf8)
    }

    public static func remove(_ name: String) throws {
        guard exists(name) else { throw GraftError("no seed named '\(name)'") }
        try FileManager.default.removeItem(at: URL(fileURLWithPath: path(for: name)))
    }

    /// A free `<base>-copy` / `<base>-copy-2` / … name that isn't taken yet.
    public static func uniqueName(basedOn base: String) -> String {
        let root = base.isEmpty ? "untitled" : base
        var candidate = "\(root)-copy"
        var n = 2
        while exists(candidate) { candidate = "\(root)-copy-\(n)"; n += 1 }
        return candidate
    }
}
