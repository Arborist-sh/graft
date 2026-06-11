import ArgumentParser
import Foundation
import GraftCore

/// `graft init` — interactive one-stop setup: build a profile, add pools, pick the
/// App from the keychain (importing its PEM if needed), and set it active.
struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Interactive setup: create a profile, add pools, import keys."
    )

    @Flag(help: "Store/read keys in the system keychain (headless hosts).")
    var system = false

    func run() throws {
        let scope: KeychainScope = system ? .system : .login
        printErr("Graft setup — let's build a profile.\n")

        let profileName = Prompt.line("Profile name", default: "default")
        var config = Profiles.exists(profileName)
            ? ((try? Profiles.load(profileName)) ?? GraftConfig())
            : GraftConfig(provider: "tart")
        if Profiles.exists(profileName) {
            printErr("(extending existing profile '\(profileName)')")
        }

        repeat {
            let pool = try buildPool(scope: scope)
            config.pools.removeAll { $0.name == pool.name }
            config.pools.append(pool)
        } while Prompt.confirm("Add another pool?", default: false)

        config.secrets = SecretsConfig(store: "keychain", scope: scope.rawValue)
        try Profiles.save(config, as: profileName)
        printErr("\n✓ wrote profile '\(profileName)'  →  \(Profiles.path(for: profileName))")

        if Prompt.confirm("Make '\(profileName)' the active profile?", default: true) {
            try Profiles.setActive(profileName)
            printErr("✓ active profile is now '\(profileName)'")
        }

        let problems = config.validate()
        if problems.isEmpty {
            printErr("✓ config is valid")
        } else {
            for problem in problems { printErr("  ⚠ \(problem)") }
        }
        printErr("\nNext:  graft doctor   (verify GitHub auth)   then   graft run")
    }

    private func buildPool(scope: KeychainScope) throws -> PoolConfig {
        printErr("\n— New pool —")
        let name = Prompt.line("Pool name", default: "mac")
        let os: GuestOS = Prompt.choose("Guest OS?", ["macOS", "Linux"]) == 0 ? .macOS : .linux
        let defaultImage = os == .macOS
            ? "ghcr.io/cirruslabs/macos-sequoia-base:latest"
            : "ghcr.io/cirruslabs/ubuntu:latest"
        let image = Prompt.line("Tart image", default: defaultImage)
        let count = Prompt.int("How many runners?", default: os == .macOS ? 2 : 4)
        let appID = try AppPicker.resolve(scope: scope)
        let target = Prompt.required("Target (org:NAME or repo:OWNER/NAME)")
        let labelsRaw = Prompt.line("Labels (comma-separated; blank = default)", default: "")
        let labels = labelsRaw.isEmpty
            ? nil
            : labelsRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        return PoolConfig(
            name: name, image: image, os: os, count: count,
            github: GitHubConfig(appId: appID, target: target, runnerGroupId: 1, labels: labels)
        )
    }
}
