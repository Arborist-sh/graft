import Foundation

/// `SecretStore` that reads a GitHub App private key from a plain PEM file on disk —
/// `<directory>/<app-id>.pem` — instead of the macOS keychain.
///
/// This is the escape hatch for **headless hosts** (EC2 Mac over SSH, CI boxes): the
/// keychain is hostile without a GUI session (locks, no way to unlock non-interactively,
/// root/session mismatches), whereas a `chmod 600` file just works — no lock state, no
/// GUI, no sudo. Read-only: you drop the App's `.pem` in place yourself (there's no
/// `graft secrets import` for the file store), so it pairs with file-managed secrets /
/// config management.
///
/// Selected by `"secrets": { "store": "file", "path": "<dir>" }` in config; `path`
/// defaults to `~/.graft/keys`.
public struct FileSecretStore: SecretStore {
    public let directory: String

    /// Where `<app-id>.pem` files live by default.
    public static let defaultDirectory = "~/.graft/keys"

    public init(directory: String = FileSecretStore.defaultDirectory) {
        self.directory = directory
    }

    public func privateKeyPEM(forAppID appID: Int) async throws -> String {
        let dir = (directory as NSString).expandingTildeInPath
        let path = (dir as NSString).appendingPathComponent("\(appID).pem")
        guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw GraftError(
                "no key file for app \(appID) at \(path) — drop the App's private-key .pem there "
                + "(and `chmod 600` it)")
        }
        // A private key that's group/other-readable is a problem — warn, don't fail.
        if let perms = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions])
            as? NSNumber, perms.uint16Value & 0o077 != 0 {
            Log.warn("\(path) is group/other-readable (mode \(String(perms.uint16Value, radix: 8))) — `chmod 600` it")
        }
        return pem
    }
}
