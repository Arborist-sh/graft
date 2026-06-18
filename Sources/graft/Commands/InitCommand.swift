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

    func run() async throws {
        try await Wizard.createProfile()
    }
}
