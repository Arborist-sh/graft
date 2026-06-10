import Foundation

/// The central abstraction. The pool supervisor never calls `tart` directly — it
/// always goes through a provider. This is what makes Orchard (multi-host) or a
/// future native backend (Twig) a drop-in swap rather than a rewrite.
public protocol VMProvider: Sendable {
    /// How many more VMs of this OS this provider can currently hand out.
    /// For local Tart + macOS this is Apple's hard 2-VM ceiling minus what's running.
    func capacity(for os: GuestOS) async -> Int

    /// Clone + boot a VM from `image`, wait for it to get an IP, and return it.
    /// `os` is declared by the caller (from pool config) — providers don't probe.
    func acquire(image: String, os: GuestOS) async throws -> RunningVM

    /// Stop and destroy a VM. Idempotent where possible — releasing an
    /// already-gone VM should not throw.
    func release(_ vm: RunningVM) async throws
}
