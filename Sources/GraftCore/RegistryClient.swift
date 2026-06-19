import Foundation

/// A well-known public base image you can pull from a registry. ghcr.io — where the
/// cirruslabs base images live — has no repo-listing API, so the "browse" experience is
/// seeded from this hand-curated set. But `RegistryClient.tags(forRepository:)` works for
/// *any* repo ref, so a typed-in repository is a first-class citizen too.
public struct RegistryImage: Sendable, Hashable, Codable {
    /// Host + path, no tag — e.g. `ghcr.io/cirruslabs/macos-tahoe-xcode`.
    public let repository: String
    /// Human label for the picker, e.g. "macOS Tahoe · Xcode".
    public let title: String
    public let os: GuestOS
    /// One-liner shown under the title.
    public let blurb: String

    public init(repository: String, title: String, os: GuestOS, blurb: String) {
        self.repository = repository
        self.title = title
        self.os = os
        self.blurb = blurb
    }
}

/// The curated set of base repositories offered when browsing a registry. Kept small and
/// hand-maintained on purpose: ghcr.io won't enumerate repos for us, and these are the
/// images Graft is actually built around (cirruslabs' Tart bases). Anything outside this
/// list still works by typing the repository ref.
public enum RegistryCatalog {
    public static let known: [RegistryImage] = [
        // macOS — current Tart bases. `-base` is a clean OS; `-xcode` adds the Xcode toolchain.
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-tahoe-base",
                      title: "macOS Tahoe · base", os: .macOS,
                      blurb: "macOS 26 Tahoe, clean — bring your own toolchain"),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-tahoe-xcode",
                      title: "macOS Tahoe · Xcode", os: .macOS,
                      blurb: "macOS 26 Tahoe with Xcode + the iOS toolchain baked in"),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-sequoia-base",
                      title: "macOS Sequoia · base", os: .macOS,
                      blurb: "macOS 15 Sequoia, clean — bring your own toolchain"),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-sequoia-xcode",
                      title: "macOS Sequoia · Xcode", os: .macOS,
                      blurb: "macOS 15 Sequoia with Xcode + the iOS toolchain baked in"),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-sonoma-base",
                      title: "macOS Sonoma · base", os: .macOS,
                      blurb: "macOS 14 Sonoma, clean — bring your own toolchain"),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-sonoma-xcode",
                      title: "macOS Sonoma · Xcode", os: .macOS,
                      blurb: "macOS 14 Sonoma with Xcode + the iOS toolchain baked in"),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-ventura-base",
                      title: "macOS Ventura · base", os: .macOS,
                      blurb: "macOS 13 Ventura, clean — bring your own toolchain"),
        RegistryImage(repository: "ghcr.io/cirruslabs/macos-ventura-xcode",
                      title: "macOS Ventura · Xcode", os: .macOS,
                      blurb: "macOS 13 Ventura with Xcode + the iOS toolchain baked in"),
        // Linux — planned future epic, but the picker shouldn't hide the bases that exist.
        RegistryImage(repository: "ghcr.io/cirruslabs/ubuntu",
                      title: "Ubuntu", os: .linux,
                      blurb: "Cirrus Labs' Ubuntu Tart base"),
        RegistryImage(repository: "ghcr.io/cirruslabs/debian",
                      title: "Debian", os: .linux,
                      blurb: "Cirrus Labs' Debian Tart base"),
    ]

    /// The curated images for a guest OS, in display order.
    public static func images(for os: GuestOS) -> [RegistryImage] {
        known.filter { $0.os == os }
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
    /// is rejected — it has no registry to query.
    static func split(_ repoRef: String) throws -> (host: String, name: String) {
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
