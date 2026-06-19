import Foundation

/// A registry image you can browse and pull — one entry in the catalog. The catalog is
/// persisted at `~/.graft/registries.json` (see `RegistryCatalog`), so the set is fully
/// yours: the cirruslabs bases are just the seeded defaults, not a hard dependency. And
/// `RegistryClient.tags(forRepository:)` works for *any* repo ref, so a typed-in repository
/// is a first-class citizen too.
public struct RegistryImage: Sendable, Hashable, Codable, Identifiable {
    /// Host + path, no tag — e.g. `ghcr.io/cirruslabs/macos-tahoe-xcode`.
    public var repository: String
    /// Human label for the picker, e.g. "macOS Tahoe · Xcode".
    public var title: String
    /// One-liner shown under the title (blank for user-added repos).
    public var blurb: String
    /// The guest OS this image targets, or nil to offer it for any pool.
    public var os: GuestOS?

    public var id: String { repository }

    /// Registry host — everything before the first "/", e.g. `ghcr.io`.
    public var host: String {
        repository.split(separator: "/").first.map(String.init) ?? repository
    }

    /// The namespace/owner — the path between the host and the image name.
    /// `ghcr.io/cirruslabs/macos-tahoe-xcode` → `cirruslabs`; `ghcr.io/a/b/img` → `a/b`;
    /// a bare `host/name` → "".
    public var owner: String {
        let parts = repository.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return "" }
        return parts[1..<(parts.count - 1)].joined(separator: "/")
    }

    /// The image name — the last path segment, minus any `:tag`.
    public var imageName: String { RegistryImage.derivedTitle(repository) }

    /// Stable key for grouping the catalog by source (host + owner), e.g. `ghcr.io/cirruslabs`.
    /// The browser's leftmost column is one row per `ownerKey`.
    public var ownerKey: String { owner.isEmpty ? host : "\(host)/\(owner)" }

    public init(repository: String, title: String, blurb: String = "", os: GuestOS? = nil) {
        self.repository = repository
        self.title = title
        self.blurb = blurb
        self.os = os
    }

    /// A user-added entry from a typed repository ref: title derived from the last path
    /// segment, no blurb, unknown OS (so it shows for any pool).
    public static func userAdded(_ repository: String) -> RegistryImage {
        RegistryImage(repository: repository, title: derivedTitle(repository))
    }

    /// The last path segment, minus any `:tag` — a sensible label for a bare repo ref.
    static func derivedTitle(_ repository: String) -> String {
        let last = repository.split(separator: "/").last.map(String.init) ?? repository
        return last.split(separator: ":").first.map(String.init) ?? last
    }

    enum CodingKeys: String, CodingKey { case repository, title, blurb, os }

    // Tolerant decode so a hand-edited file with only `repository` still loads — the rest
    // is derived/defaulted. Encoding is synthesized (and omits a nil `os`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let repo = try c.decode(String.self, forKey: .repository)
        repository = repo
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? RegistryImage.derivedTitle(repo)
        blurb = try c.decodeIfPresent(String.self, forKey: .blurb) ?? ""
        os = try c.decodeIfPresent(GuestOS.self, forKey: .os)
    }
}

/// The catalog of registry images offered in the picker, persisted at
/// `~/.graft/registries.json` alongside profiles and seeds. Seeded once from `defaults`,
/// then fully user-owned — add or remove anything, so the app isn't bound to cirruslabs'
/// naming if it changes. Shared by the GUI browser and the CLI image picker.
public enum RegistryCatalog {
    /// Built-in defaults, written to the file on first run (cirruslabs' Tart bases).
    public static let defaults: [RegistryImage] = [
        // macOS — current Tart bases. `-base` is a clean OS; `-xcode` adds the Xcode toolchain.
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-tahoe-base",
                      title: "macOS Tahoe · base",
                      blurb: "macOS 26 Tahoe, clean — bring your own toolchain", os: .macOS),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-tahoe-xcode",
                      title: "macOS Tahoe · Xcode",
                      blurb: "macOS 26 Tahoe with Xcode + the iOS toolchain baked in", os: .macOS),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-sequoia-base",
                      title: "macOS Sequoia · base",
                      blurb: "macOS 15 Sequoia, clean — bring your own toolchain", os: .macOS),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-sequoia-xcode",
                      title: "macOS Sequoia · Xcode",
                      blurb: "macOS 15 Sequoia with Xcode + the iOS toolchain baked in", os: .macOS),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-sonoma-base",
                      title: "macOS Sonoma · base",
                      blurb: "macOS 14 Sonoma, clean — bring your own toolchain", os: .macOS),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-sonoma-xcode",
                      title: "macOS Sonoma · Xcode",
                      blurb: "macOS 14 Sonoma with Xcode + the iOS toolchain baked in", os: .macOS),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-ventura-base",
                      title: "macOS Ventura · base",
                      blurb: "macOS 13 Ventura, clean — bring your own toolchain", os: .macOS),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-ventura-xcode",
                      title: "macOS Ventura · Xcode",
                      blurb: "macOS 13 Ventura with Xcode + the iOS toolchain baked in", os: .macOS),
        // Linux — planned future epic, but the picker shouldn't hide the bases that exist.
        RegistryImage(repository: "ghcr.io/cirruslabs/ubuntu",
                      title: "Ubuntu", blurb: "Cirrus Labs' Ubuntu Tart base", os: .linux),
        RegistryImage(repository: "ghcr.io/cirruslabs/debian",
                      title: "Debian", blurb: "Cirrus Labs' Debian Tart base", os: .linux),
    ]

    /// `~/.graft/registries.json` — sits next to `~/.graft/profiles` and `~/.graft/seeds`.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".graft/registries.json")
    }

    /// The saved catalog. First run (no file) seeds it with `defaults`; a corrupt or
    /// unreadable file falls back to `defaults` *without* overwriting, so a hand-edit typo
    /// is recoverable rather than silently clobbered.
    public static func load() -> [RegistryImage] {
        guard let data = try? Data(contentsOf: fileURL) else {
            try? save(defaults)
            return defaults
        }
        return (try? JSONDecoder().decode([RegistryImage].self, from: data)) ?? defaults
    }

    /// Persist the catalog (after an add/remove). Pretty-printed + key-sorted so the file
    /// stays diffable and hand-editable.
    public static func save(_ images: [RegistryImage]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(images).write(to: fileURL, options: .atomic)
    }

    /// Catalog entries to offer for a pool's guest OS — an entry with no OS shows for any pool.
    public static func images(for os: GuestOS) -> [RegistryImage] {
        load().filter { $0.os == nil || $0.os == os }
    }
}

/// Lists the tags of an OCI repository over the registry's anonymous pull-token flow —
/// enough to power "search a registry, then pull" without shelling out to `tart` or `oras`.
/// Stateless and `Sendable`; one instance is reusable.
///
/// The flow is the standard OCI distribution dance: hit `/v2/<name>/tags/list`; if the
/// registry answers `401` with a `Www-Authenticate: Bearer …` challenge, fetch an
/// anonymous token from the named realm and retry. Works against ghcr.io (where the
/// cirruslabs bases live), Docker Hub, and any spec-compliant registry.
public struct RegistryClient: Sendable {
    private let timeout: Double

    public init(timeout: Double = 12) {
        self.timeout = timeout
    }

    /// Tags for `repoRef` (a `host/path` repository, with or without a trailing `:tag`),
    /// ordered for a picker: `latest` first, then newest-looking tags first. Throws a
    /// `GraftError` if the ref isn't a registry repository or the registry can't be reached.
    public func tags(forRepository repoRef: String) async throws -> [String] {
        let (host, name) = try Self.split(repoRef)
        guard let listURL = URL(string: "https://\(host)/v2/\(name)/tags/list?n=200") else {
            throw GraftError("not a valid registry repository: \(repoRef)")
        }

        // Try unauthenticated first; public registries answer with a token challenge.
        var (data, http) = try await get(listURL, bearer: nil)
        if http.statusCode == 401 {
            let token = try await fetchToken(
                challenge: http.value(forHTTPHeaderField: "Www-Authenticate"),
                host: host, name: name
            )
            (data, http) = try await get(listURL, bearer: token)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw GraftError("registry returned HTTP \(http.statusCode) for \(name)")
        }
        struct TagList: Decodable { let tags: [String]? }
        let tags = (try? JSONDecoder().decode(TagList.self, from: data))?.tags ?? []
        return Self.order(tags)
    }

    // MARK: - HTTP

    private func get(_ url: URL, bearer: String?) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("graft", forHTTPHeaderField: "User-Agent")
        // Accept both the OCI and Docker tag-list media types; tags/list is JSON regardless.
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GraftError("no HTTP response from \(url.host ?? "registry")")
        }
        return (data, http)
    }

    /// Resolve an anonymous pull token from a `Www-Authenticate: Bearer …` challenge.
    /// Falls back to a `repository:<name>:pull` scope when the challenge omits one.
    private func fetchToken(challenge: String?, host: String, name: String) async throws -> String {
        let params = Self.parseBearerChallenge(challenge ?? "")
        let realm = params["realm"] ?? "https://\(host)/token"
        let service = params["service"] ?? host
        let scope = params["scope"] ?? "repository:\(name):pull"

        var comps = URLComponents(string: realm)
        comps?.queryItems = [
            URLQueryItem(name: "service", value: service),
            URLQueryItem(name: "scope", value: scope),
        ]
        guard let tokenURL = comps?.url else {
            throw GraftError("bad token realm from \(host): \(realm)")
        }
        let (data, http) = try await get(tokenURL, bearer: nil)
        guard (200..<300).contains(http.statusCode) else {
            throw GraftError("couldn't get a pull token from \(host) (HTTP \(http.statusCode))")
        }
        // Registries return the token under "token" (OCI) or "access_token" (Docker).
        struct Token: Decodable { let token: String?; let accessToken: String? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(Token.self, from: data)
        guard let token = decoded.token ?? decoded.accessToken, !token.isEmpty else {
            throw GraftError("registry \(host) returned no pull token")
        }
        return token
    }

    // MARK: - Parsing (pure, unit-tested)

    /// Split a `host/path[:tag]` repository ref into `(host, path)`. The host must look like
    /// a registry hostname (contain a `.` or `:`), so a bare local name like `my-image`
    /// is rejected — it has no registry to query. Public so the GUI can validate/normalize a
    /// typed repository before adding it to the catalog.
    public static func split(_ repoRef: String) throws -> (host: String, name: String) {
        let trimmed = repoRef.trimmingCharacters(in: .whitespaces)
        guard let slash = trimmed.firstIndex(of: "/") else {
            throw GraftError("not a registry repository (no host): \(repoRef)")
        }
        let host = String(trimmed[..<slash])
        guard host.contains(".") || host.contains(":") else {
            throw GraftError("not a registry repository (need a host like ghcr.io): \(repoRef)")
        }
        var name = String(trimmed[trimmed.index(after: slash)...])
        // Drop a trailing `:tag` — a colon in the *last* path segment is a tag, not a port.
        if let lastSlash = name.lastIndex(of: "/") {
            let tail = name[name.index(after: lastSlash)...]
            if let colon = tail.lastIndex(of: ":") { name = String(name[..<colon]) }
        } else if let colon = name.lastIndex(of: ":") {
            name = String(name[..<colon])
        }
        guard !name.isEmpty else { throw GraftError("not a registry repository (no path): \(repoRef)") }
        return (host, name)
    }

    /// Parse the comma-separated `key="value"` params of a `Bearer` auth challenge.
    static func parseBearerChallenge(_ header: String) -> [String: String] {
        var rest = header.trimmingCharacters(in: .whitespaces)
        if rest.lowercased().hasPrefix("bearer ") { rest = String(rest.dropFirst(7)) }
        var out: [String: String] = [:]
        for pair in rest.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0) }
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            out[key] = value
        }
        return out
    }

    /// Order tags for a picker: `latest` pinned first, then the rest with the newest-looking
    /// last entries first (registries append new tags, so reversing the list ≈ newest-first),
    /// de-duplicated.
    static func order(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        if tags.contains("latest") { out.append("latest"); seen.insert("latest") }
        for tag in tags.reversed() where !seen.contains(tag) {
            out.append(tag); seen.insert(tag)
        }
        return out
    }
}
