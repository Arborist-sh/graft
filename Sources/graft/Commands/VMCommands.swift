import ArgumentParser
import GraftCore

/// `graft vm …` — low-level VM plumbing. The supervisor uses `VMProvider`
/// directly; these commands are for humans poking at the layer underneath.
struct VM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vm",
        abstract: "Low-level VM plumbing (clone, boot, list, destroy).",
        subcommands: [Create.self, Delete.self, List.self, IP.self]
    )
}

extension VM {
    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Clone + boot a VM, wait for its IP, print `name<TAB>ip`."
        )

        @Argument(help: "Tart image, e.g. ghcr.io/cirruslabs/macos-sequoia-xcode:latest")
        var image: String

        @Option(help: "Guest OS (macos|linux) for capacity accounting.")
        var os: GuestOS = .macOS

        func run() async throws {
            let provider = LocalTartProvider()
            printErr("cloning \(image) and booting…")
            let vm = try await provider.acquire(image: image, os: os)
            print("\(vm.name)\t\(vm.ip)")
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop and destroy a VM.")

        @Argument(help: "VM name (graft-…).")
        var name: String

        func run() async throws {
            try? await Tart.stop(name: name)
            guard try await Tart.exists(name: name) else {
                printErr("no such VM: \(name)")
                throw ExitCode.failure
            }
            try await Tart.delete(name: name)
            printErr("deleted \(name)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List graft-managed VMs.")

        @Flag(help: "Show all Tart VMs, not just graft-managed ones.")
        var all = false

        func run() async throws {
            let vms = all ? try await Tart.list() : try await LocalTartProvider().graftManagedVMs()
            guard !vms.isEmpty else {
                printErr(all ? "no VMs" : "no graft-managed VMs")
                return
            }
            for vm in vms {
                print("\(vm.name)\t\(vm.state)")
            }
        }
    }

    struct IP: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a VM's IP.")

        @Argument(help: "VM name.")
        var name: String

        @Flag(help: "Wait (poll) for an IP if one isn't assigned yet.")
        var wait = false

        func run() async throws {
            if wait {
                print(try await Tart.waitForIP(name: name))
            } else if let ip = try await Tart.ip(name: name) {
                print(ip)
            } else {
                throw GraftError("\(name) has no IP yet (try --wait)")
            }
        }
    }
}
