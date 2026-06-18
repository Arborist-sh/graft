import ArgumentParser
import GraftCore

/// `graft config …` — validate a config or print a starter template.
struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Validate configuration or print a starter template.",
        subcommands: [Validate.self, Template.self]
    )
}

extension ConfigCommand {
    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check that a config is well-formed.")

        @Option(name: .shortAndLong, help: "Config path (overrides profile resolution).")
        var config: String?

        @Option(name: .long, help: "Profile to validate (default: active profile).")
        var profile: String?

        @Flag(help: "Skip checking that App private keys are present in the Keychain.")
        var skipKeys = false

        func run() async throws {
            let path = GraftConfig.resolvePath(explicit: config, profile: profile)
            let cfg = try GraftConfig.load(from: path)

            // Structural problems are fatal.
            let problems = cfg.validate()
            guard problems.isEmpty else {
                printErr("✗ \(path): \(problems.count) problem(s)")
                for problem in problems { printErr("  • \(problem)") }
                throw ExitCode.failure
            }
            print("✓ \(path) is structurally valid (\(cfg.pools.count) pool(s))")

            // Key resolvability is a warning, not a failure — keys may live in the
            // system keychain (sudo) or be imported later on a control host.
            guard !skipKeys else { return }
            // Each App's key is looked up in its own recorded keychain scope.
            for gh in cfg.distinctGitHubConfigs().sorted(by: { $0.appId < $1.appId }) {
                let store = KeychainSecretStore(scope: gh.scope)
                do {
                    _ = try await store.privateKeyPEM(forAppID: gh.appId)
                    print("  ✓ app \(gh.appId): key present in \(gh.scope.rawValue) keychain")
                } catch {
                    printErr("  ⚠ app \(gh.appId): \(error)")
                }
            }
        }
    }

    struct Template: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a starter config to stdout.")

        func run() throws {
            print(GraftConfig.template())
        }
    }
}
