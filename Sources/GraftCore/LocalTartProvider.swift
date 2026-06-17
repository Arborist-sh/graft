import Foundation

/// `VMProvider` backed by the local `tart` CLI. Phase 1 backend — the supervisor
/// talks to this exactly the way it will later talk to Orchard.
public struct LocalTartProvider: VMProvider {
    /// Prefix for every VM graft creates, so `graft leaf list` and teardown can tell
    /// graft-managed VMs apart from anything else on the host.
    public static let namePrefix = "graft-"

    /// Nests (dev boxes) share the `graft-` prefix but are NOT pool runners — they're
    /// long-lived dev environments. The supervisor must never see them as leaves/orphans,
    /// so the managed-VM enumeration excludes them.
    public static let devPrefix = "graft-dev-"

    public init() {}

    /// Ceiling of VMs of this OS the host can run. macOS is Apple's kernel-enforced
    /// hard limit of 2; Linux is bounded by cores (heuristic, ~half). The supervisor
    /// tracks its own consumption against this ceiling — the provider just reports the
    /// static limit (it never changes on a single host).
    public func capacity(for os: GuestOS) async -> Int {
        Self.hostCapacity(for: os)
    }

    /// Synchronous host-capacity ceiling — Apple's hard 2-macOS-VM limit; Linux
    /// bounded by cores. Exposed so the UI can plan a target count without an async
    /// provider call.
    public static func hostCapacity(for os: GuestOS) -> Int {
        switch os {
        case .macOS:
            return 2
        case .linux:
            return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        }
    }

    public func acquire(name: String, image: String, os: GuestOS, mounts: [Mount], network: VMNetwork, resources: VMResources, startupScript: String?, onProgress: (@Sendable (AcquireProgress) -> Void)?) async throws -> RunningVM {
        try await Tart.clone(image: image, to: name)
        do {
            // Per-pool sizing: resize the clone before boot (overrides the image's bake).
            if !resources.isEmpty {
                var setArgs = ["set"]
                if let cpu = resources.cpu { setArgs += ["--cpu", String(cpu)] }
                if let memory = resources.memory { setArgs += ["--memory", String(memory)] }
                setArgs.append(name)
                _ = try await Shell.run(Tart.executable, setArgs)
            }
            onProgress?(.booting)   // local Tart: clone done, the guest is now coming up
            try Tart.run(name: name, mounts: mounts, network: network)
            let ip: String
            do {
                ip = try await Tart.waitForIP(name: name)
            } catch {
                // The detached `tart run` never brought the VM up. Its output went to the
                // boot log, not our stderr — read it back so the real cause (not just an IP
                // timeout) reaches the supervisor instead of being swallowed.
                let log = BootLog.tail(for: name)
                guard !log.isEmpty else { throw error }
                let indented = log.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "    \($0)" }.joined(separator: "\n")
                throw GraftError("\(error)\n  `tart run \(name)` output:\n\(indented)")
            }
            let vm = RunningVM(name: name, ip: ip, os: os)
            // Same host as the guest, so we launch the runner ourselves — detached, so it
            // survives this exec closing — then monitor via GitHub like the fleet path.
            if let startupScript {
                try await waitForGuest(vm)
                let b64 = Data(startupScript.utf8).base64EncodedString()
                // The script self-detaches the runner (nohup … & disown), so just run it —
                // it returns once the runner is backgrounded, leaving it alive in the guest.
                let launch = "echo \(b64) | base64 -d > /tmp/graft-startup.sh && bash /tmp/graft-startup.sh"
                _ = try await exec(on: vm, ["bash", "-lc", launch], timeout: .seconds(120))
            }
            return vm
        } catch {
            // Boot or IP wait failed — don't leak the clone.
            try? await Tart.stop(name: name)
            try? await Tart.delete(name: name)
            throw error
        }
    }

    public func release(_ vm: RunningVM) async throws {
        // Drop the boot log once the leaf is gone, so they don't pile up one-per-runner.
        defer { BootLog.remove(for: vm.name) }
        // Best-effort stop (a crashed VM may already be down), then delete.
        try? await Tart.stop(name: vm.name)
        guard try await Tart.exists(name: vm.name) else { return }
        try await Tart.delete(name: vm.name)
    }

    public func exec(on vm: RunningVM, _ command: [String], timeout: Duration? = nil) async throws -> ShellResult {
        try await Shell.run(Tart.executable, ["exec", vm.name] + command, timeout: timeout)
    }

    public func execStreaming(on vm: RunningVM, script: String, onLine: (@Sendable (String) -> Void)?) async throws -> Int32 {
        // `tart exec -i <name> bash -s` runs the script on stdin inside the guest;
        // stdout/stderr stream back, exit code propagates.
        try await Shell.runStreaming(
            Tart.executable,
            ["exec", "-i", vm.name, "bash", "-s"],
            stdin: script,
            onLine: onLine
        )
    }

    /// VMs graft created on this host as pool runners (by name prefix), excluding nests
    /// (dev boxes). Backs `graft leaf list` and the orphan sweep.
    public func graftManagedVMs() async throws -> [TartVM] {
        try await Tart.list().filter { $0.name.hasPrefix(Self.namePrefix) && !$0.name.hasPrefix(Self.devPrefix) }
    }

    public func managedVMNames() async -> [String] {
        ((try? await graftManagedVMs()) ?? []).map(\.name)
    }

    /// Stop + delete any graft-managed VM still on this host (by name prefix).
    public func sweepOrphans() async {
        for vm in (try? await graftManagedVMs()) ?? [] {
            Log.info("sweeping \(vm.name)")
            try? await Tart.stop(name: vm.name)
            try? await Tart.delete(name: vm.name)
        }
    }
}
