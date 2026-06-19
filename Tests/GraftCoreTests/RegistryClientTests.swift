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

    @Test("catalog filters by guest OS and carries no tags in the repo ref")
    func catalogByOS() {
        let mac = RegistryCatalog.images(for: .macOS)
        let linux = RegistryCatalog.images(for: .linux)
        #expect(!mac.isEmpty)
        #expect(!linux.isEmpty)
        #expect(mac.allSatisfy { $0.os == .macOS })
        #expect(linux.allSatisfy { $0.os == .linux })
        #expect(RegistryCatalog.known.allSatisfy { !$0.repository.contains(":") })
        #expect(RegistryCatalog.known.allSatisfy { $0.repository.hasPrefix("ghcr.io/") })
    }
}
