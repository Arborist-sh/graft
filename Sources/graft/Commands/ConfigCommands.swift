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

        @Option(name: .shortAndLong, help: "Config path (default: $GRAFT_CONFIG or ~/.graft/config.json).")
        var config: String?

        func run() async throws {
            let path = GraftConfig.resolvePath(explicit: config)
            let cfg = try GraftConfig.load(from: path)
            let problems = cfg.validate()
            guard problems.isEmpty else {
                printErr("✗ \(path): \(problems.count) problem(s)")
                for problem in problems { printErr("  • \(problem)") }
                throw ExitCode.failure
            }
            print("✓ \(path) is valid (\(cfg.pools.count) pool(s))")
        }
    }

    struct Template: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a starter config to stdout.")

        func run() throws {
            print(GraftConfig.template())
        }
    }
}
