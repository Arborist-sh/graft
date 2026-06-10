import Foundation
import Testing
@testable import GraftCore

@Suite("Config parsing & validation")
struct ConfigTests {
    @Test("runnerGroupId defaults to 1 when omitted")
    func runnerGroupIdDefault() throws {
        let json = """
        { "appId": 42, "target": "org:acme" }
        """
        let gh = try JSONDecoder().decode(GitHubConfig.self, from: Data(json.utf8))
        #expect(gh.runnerGroupId == 1)
        #expect(gh.labels == nil)
    }

    @Test("labels default to [self-hosted, os, name] when unset")
    func defaultLabels() {
        let pool = PoolConfig(
            name: "macos-release",
            image: "img:latest",
            os: .macOS,
            count: 2,
            github: GitHubConfig(appId: 1, target: "org:acme")
        )
        #expect(pool.resolvedLabels() == ["self-hosted", "macos", "macos-release"])
    }

    @Test("explicit labels override the default")
    func explicitLabels() {
        let pool = PoolConfig(
            name: "p", image: "i", os: .linux, count: 1,
            github: GitHubConfig(appId: 1, target: "org:acme", labels: ["custom"])
        )
        #expect(pool.resolvedLabels() == ["custom"])
    }

    @Test("target parsing: org and repo")
    func targetParsing() throws {
        #expect(try GitHubTarget(parsing: "org:acme") == .org("acme"))
        #expect(try GitHubTarget(parsing: "repo:acme/widgets") == .repo(owner: "acme", name: "widgets"))
        #expect(try GitHubTarget(parsing: "org:acme").apiPath == "orgs/acme")
        #expect(try GitHubTarget(parsing: "repo:acme/widgets").apiPath == "repos/acme/widgets")
    }

    @Test("target parsing rejects malformed strings")
    func targetParsingRejects() {
        #expect(throws: GraftError.self) { _ = try GitHubTarget(parsing: "acme") }
        #expect(throws: GraftError.self) { _ = try GitHubTarget(parsing: "repo:acme") }
        #expect(throws: GraftError.self) { _ = try GitHubTarget(parsing: "team:acme") }
    }

    @Test("validation flags duplicate pools and bad targets")
    func validation() {
        let cfg = GraftConfig(pools: [
            PoolConfig(name: "dup", image: "i", os: .macOS, count: 1,
                       github: GitHubConfig(appId: 1, target: "org:acme")),
            PoolConfig(name: "dup", image: "", os: .macOS, count: 1,
                       github: GitHubConfig(appId: 1, target: "nonsense")),
        ])
        let problems = cfg.validate()
        #expect(problems.contains { $0.contains("duplicate pool name") })
        #expect(problems.contains { $0.contains("image is empty") })
    }

    @Test("a valid single-pool config has no problems")
    func validConfig() {
        let cfg = GraftConfig(pools: [
            PoolConfig(name: "p", image: "img:latest", os: .macOS, count: 2,
                       github: GitHubConfig(appId: 1, target: "org:acme")),
        ])
        #expect(cfg.validate().isEmpty)
    }
}
