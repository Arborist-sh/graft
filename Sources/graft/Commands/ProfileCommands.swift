import ArgumentParser
import GraftCore

/// `graft profile …` — manage named config profiles and switch between them.
struct Profile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Manage config profiles (switch between e.g. personal and work).",
        subcommands: [Create.self, List.self, Use.self, Show.self, Remove.self, Path.self]
    )
}

extension Profile {
    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Interactively create a profile (name, pools, keys).",
            aliases: ["new"]
        )

        @Flag(help: "Store/read keys in the system keychain (headless hosts).")
        var system = false

        func run() async throws {
            let scope: KeychainScope = system ? .system : .login
            try await Wizard.createProfile(scope: scope)
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List profiles (active marked with *).")

        func run() throws {
            let names = Profiles.names()
            guard !names.isEmpty else {
                printErr("no profiles — create one with `graft init`")
                return
            }
            let active = Profiles.activeName()
            for name in names {
                print("\(name == active ? "* " : "  ")\(name)")
            }
        }
    }

    struct Use: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set the active profile.")

        @Argument(help: "Profile name.")
        var name: String

        func run() throws {
            try Profiles.setActive(name)
            printErr("✓ active profile is now '\(name)'")
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a profile's config (default: active).")

        @Argument(help: "Profile name (default: active).")
        var name: String?

        func run() throws {
            let profileName = try resolveProfileName(name)
            print(try Profiles.load(profileName).jsonString())
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a profile.")

        @Argument(help: "Profile name.")
        var name: String

        func run() throws {
            try Profiles.remove(name)
            printErr("✓ removed profile '\(name)'")
        }
    }

    struct Path: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a profile's file path (default: active).")

        @Argument(help: "Profile name (default: active).")
        var name: String?

        func run() throws {
            print(Profiles.path(for: try resolveProfileName(name)))
        }
    }
}
