import Foundation

/// Builds a Tart image from an `ImageRecipe` — the same move as `RunnerProvisioner`,
/// but the result is kept (stopped) instead of run once: clone the base → boot (with
/// the recipe's mounts) → run the provisioning steps in the guest → stop → promote to
/// the named image. Tart clones are APFS copy-on-write, so the snapshot is cheap and
/// later clones (runners, `graft dev`) share its blocks.
public struct ImageBuilder: Sendable {
    private let provider: LocalTartProvider

    /// Name prefix for the throwaway build VM. A finished build deletes its own temp;
    /// these only linger after an interrupted/failed build (and are swept on the next).
    public static let tempPrefix = "graft-imgbuild-"

    /// Whether `name` is one of our throwaway build VMs.
    public static func isOrphanTemp(_ name: String) -> Bool { name.hasPrefix(tempPrefix) }

    public init(provider: LocalTartProvider = LocalTartProvider()) {
        self.provider = provider
    }

    /// Remove leftover throwaway build VMs from prior failed/interrupted builds, so they
    /// can't accumulate or hold one of the host's two macOS VM slots. Best-effort; returns
    /// the names actually removed. `includeRunning` is true for the pre-build auto-sweep
    /// (a fresh build owns the host, and wedged temps are *running* but dead) and false for
    /// a manual `prune` (so it never surprise-kills an in-progress build).
    @discardableResult
    public func sweepOrphans(includeRunning: Bool = true) async -> [String] {
        let orphans = (try? await Tart.list())?.filter {
            Self.isOrphanTemp($0.name) && (includeRunning || !$0.isRunning)
        } ?? []
        for vm in orphans {
            Log.info("sweeping orphaned build VM \(vm.name) (leftover from a prior failed build)…")
            try? await Tart.stop(name: vm.name)
            try? await Tart.delete(name: vm.name)
        }
        return orphans.map(\.name)
    }

    /// Build `recipe` into a local image named `recipe.name`. `onLine` receives the
    /// guest's build output live. A failure leaves any pre-existing image of that name
    /// untouched (the build happens on a throwaway clone first).
    /// `scriptBody`, if given (the contents of the recipe's `script:` file), runs before
    /// the inline `run` steps in the same guest shell.
    /// `repoToken`, if given, mints a short-lived GitHub App installation token for a `repos:`
    /// URL so a private repo's cache-warming clone authenticates as graft's App — no deploy key.
    /// Returns nil per-repo to fall back to an anonymous clone (public repos, or no App access).
    public func build(
        _ recipe: ImageRecipe, scriptBody: String? = nil,
        repoToken: (@Sendable (String) async -> String?)? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws {
        await sweepOrphans()                          // clear leftovers from prior failed builds
        try await Tart.ensureAvailable(recipe.from)  // pull the base if it isn't cached
        let temp = Self.tempPrefix + UUID().uuidString.prefix(8).lowercased()
        Log.info("cloning base \(recipe.from) → \(temp)…")
        try await Tart.clone(image: recipe.from, to: temp)
        do {
            Log.info("booting build VM…")
            try Tart.run(name: temp, mounts: recipe.mounts ?? [], network: recipe.network ?? .nat)
            let vm = RunningVM(name: temp, ip: "", os: recipe.guestOS)
            Log.info("waiting for the guest to finish booting (first boot can take ~60–90s)…")
            try await provider.waitForGuest(vm, timeout: .seconds(180))
            Log.info("guest is up — running provisioning steps:")

            // Mint App tokens for private repo precaches (skip ones with an explicit ssh-key).
            // A nil result means anonymous clone — fine for public repos.
            var repoTokens: [String: String] = [:]
            if let repoToken, let repos = recipe.repos {
                for r in repos where r.sshKey == nil {
                    if let token = await repoToken(r.url) { repoTokens[r.url] = token }
                }
            }

            if let provisioning = recipe.provisioning(scriptBody: scriptBody, repoTokens: repoTokens) {
                let exit = try await provider.execStreaming(
                    on: vm, script: provisioning, onLine: onLine)
                guard exit == 0 else { throw GraftError("image build step failed (exit \(exit))") }
            }

            Log.info("provisioning done — stopping & promoting image '\(recipe.name)'…")
            try await Tart.stop(name: temp)

            // Promote: replace any existing image of this name with the freshly-built
            // one (CoW clone, ~instant), then drop the throwaway.
            if try await Tart.exists(name: recipe.name) {
                try await Tart.delete(name: recipe.name)
            }
            try await Tart.clone(image: temp, to: recipe.name)
            try await Tart.delete(name: temp)

            // Apply VM-shape settings (cpu/memory/disk/display) to the finished image so
            // every clone — runners and `graft dev` — inherits them.
            if let vm = recipe.vmSettings {
                Log.info("applying VM settings (cpu/memory/disk/display)…")
                try await Tart.set(
                    name: recipe.name,
                    cpu: vm.cpu, memory: vm.memory, diskSize: vm.diskSize, display: vm.display)
            }
        } catch {
            try? await Tart.stop(name: temp)
            try? await Tart.delete(name: temp)
            throw error
        }
    }

}
