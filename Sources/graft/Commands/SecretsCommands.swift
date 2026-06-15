import ArgumentParser
import Foundation
import GraftCore

/// `graft secrets …` — manage GitHub App private keys in the macOS Keychain.
/// The PEM never lives on disk; this is how it gets in (and out of) the Keychain.
struct Secrets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secrets",
        abstract: "Manage GitHub App private keys in the macOS Keychain.",
        subcommands: [CreateApp.self, Import.self, List.self, Remove.self]
    )
}

/// Login (default) vs. system keychain, shared by all `secrets` subcommands.
struct KeychainScopeOptions: ParsableArguments {
    @Flag(help: "Use the system keychain — for headless `--daemon` hosts. Writing needs sudo.")
    var system = false

    var scope: KeychainScope { system ? .system : .login }
    var store: KeychainSecretStore { KeychainSecretStore(scope: scope) }
}

extension Secrets {
    /// Create a brand-new GitHub App via the manifest flow — opens the browser, you click
    /// "Create GitHub App", and graft receives the App ID + private key automatically and
    /// stores the key in the Keychain. No copy-pasting the ID, no downloading the .pem.
    struct CreateApp: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create-app",
            abstract: "Create a new GitHub App in your browser; store its key automatically."
        )

        @Option(name: .long, help: "Create it under an organization (you must be an org owner) instead of your account.")
        var org: String?

        @Option(name: .long, help: "Desired App name (globally unique). Omit to name it on GitHub.")
        var name: String?

        @Option(name: .long, help: "Also set this profile's GitHub App ID to the new App.")
        var profile: String?

        @OptionGroup var keychain: KeychainScopeOptions

        func run() async throws {
            let account: AppManifestFlow.Account = org.map { .org($0) } ?? .user
            printErr("Opening your browser — click “Create GitHub App” on GitHub, then come back here…")

            let created = try await AppManifestFlow.run(account: account, name: name) { url in
                Self.open(url)
            }

            try keychain.store.store(pem: created.pem, forAppID: created.appID)
            printErr("✓ created App “\(created.name)” (id \(created.appID)); key stored in the \(keychain.scope.rawValue) keychain")

            if let profile {
                var cfg = try Profiles.load(profile)
                cfg.github = GitHubConfig(
                    appId: created.appID,
                    target: cfg.github?.target ?? "",
                    runnerGroupId: cfg.github?.runnerGroupId ?? 1
                )
                try Profiles.save(cfg, as: profile)
                printErr("✓ set profile “\(profile)” App ID to \(created.appID)")
            }

            printErr("→ last step — install the App on your org/repo:")
            printErr("  \(created.installURL)")
            Self.open(URL(string: created.installURL)!)
        }

        /// Open a URL in the default browser via `open(1)` (no AppKit dependency in the CLI).
        static func open(_ url: URL) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [url.absoluteString]
            try? p.run()
        }
    }

    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Import an App private-key PEM into the Keychain (then shred the file)."
        )

        @Option(name: .long, help: "GitHub App ID.")
        var appId: Int

        @Option(name: .long, help: "Path to the App private-key .pem.")
        var pem: String

        @OptionGroup var keychain: KeychainScopeOptions

        func run() async throws {
            let path = (pem as NSString).expandingTildeInPath
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw GraftError("can't read PEM at \(path)")
            }
            try PrivateKeyValidator.validate(pem: contents)
            try keychain.store.store(pem: contents, forAppID: appId)
            printErr("✓ stored key for app \(appId) in the \(keychain.scope.rawValue) keychain")
            printErr("  now shred the file:  rm -P \(path)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List App IDs with a stored key.")

        @OptionGroup var keychain: KeychainScopeOptions

        func run() throws {
            let ids = try keychain.store.storedAppIDs()
            guard !ids.isEmpty else {
                printErr("no keys in the \(keychain.scope.rawValue) keychain")
                return
            }
            for id in ids { print(id) }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Remove a stored key."
        )

        @Option(name: .long, help: "GitHub App ID.")
        var appId: Int

        @OptionGroup var keychain: KeychainScopeOptions

        func run() throws {
            try keychain.store.remove(appID: appId)
            printErr("✓ removed key for app \(appId) from the \(keychain.scope.rawValue) keychain")
        }
    }
}
