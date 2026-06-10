import Foundation

/// A human-facing error with a ready-to-print message. Used across Graft for
/// failures that aren't a subprocess (`ShellError`) — timeouts, bad config,
/// missing secrets, unreachable hosts.
public struct GraftError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}
