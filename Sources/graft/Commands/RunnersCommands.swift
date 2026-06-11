import ArgumentParser
import GraftCore

/// `graft runners …` — inspect and clean up the runner registrations Graft has
/// created on GitHub. JIT runners that never ran a job (e.g. killed on shutdown)
/// linger as "offline"; `prune` sweeps those husks. The supervisor now deregisters
/// runners on teardown, so this is mainly a safety net + manual cleanup.
struct Runners: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runners",
        abstract: "List or prune graft's GitHub runner registrations.",
        subcommands: [List.self, Prune.self]
    )
}

extension Runners {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List graft runners on GitHub for a profile's targets.")

        @Option(name: .long, help: "Profile to read targets from (default: active).")
        var profile: String?

        @Flag(help: "Use the system keychain instead of login.")
        var system = false

        func run() async throws {
            let (pools, scope) = try profileTargets(profile: profile, system: system)
            let secrets = KeychainSecretStore(scope: scope)
            for pool in pools {
                let parsed = try pool.github.parsedTarget()
                let client = GitHubAppClient(appID: pool.github.appId, secrets: secrets)
                let runners = try await client.listRunners(target: parsed)
                    .filter { $0.name.hasPrefix(LocalTartProvider.namePrefix) }
                print("── app \(pool.github.appId), \(pool.github.target) ──")
                if runners.isEmpty { print("  (no graft runners)"); continue }
                for r in runners {
                    print("  \(r.isOffline ? "⚪️ offline" : "🟢 online ")  \(r.name)  #\(r.id)")
                }
            }
        }
    }

    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete offline graft runner husks on GitHub.")

        @Option(name: .long, help: "Profile to read targets from (default: active).")
        var profile: String?

        @Flag(help: "Use the system keychain instead of login.")
        var system = false

        @Flag(name: .long, help: "Also remove online runners (dangerous — kills live registrations).")
        var includeOnline = false

        func run() async throws {
            let (pools, scope) = try profileTargets(profile: profile, system: system)
            let secrets = KeychainSecretStore(scope: scope)
            var deleted = 0
            for pool in pools {
                let parsed = try pool.github.parsedTarget()
                let client = GitHubAppClient(appID: pool.github.appId, secrets: secrets)
                let husks = try await client.listRunners(target: parsed).filter {
                    $0.name.hasPrefix(LocalTartProvider.namePrefix) && (includeOnline || $0.isOffline)
                }
                guard !husks.isEmpty else {
                    printErr("✓ \(pool.github.target): nothing to prune")
                    continue
                }
                for r in husks {
                    do {
                        try await client.deleteRunner(id: r.id, target: parsed)
                        deleted += 1
                        printErr("  ✓ removed \(r.name) (#\(r.id))")
                    } catch {
                        printErr("  ✗ \(r.name) (#\(r.id)): \(error)")
                    }
                }
            }
            printErr("pruned \(deleted) runner(s)")
        }
    }
}

/// The distinct (app, target) pools of a profile, plus the keychain scope to read
/// their App keys from. Deduped so a target shared by several pools is hit once.
private func profileTargets(profile: String?, system: Bool) throws -> (pools: [PoolConfig], scope: KeychainScope) {
    let name = try resolveProfileName(profile)
    let cfg = try Profiles.load(name)
    guard !cfg.pools.isEmpty else { throw GraftError("profile '\(name)' has no pools") }

    var seen = Set<String>()
    let distinct = cfg.pools.filter { seen.insert("\($0.github.appId)|\($0.github.target)").inserted }
    let scope: KeychainScope = system ? .system : (KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login)
    return (distinct, scope)
}
