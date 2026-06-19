import Foundation
import Testing
@testable import GraftCore

@Suite("Registry repository parsing & catalog")
struct RegistryClientTests {

    @Test("splits host/path with no tag")
    func splitNoTag() throws {
        let (host, name) = try RegistryClient.split("ghcr.io/cirruslabs/macos-tahoe-xcode")
        #expect(host == "ghcr.io")
        #expect(name == "cirruslabs/macos-tahoe-xcode")
    }

    @Test("drops a trailing :tag from the path")
    func splitWithTag() throws {
        let (host, name) = try RegistryClient.split("ghcr.io/cirruslabs/macos-tahoe-xcode:26.1")
        #expect(host == "ghcr.io")
        #expect(name == "cirruslabs/macos-tahoe-xcode")
    }

    @Test("keeps a port on the host but strips the image tag")
    func splitWithPortAndTag() throws {
        let (host, name) = try RegistryClient.split("localhost:5000/team/img:latest")
        #expect(host == "localhost:5000")
        #expect(name == "team/img")
    }

    @Test("rejects a bare local name with no host")
    func splitRejectsBareName() {
        #expect(throws: GraftError.self) { try RegistryClient.split("my-local-image") }
    }

    @Test("rejects a single-segment host that isn't a registry")
    func splitRejectsNonHost() {
        // "owner/name" — "owner" has no dot/colon, so it's not a registry host.
        #expect(throws: GraftError.self) { try RegistryClient.split("owner/name") }
    }

    @Test("parses a ghcr-style Bearer challenge")
    func parseChallenge() {
        let header = #"Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:cirruslabs/macos-tahoe-xcode:pull""#
        let params = RegistryClient.parseBearerChallenge(header)
        #expect(params["realm"] == "https://ghcr.io/token")
        #expect(params["service"] == "ghcr.io")
        #expect(params["scope"] == "repository:cirruslabs/macos-tahoe-xcode:pull")
    }

    @Test("tolerates a challenge without the leading scheme word")
    func parseChallengeNoScheme() {
        let params = RegistryClient.parseBearerChallenge(#"realm="https://r/token", service="r""#)
        #expect(params["realm"] == "https://r/token")
        #expect(params["service"] == "r")
    }

    @Test("orders tags: latest first, then newest-looking first, de-duped")
    func ordering() {
        let ordered = RegistryClient.order(["26.0", "latest", "26.1", "26.2", "latest"])
        #expect(ordered.first == "latest")
        #expect(ordered == ["latest", "26.2", "26.1", "26.0"])
    }

    @Test("ordering without a latest tag just reverses")
    func orderingNoLatest() {
        #expect(RegistryClient.order(["a", "b", "c"]) == ["c", "b", "a"])
    }

    @Test("default catalog is well-formed, OS-tagged, and ghcr-hosted")
    func catalogDefaults() {
        let defaults = RegistryCatalog.defaults
        #expect(!defaults.isEmpty)
        #expect(defaults.contains { $0.os == .macOS })
        #expect(defaults.contains { $0.os == .linux })
        #expect(defaults.allSatisfy { !$0.repository.contains(":") })   // no baked-in tags
        #expect(defaults.allSatisfy { $0.repository.hasPrefix("ghcr.io/") })
        #expect(defaults.allSatisfy { $0.host == "ghcr.io" })           // host derived
    }

    @Test("userAdded derives a title from the last segment and strips a tag")
    func userAddedEntry() {
        let e = RegistryImage.userAdded("ghcr.io/briancorbin/g1-mobile-ci:latest")
        #expect(e.title == "g1-mobile-ci")
        #expect(e.host == "ghcr.io")
        #expect(e.blurb.isEmpty)
        #expect(e.os == nil)   // unknown OS → shows for any pool
    }

    @Test("derives host / owner / imageName / ownerKey from a repo ref")
    func ownerDerivation() {
        let e = RegistryImage(repository: "ghcr.io/cirruslabs/macos-tahoe-xcode", title: "x")
        #expect(e.host == "ghcr.io")
        #expect(e.owner == "cirruslabs")
        #expect(e.imageName == "macos-tahoe-xcode")
        #expect(e.ownerKey == "ghcr.io/cirruslabs")
    }

    @Test("handles a nested owner path and a bare host/name")
    func ownerEdgeCases() {
        let nested = RegistryImage(repository: "ghcr.io/org/team/img", title: "x")
        #expect(nested.owner == "org/team")
        #expect(nested.imageName == "img")
        #expect(nested.ownerKey == "ghcr.io/org/team")

        let bare = RegistryImage(repository: "registry.local/img", title: "x")
        #expect(bare.owner == "")
        #expect(bare.imageName == "img")
        #expect(bare.ownerKey == "registry.local")   // falls back to host when no owner
    }

    @Test("decodes a sparse entry (repository only), deriving title/blurb/os")
    func decodeSparse() throws {
        let json = Data(#"{"repository":"ghcr.io/me/img"}"#.utf8)
        let e = try JSONDecoder().decode(RegistryImage.self, from: json)
        #expect(e.repository == "ghcr.io/me/img")
        #expect(e.title == "img")
        #expect(e.blurb.isEmpty)
        #expect(e.os == nil)
    }

    @Test("a nil-OS entry shows for any pool; a tagged entry only for its OS")
    func osFiltering() {
        let mixed = [
            RegistryImage(repository: "ghcr.io/a/mac", title: "mac", os: .macOS),
            RegistryImage(repository: "ghcr.io/a/linux", title: "linux", os: .linux),
            RegistryImage(repository: "ghcr.io/a/any", title: "any", os: nil),
        ]
        let forMac = mixed.filter { $0.os == nil || $0.os == .macOS }
        #expect(forMac.map(\.title).sorted() == ["any", "mac"])
    }
}
