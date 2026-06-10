import Foundation

/// The guest operating system a VM runs. Declared in pool config, never probed —
/// `tart clone` doesn't tell you what's inside an image, and the OS decides the
/// capacity tier (Apple's 2-macOS-VM/host limit vs. uncapped Linux).
public enum GuestOS: String, Codable, Sendable, CaseIterable {
    case macOS = "macos"
    case linux

    /// Apple Silicon enforces a hard limit of 2 concurrent macOS VMs per host in
    /// the XNU kernel. Linux guests are uncapped (bounded only by RAM/cores).
    public var isAppleVMQuotaLimited: Bool { self == .macOS }
}

/// A booted VM with a reachable IP. The unit the supervisor and provisioner pass
/// around — deliberately backend-agnostic so Tart, Orchard, or Twig all yield the
/// same shape.
public struct RunningVM: Sendable, Codable, Equatable {
    public let name: String
    public let ip: String
    public let os: GuestOS

    public init(name: String, ip: String, os: GuestOS) {
        self.name = name
        self.ip = ip
        self.os = os
    }
}
