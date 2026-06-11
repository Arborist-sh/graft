import Foundation
import GraftCore

/// Tiny stdin/stderr prompt helpers for interactive commands. Questions go to
/// stderr so stdout stays clean; answers are read from stdin.
enum Prompt {
    static func line(_ question: String, default fallback: String? = nil) -> String {
        let suffix = fallback.map { " [\($0)]" } ?? ""
        FileHandle.standardError.write(Data("\(question)\(suffix): ".utf8))
        let input = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        if input.isEmpty, let fallback { return fallback }
        return input
    }

    static func required(_ question: String) -> String {
        while true {
            let value = line(question)
            if !value.isEmpty { return value }
            printErr("  (required)")
        }
    }

    static func int(_ question: String, default fallback: Int) -> Int {
        while true {
            let value = line(question, default: String(fallback))
            if let number = Int(value) { return number }
            printErr("  (enter a number)")
        }
    }

    static func positiveInt(_ question: String) -> Int {
        while true {
            let value = line(question)
            if let number = Int(value), number > 0 { return number }
            printErr("  (enter a positive number)")
        }
    }

    static func confirm(_ question: String, default fallback: Bool = true) -> Bool {
        let hint = fallback ? "Y/n" : "y/N"
        let value = line("\(question) (\(hint))").lowercased()
        if value.isEmpty { return fallback }
        return value.hasPrefix("y")
    }

    /// Present a numbered menu, return the chosen index.
    static func choose(_ question: String, _ options: [String]) -> Int {
        printErr(question)
        for (index, option) in options.enumerated() { printErr("  [\(index + 1)] \(option)") }
        while true {
            let value = line("pick [1-\(options.count)]")
            if let number = Int(value), (1...options.count).contains(number) { return number - 1 }
            printErr("  not a valid choice")
        }
    }
}

/// Resolve a GitHub App ID interactively: pick from keys already in the keychain,
/// or enter a new one — and if that App has no key yet, offer to import its PEM.
enum AppPicker {
    static func resolve(scope: KeychainScope) throws -> Int {
        let store = KeychainSecretStore(scope: scope)
        let existing = (try? store.storedAppIDs()) ?? []   // attribute read — no Keychain prompt

        if existing.isEmpty {
            printErr("(no App keys in the \(scope.rawValue) keychain yet)")
            return try enterNew(store: store, scope: scope)
        }

        var options = existing.map { "app \($0)" }
        options.append("enter a different App ID…")
        let choice = Prompt.choose("Which GitHub App?", options)
        if choice < existing.count { return existing[choice] }
        return try enterNew(store: store, scope: scope)
    }

    private static func enterNew(store: KeychainSecretStore, scope: KeychainScope) throws -> Int {
        let appID = Prompt.positiveInt("GitHub App ID")
        let hasKey = ((try? store.storedAppIDs()) ?? []).contains(appID)
        if !hasKey, Prompt.confirm("No key stored for app \(appID). Import a .pem now?", default: true) {
            let path = (Prompt.required("Path to the App private-key .pem") as NSString).expandingTildeInPath
            guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw GraftError("can't read PEM at \(path)")
            }
            try PrivateKeyValidator.validate(pem: pem)
            try store.store(pem: pem, forAppID: appID)
            printErr("✓ stored key for app \(appID) in the \(scope.rawValue) keychain")
            printErr("  shred the file:  rm -P \(path)")
        }
        return appID
    }
}

/// Pick a Tart image for a pool: choose from what's already on the machine
/// (local clones + pulled OCI images via `tart list`), or type any registry ref.
/// No baked-in default — the menu reflects reality.
enum ImagePicker {
    static func resolve() async -> String {
        let prompt = "Tart image (e.g. ghcr.io/cirruslabs/macos-tahoe-base:latest)"
        let available = (try? await Tart.list()) ?? []

        // Drop digest-pinned duplicates (`name@sha256:…`) — the tag/name ref is
        // what people clone from. Dedupe and sort.
        let names = available.map(\.name).filter { !$0.contains("@sha256:") }
        let unique = Array(Set(names)).sorted()
        guard !unique.isEmpty else { return Prompt.required(prompt) }

        let sourceByName = Dictionary(
            available.map { ($0.name, $0.source ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        var options = unique.map { name -> String in
            let src = (sourceByName[name] ?? "").lowercased()
            return src.isEmpty ? name : "\(name)  (\(src))"
        }
        options.append("enter a custom image…")

        let choice = Prompt.choose("Which Tart image?", options)
        return choice < unique.count ? unique[choice] : Prompt.required(prompt)
    }
}

/// Shared interactive flows behind `init`, `profile create`, and `pool new` —
/// one source of truth so the three entry points can't drift.
enum Wizard {
    /// Prompt for a single pool's fields (image via `ImagePicker`, App via `AppPicker`).
    static func buildPool(scope: KeychainScope) async throws -> PoolConfig {
        printErr("\n— New pool —")
        let name = Prompt.line("Pool name", default: "mac")
        let os: GuestOS = Prompt.choose("Guest OS?", ["macOS", "Linux"]) == 0 ? .macOS : .linux
        let image = await ImagePicker.resolve()
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

    /// Full profile wizard: name → one-or-more pools → keychain secrets → save →
    /// optionally set active → validate. Returns the profile name.
    @discardableResult
    static func createProfile(scope: KeychainScope, makeActiveDefault: Bool = true) async throws -> String {
        printErr("Graft setup — let's build a profile.\n")

        let profileName = Prompt.line("Profile name", default: "default")
        var config = Profiles.exists(profileName)
            ? ((try? Profiles.load(profileName)) ?? GraftConfig())
            : GraftConfig(provider: "tart")
        if Profiles.exists(profileName) {
            printErr("(extending existing profile '\(profileName)')")
        }

        repeat {
            let pool = try await buildPool(scope: scope)
            config.pools.removeAll { $0.name == pool.name }
            config.pools.append(pool)
        } while Prompt.confirm("Add another pool?", default: false)

        config.secrets = SecretsConfig(store: "keychain", scope: scope.rawValue)
        try Profiles.save(config, as: profileName)
        printErr("\n✓ wrote profile '\(profileName)'  →  \(Profiles.path(for: profileName))")

        if Prompt.confirm("Make '\(profileName)' the active profile?", default: makeActiveDefault) {
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
        return profileName
    }
}

/// The active profile, or throw a helpful error.
func resolveProfileName(_ explicit: String?) throws -> String {
    if let explicit { return explicit }
    if let active = Profiles.activeName() { return active }
    throw GraftError("no active profile — pass --profile NAME or run `graft profile use NAME`")
}
