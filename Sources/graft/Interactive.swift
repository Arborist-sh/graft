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

/// The active profile, or throw a helpful error.
func resolveProfileName(_ explicit: String?) throws -> String {
    if let explicit { return explicit }
    if let active = Profiles.activeName() { return active }
    throw GraftError("no active profile — pass --profile NAME or run `graft profile use NAME`")
}
