import ArgumentParser
import Foundation
import GraftCore

/// `graft orchard …` — drive the whole Orchard lifecycle from graft so the multi-host
/// fleet is a one-stop shop (GFT-11). Internally these still shell out to the `orchard`
/// CLI, but you never have to leave graft: stand up a local controller (`dev`), wire a
/// profile at one (`init`), and inspect the fleet (`status` / `workers` / `vms`).
struct Orchard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orchard",
        abstract: "Stand up, configure, and inspect an Orchard fleet.",
        subcommands: [Dev.self, Init.self, Status.self, Workers.self, VMs.self]
    )
}

// MARK: - Shared helpers

extension Orchard {
    static let devURL = "http://127.0.0.1:6120"

    /// Fail early with an install hint if the `orchard` CLI isn't on PATH.
    static func requireOrchard() async throws {
        guard let r = try? await Shell.run("orchard", ["--version"]), r.succeeded else {
            throw GraftError("`orchard` not found on PATH — install it with `brew install cirruslabs/cli/orchard`")
        }
    }

    /// Build an `OrchardProvider` from a profile's orchard block, resolving the token
    /// from the Keychain when it isn't inline (same order as `graft run`).
    static func provider(profile: String?) throws -> OrchardProvider {
        let name = try resolveProfileName(profile)
        let cfg = try Profiles.load(name)
        guard var orchard = cfg.orchard else {
            throw GraftError("profile '\(name)' has no orchard config — run `graft orchard init`")
        }
        if (orchard.token ?? "").isEmpty {
            let scope = KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login
            orchard.token = KeychainSecretStore(scope: scope).orchardToken(account: orchard.serviceAccount)
        }
        return OrchardProvider(config: orchard)
    }
}

// MARK: - graft orchard dev

extension Orchard {
    /// Wrap `orchard dev` (controller + worker in one process) for a zero-setup local
    /// fleet — the way `graft dev` wraps Tart. Runs in the foreground; Ctrl-C stops it.
    struct Dev: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a local Orchard controller + worker (foreground)."
        )

        func run() async throws {
            try await Orchard.requireOrchard()
            printErr(ANSI.bold("Starting a local Orchard dev controller + worker…"))
            printErr("  controller: \(Orchard.devURL)  \(ANSI.dim("(unsecured — local only)"))")
            printErr("  next, in another terminal:")
            printErr("    \(ANSI.green("graft orchard init --local"))   \(ANSI.dim("# point a profile at this controller"))")
            printErr("    \(ANSI.green("graft run"))")
            printErr(ANSI.dim("  Ctrl-C here stops the controller (and its VMs).\n"))

            // Foreground passthrough — inherits the terminal, blocks until Ctrl-C.
            let code = try Shell.runInteractive("orchard", ["dev"])
            if code != 0 { throw ExitCode(code) }
        }
    }
}

// MARK: - graft orchard init

extension Orchard {
    /// Point a profile at an Orchard controller: pick/create the service account, stash
    /// its token in the Keychain (never plaintext config), and write the `orchard` block
    /// + `provider: "orchard"` into the active profile.
    struct Init: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Configure a profile to use an Orchard controller."
        )

        @Option(name: .long, help: "Profile to configure (default: active profile).")
        var profile: String?

        @Flag(name: .long, help: "Wire the local `orchard dev` controller (unsecured, no token).")
        var local = false

        func run() async throws {
            try await Orchard.requireOrchard()
            let profileName = resolveProfileNameOrDefault(profile)
            var cfg = (try? Profiles.load(profileName)) ?? GraftConfig(provider: "tart")
            let scope = KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login

            let orchard: OrchardConfig
            if local {
                printErr("Wiring profile '\(profileName)' to the local dev controller (\(Orchard.devURL)).")
                orchard = OrchardConfig(
                    controllerURL: URL(string: Orchard.devURL)!,
                    serviceAccount: "admin",            // unsecured dev ignores auth
                    token: nil,
                    maxVMs: cfg.orchard?.maxVMs
                )
            } else {
                let urlString = Prompt.line("Controller URL", default: "https://orchard.example.com:6120")
                guard let url = URL(string: urlString), url.scheme != nil else {
                    throw GraftError("'\(urlString)' isn't a valid URL")
                }
                let account = Prompt.line("Service account name", default: "graft")
                try await resolveServiceAccount(account, url: url, scope: scope)
                let maxVMs = Prompt.int("Max VMs graft should ask for (ceiling)", default: cfg.orchard?.maxVMs ?? 8)
                orchard = OrchardConfig(controllerURL: url, serviceAccount: account, token: nil, maxVMs: maxVMs)
            }

            cfg.provider = "orchard"
            cfg.orchard = orchard
            cfg.secrets = cfg.secrets ?? SecretsConfig(store: "keychain", scope: scope.rawValue)
            try Profiles.save(cfg, as: profileName)

            printErr("\n✓ profile '\(profileName)' now uses Orchard  →  \(Profiles.path(for: profileName))")
            let problems = cfg.validate()
            for problem in problems { printErr("  ⚠ \(problem)") }
            printErr("\nNext:  \(ANSI.green("graft orchard status"))   then   \(ANSI.green("graft run"))")
        }

        /// Ensure the service account exists and its token is in the Keychain. Tries to
        /// create it (works on the unsecured dev controller, or when you hold an admin
        /// `orchard context`); on failure, falls back to pasting an existing token.
        private func resolveServiceAccount(_ account: String, url: URL, scope: KeychainScope) async throws {
            let store = KeychainSecretStore(scope: scope)
            if store.orchardToken(account: account) != nil,
               !Prompt.confirm("A token for '\(account)' is already stored — replace it?", default: false) {
                return
            }

            let create = Prompt.confirm(
                "Create service account '\(account)' on the controller now? (needs admin access)",
                default: true
            )
            let token: String
            if create {
                // We pass our own token (the API autogenerates but doesn't echo it back),
                // so we know the value to store.
                token = UUID().uuidString.lowercased()
                var env = ProcessInfo.processInfo.environment
                env[OrchardEnv.url] = url.absoluteString
                let result = try await Shell.run("orchard", [
                    "create", "service-account", account,
                    "--roles", "compute:read", "--roles", "compute:write", "--roles", "compute:connect",
                    "--token", token,
                ], environment: env, timeout: .seconds(20))
                guard result.succeeded else {
                    printErr(ANSI.yellow("  couldn't create it: \(result.stderrTrimmed.isEmpty ? result.stdoutTrimmed : result.stderrTrimmed)"))
                    printErr("  (does it already exist, or do you lack admin access on the controller?)")
                    let pasted = Prompt.required("Paste an existing token for '\(account)'")
                    try store.storeOrchardToken(pasted, account: account)
                    printErr("✓ stored token for '\(account)' in the \(scope.rawValue) keychain")
                    return
                }
                printErr("✓ created service account '\(account)' (compute:read/write/connect)")
            } else {
                token = Prompt.required("Paste an existing token for '\(account)'")
            }
            try store.storeOrchardToken(token, account: account)
            printErr("✓ stored token for '\(account)' in the \(scope.rawValue) keychain")
        }
    }
}

// MARK: - graft orchard status / workers / vms

extension Orchard {
    /// One-glance fleet health: controller, worker count, free slots, graft's VMs.
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show fleet health (controller, workers, free slots).")

        @Option(name: .long, help: "Profile to read (default: active profile).")
        var profile: String?

        func run() async throws {
            let report = try await Orchard.provider(profile: profile).report()
            let paused = report.workers.filter(\.paused).count
            print("controller:  \(report.controllerURL)")
            print("workers:     \(report.workers.count)\(paused > 0 ? "  (\(paused) paused)" : "")")
            print("slots:       \(report.totalSlots) advertised · \(report.usedVMs) used · \(report.freeSlots) free")
            print("graft VMs:   \(report.graftVMNames.count)")
        }
    }

    /// Per-worker view with advertised slots, plus the fleet free-slot total.
    struct Workers: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List workers and their advertised VM slots.")

        @Option(name: .long, help: "Profile to read (default: active profile).")
        var profile: String?

        func run() async throws {
            let report = try await Orchard.provider(profile: profile).report()
            guard !report.workers.isEmpty else {
                printErr("no workers registered")
                return
            }
            let width = report.workers.map { $0.name.count }.max() ?? 8
            print("\(pad("WORKER", width))  PAUSED  SLOTS")
            for w in report.workers {
                print("\(pad(w.name, width))  \(pad(w.paused ? "yes" : "no", 6))  \(w.slots)")
            }
            printErr(ANSI.dim("— fleet: \(report.freeSlots) free / \(report.totalSlots) slots (\(report.usedVMs) used)"))
        }

        private func pad(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
        }
    }

    /// VMs on the controller — graft's by default, the whole cluster with `--all`.
    struct VMs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "vms",
            abstract: "List VMs on the controller (graft's by default)."
        )

        @Option(name: .long, help: "Profile to read (default: active profile).")
        var profile: String?

        @Flag(help: "Show every VM on the cluster, not just graft's.")
        var all = false

        func run() async throws {
            let listing = try await Orchard.provider(profile: profile).rawList("vms")
            let lines = listing.split(whereSeparator: \.isNewline).map(String.init)
            guard let header = lines.first else { printErr("no VMs"); return }
            let rows = all
                ? Array(lines.dropFirst())
                : lines.dropFirst().filter { $0.hasPrefix("graft-") }
            guard !rows.isEmpty else {
                printErr(all ? "no VMs" : "no graft-managed VMs (try --all)")
                return
            }
            print(header)
            rows.forEach { print($0) }
        }
    }
}

/// Like `resolveProfileName`, but falls back to "default" instead of throwing — `init`
/// can create the active profile if none exists yet.
private func resolveProfileNameOrDefault(_ explicit: String?) -> String {
    if let explicit { return explicit }
    return Profiles.activeName() ?? "default"
}
