import ArgumentParser
import GraftCore

/// `graft pool …` — flag-driven pool edits on a profile (scripting counterpart to
/// the `graft init` wizard).
struct Pool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pool",
        abstract: "Add, remove, or list pools in a profile.",
        subcommands: [Add.self, Remove.self, List.self]
    )
}

extension Pool {
    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add (or replace) a pool in a profile.")

        @Option(name: .long, help: "Profile to edit (default: active). Created if missing.")
        var profile: String?

        @Option(name: .long, help: "Pool name.")
        var name: String

        @Option(name: .long, help: "Tart image.")
        var image: String

        @Option(name: .long, help: "Guest OS (macos|linux).")
        var os: GuestOS = .macOS

        @Option(name: .long, help: "Number of runners.")
        var count: Int = 2

        @Option(name: .long, help: "GitHub App ID.")
        var appId: Int

        @Option(name: .long, help: "Target: org:NAME or repo:OWNER/NAME.")
        var target: String

        @Option(name: .long, help: "Runner group id (default 1).")
        var runnerGroupId: Int = 1

        @Option(name: .long, help: "Comma-separated labels (blank = default).")
        var labels: String?

        func run() throws {
            // Profile may not exist yet — create it on first add.
            let profileName = profile ?? Profiles.activeName() ?? "default"
            var config = Profiles.exists(profileName)
                ? try Profiles.load(profileName)
                : GraftConfig(provider: "tart", secrets: SecretsConfig())

            let labelList = labels?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            let pool = PoolConfig(
                name: name, image: image, os: os, count: count,
                github: GitHubConfig(appId: appId, target: target, runnerGroupId: runnerGroupId, labels: labelList)
            )
            let replaced = config.pools.contains { $0.name == name }
            config.pools.removeAll { $0.name == name }
            config.pools.append(pool)
            try Profiles.save(config, as: profileName)
            printErr("✓ \(replaced ? "replaced" : "added") pool '\(name)' in profile '\(profileName)'")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a pool from a profile.")

        @Option(name: .long, help: "Profile to edit (default: active).")
        var profile: String?

        @Argument(help: "Pool name.")
        var name: String

        func run() throws {
            let profileName = try resolveProfileName(profile)
            var config = try Profiles.load(profileName)
            guard config.pools.contains(where: { $0.name == name }) else {
                throw GraftError("profile '\(profileName)' has no pool named '\(name)'")
            }
            config.pools.removeAll { $0.name == name }
            try Profiles.save(config, as: profileName)
            printErr("✓ removed pool '\(name)' from profile '\(profileName)'")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List pools in a profile.")

        @Option(name: .long, help: "Profile to list (default: active).")
        var profile: String?

        func run() throws {
            let profileName = try resolveProfileName(profile)
            let config = try Profiles.load(profileName)
            guard !config.pools.isEmpty else {
                printErr("profile '\(profileName)' has no pools")
                return
            }
            for pool in config.pools {
                print("\(pool.name)\t\(pool.os.rawValue)\tx\(pool.count)\t\(pool.image)\tapp \(pool.github.appId)\t\(pool.github.target)")
            }
        }
    }
}
