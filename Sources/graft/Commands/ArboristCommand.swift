import ArgumentParser
import Foundation
import GraftCore

/// `graft arborist` — the caretaker. Everything operational routes through here:
///
///   graft arborist tend       supervise the pool (+ --monitor to report health)
///   graft arborist check      verify the GitHub App auth chain (no VM boot)
///   graft arborist canopy     at-a-glance tree overview
///   graft arborist leaves     list leaves (VMs)
///   graft arborist branches   list branches (workers)
///   graft arborist runners    list / prune GitHub runners
///
/// A parent command — run a subcommand. (`Run` registers here as `tend`, `Tree.Status`
/// as `canopy`; the structs live in their own files.)
struct Arborist: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "arborist",
        abstract: "Tend the tree — supervise, check, and inspect.",
        subcommands: [Run.self, Check.self, Tree.Status.self, Tree.Branches.self, Tree.Leaves.self, Runners.self]
    )
}

/// `graft arborist check` — verify the whole GitHub App auth chain against the real API
/// without booting a VM: read key → sign JWT → find installation → mint token → create a
/// probe JIT runner → delete it. Leaves no trace on the org.
///
/// Run it bare and it picks the App from the keys in your keychain and prompts for the
/// target; or pass `--app-id`/`--target` to skip the prompts; or `--config`/`--pool` to
/// check pools from a config file.
struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Verify the GitHub App auth chain end-to-end (no VM boot)."
    )

    @Option(name: .long, help: "GitHub App ID for a one-off check (default: check the active profile's pools).")
    var appId: Int?

    @Option(name: .long, help: "Target 'org:NAME'/'repo:OWNER/NAME' for a one-off check (default: the active profile's pools).")
    var target: String?

    @Option(name: .long, help: "Runner group id for the probe runner (default 1).")
    var runnerGroupId: Int = 1

    @Option(name: .shortAndLong, help: "Check pools from this config file instead of the keychain.")
    var config: String?

    @Option(name: .long, help: "Check pools from this profile instead of the keychain.")
    var profile: String?

    @Option(name: .long, help: "With --config/--profile, only check this pool.")
    var pool: String?

    @Flag(help: "Stop after minting a token — don't create/delete a probe runner.")
    var noProbe = false

    func run() async throws {
        let targets: [GitHubConfig]

        if appId != nil || target != nil {
            // Ad-hoc mode: an explicit App/target was given — check that one (prompt for
            // whichever half is missing). For one-off checks outside a profile. There's no
            // recorded scope, so we *find* the key — scan both keychains for where it lives.
            let resolvedAppID: Int
            let scope: KeychainScope
            if let appId {
                resolvedAppID = appId
                scope = Self.locateKey(forAppID: appId)
            } else {
                (resolvedAppID, scope) = try Self.pickAppID()
            }
            let resolvedTarget = try target ?? Self.promptTarget()
            targets = [GitHubConfig(appId: resolvedAppID, target: resolvedTarget, runnerGroupId: runnerGroupId, scope: scope)]
        } else {
            // Profile mode (default): check the GitHub config every pool registers against
            // (resolved: pool override, else the profile default) — nothing to retype. Each
            // config carries its own keychain scope.
            let path = GraftConfig.resolvePath(explicit: config, profile: profile)
            let cfg = try GraftConfig.load(from: path)
            let filtered = pool.map { name in cfg.pools.filter { $0.name == name } } ?? cfg.pools
            guard !filtered.isEmpty else {
                throw GraftError(pool.map { "no pool named '\($0)'" }
                    ?? "no pools in the active profile — run `graft init`, or pass --app-id/--target for a one-off check")
            }
            var seen = Set<String>()
            targets = filtered.compactMap { cfg.gitHub(for: $0) }
                .filter { seen.insert("\($0.appId)|\($0.target)").inserted }
            guard !targets.isEmpty else {
                throw GraftError("profile has no GitHub config — set a top-level `github`, or pass --app-id/--target")
            }
        }

        let allPassed = await Self.verify(targets: targets, probe: !noProbe)
        if !allPassed { throw ExitCode.failure }
        print("\nall checks passed ✓  — GitHub App auth is wired correctly")
    }

    /// Run the GitHub App auth chain against the real API for each config: sign an App JWT
    /// → discover the installation → mint an installation token → (optionally) create and
    /// immediately delete a probe JIT runner. Each App's key is read from its own recorded
    /// keychain scope. Prints progress; returns true iff every step of every target passed.
    /// Shared by `arborist check` and the `init` wizard's verify step.
    @discardableResult
    static func verify(targets: [GitHubConfig], probe: Bool = true) async -> Bool {
        func ok(_ message: String) { print("  ✓ \(message)") }
        func fail(_ step: String, _ error: Error) { printErr("  ✗ \(step): \(error)") }

        var failed = false
        for gh in targets {
            let client = GitHubAppClient(appID: gh.appId, secrets: KeychainSecretStore(scope: gh.scope))
            let scope = gh.scope
            print("── app \(gh.appId), \(gh.target) ──")

            let parsedTarget: GitHubTarget
            do { parsedTarget = try gh.parsedTarget() }
            catch { fail("parse target", error); failed = true; continue }

            do { _ = try await client.makeAppJWT(); ok("read key from \(scope.rawValue) keychain + signed App JWT") }
            catch { fail("sign App JWT", error); failed = true; continue }

            do {
                let id = try await client.installationID(for: parsedTarget)
                ok("found App installation (#\(id))")
            } catch { fail("discover installation", error); failed = true; continue }

            do { _ = try await client.installationAccessToken(for: parsedTarget); ok("minted installation access token") }
            catch { fail("mint installation token", error); failed = true; continue }

            if !probe { continue }

            let probeName = "graft-doctor-" + UUID().uuidString.prefix(8).lowercased()
            do {
                let runner = try await client.generateJITRunner(github: gh, labels: ["self-hosted"], runnerName: probeName)
                ok("generated JIT config (runner #\(runner.runnerID), \(runner.encodedConfig.count)-byte blob)")
                do {
                    try await client.deleteRunner(id: runner.runnerID, target: parsedTarget)
                    ok("deleted probe runner #\(runner.runnerID)")
                } catch {
                    fail("delete probe runner #\(runner.runnerID) — remove it manually in GitHub", error)
                    failed = true
                }
            } catch { fail("generate JIT config", error); failed = true }
        }
        return !failed
    }

    // MARK: Interactive pickers

    /// Find which keychain holds an App's key — scan login then system (attribute-only, so
    /// no Keychain unlock prompt). Defaults to login if neither has it; the verify run then
    /// surfaces the missing key with a clear error.
    private static func locateKey(forAppID appID: Int) -> KeychainScope {
        for scope in [KeychainScope.login, .system] {
            if ((try? KeychainSecretStore(scope: scope).storedAppIDs()) ?? []).contains(appID) { return scope }
        }
        return .login
    }

    /// Choose an App from the keys stored across both keychains, returning the App ID and
    /// the keychain its key lives in. Auto-selects when there's only one. Listing reads
    /// attributes only — no Keychain prompt here.
    private static func pickAppID() throws -> (Int, KeychainScope) {
        let entries: [(id: Int, scope: KeychainScope)] =
            (((try? KeychainSecretStore(scope: .login).storedApps()) ?? []).map { ($0.id, KeychainScope.login) })
            + (((try? KeychainSecretStore(scope: .system).storedApps()) ?? []).map { ($0.id, KeychainScope.system) })
        guard !entries.isEmpty else {
            throw GraftError("no App keys in your keychains — run `graft secrets import --app-id <ID> --pem <path>`")
        }
        if entries.count == 1 {
            printErr("using app \(entries[0].id) (only key, in the \(entries[0].scope.rawValue) keychain)")
            return (entries[0].id, entries[0].scope)
        }
        printErr("App keys found:")
        for (index, e) in entries.enumerated() { printErr("  [\(index + 1)] app \(e.id) — \(e.scope.rawValue) keychain") }
        while true {
            FileHandle.standardError.write(Data("pick one [1-\(entries.count)]: ".utf8))
            guard let line = readLine() else { throw GraftError("no selection made") }
            if let choice = Int(line.trimmingCharacters(in: .whitespaces)), (1...entries.count).contains(choice) {
                return (entries[choice - 1].id, entries[choice - 1].scope)
            }
            printErr("  not a valid choice")
        }
    }

    private static func promptTarget() throws -> String {
        FileHandle.standardError.write(Data("target (org:NAME or repo:OWNER/NAME): ".utf8))
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty else {
            throw GraftError("no target given")
        }
        return line
    }
}
