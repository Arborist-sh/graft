import Foundation
import Security

/// Reads a GitHub App private key (PEM) at runtime. The read path is all
/// `GitHubAppClient` needs; concrete stores add their own write/list APIs.
/// Mirrors `VMProvider`'s swap philosophy — Keychain now, Vault/1Password later.
public protocol SecretStore: Sendable {
    func privateKeyPEM(forAppID appID: Int) async throws -> String
}

/// Which macOS keychain backs the store.
public enum KeychainScope: String, Sendable, CaseIterable {
    /// The user's login keychain — unlocked by the GUI session. For interactive
    /// `graft run`.
    case login
    /// The system keychain (`/Library/Keychains/System.keychain`) — root-accessible
    /// and unlocked at boot, so a headless `graft run --daemon` can reach it with no
    /// login session. Writing requires sudo.
    case system
}

/// `SecretStore` backed by the macOS Keychain. The PEM is stored as a generic-
/// password item keyed by `service="graft-github-app", account=<appID>`, so it's
/// resolved purely from the App ID already in config — no key path on disk.
public struct KeychainSecretStore: SecretStore {
    public static let service = "graft-github-app"

    public let scope: KeychainScope

    public init(scope: KeychainScope = .login) {
        self.scope = scope
    }

    // MARK: Read (SecretStore)

    public func privateKeyPEM(forAppID appID: Int) async throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: String(appID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        applySearchScope(to: &query)

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let pem = String(data: data, encoding: .utf8) else {
                throw GraftError("keychain item for app \(appID) is not valid UTF-8")
            }
            return pem
        case errSecItemNotFound:
            throw GraftError(
                "no private key in \(scope.rawValue) keychain for app \(appID) — "
                + "run `graft secrets import --app-id \(appID) --pem <path>`"
            )
        default:
            throw keychainError("read", status)
        }
    }

    // MARK: Write / manage (used by `graft secrets`)

    /// Upsert the PEM for an App. Deletes any existing item first so re-importing
    /// is idempotent. An optional `name` (the GitHub App's display name) is stashed in the
    /// item's comment attribute, so it can be read back without unlocking the key data.
    public func store(pem: String, forAppID appID: Int, name: String? = nil) throws {
        try remove(appID: appID)
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: String(appID),
            kSecAttrLabel as String: "Graft GitHub App \(appID) private key",
            kSecValueData as String: Data(pem.utf8),
        ]
        if let name, !name.isEmpty { attributes[kSecAttrComment as String] = name }
        applyWriteScope(to: &attributes)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw keychainError("write", status)
        }
    }

    /// Set/replace (or, with nil, clear) the stored display name for an App that already
    /// has a key — re-reads the PEM and rewrites the item. Used to backfill names from
    /// GitHub, and to clear a misleading name when a key turns out not to match its ID.
    public func setName(_ name: String?, forAppID appID: Int) async throws {
        let pem = try await privateKeyPEM(forAppID: appID)
        try store(pem: pem, forAppID: appID, name: name)
    }

    /// Remove the PEM for an App. No-op if absent.
    public func remove(appID: Int) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: String(appID),
        ]
        applySearchScope(to: &query)

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError("delete", status)
        }
    }

    /// An App with a key in the keychain, plus its display name if one was stored.
    public struct StoredApp: Sendable, Equatable {
        public let id: Int
        public let name: String?
        public init(id: Int, name: String?) { self.id = id; self.name = name }
    }

    /// App IDs that currently have a key in this keychain.
    public func storedAppIDs() throws -> [Int] {
        try storedApps().map(\.id)
    }

    /// Apps with a key in this keychain, each with its stored display name (if any).
    /// Attribute-only read — does not unlock the key data, so it never prompts.
    public func storedApps() throws -> [StoredApp] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        applySearchScope(to: &query)

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let array = items as? [[String: Any]] else {
            throw keychainError("list", status)
        }
        return array.compactMap { attrs -> StoredApp? in
            guard let id = (attrs[kSecAttrAccount as String] as? String).flatMap(Int.init) else { return nil }
            let name = attrs[kSecAttrComment as String] as? String
            return StoredApp(id: id, name: (name?.isEmpty ?? true) ? nil : name)
        }.sorted { $0.id < $1.id }
    }

    // MARK: Orchard service-account token (GFT-11)

    // Stored just like the App PEM — a generic-password item, but under its own service
    // so the two never collide — keyed by the Orchard service-account name. Keeps the
    // controller token out of plaintext profile config.
    public static let orchardTokenService = "graft-orchard-token"

    /// Read the Orchard token for a service account, or nil if none is stored. Non-
    /// throwing so `graft run`'s provider resolution can fall back cleanly.
    public func orchardToken(account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.orchardTokenService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        applySearchScope(to: &query)
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether an Orchard token is stored for this account — an attribute-only existence
    /// check, so it never prompts (unlike `orchardToken`, which reads the secret data).
    public func hasOrchardToken(account: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.orchardTokenService,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        applySearchScope(to: &query)
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    /// Upsert the Orchard token for a service account (idempotent: delete then add).
    public func storeOrchardToken(_ token: String, account: String) throws {
        try removeOrchardToken(account: account)
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.orchardTokenService,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Graft Orchard token for '\(account)'",
            kSecValueData as String: Data(token.utf8),
        ]
        applyWriteScope(to: &attributes)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError("write", status) }
    }

    /// Remove the Orchard token for a service account. No-op if absent.
    public func removeOrchardToken(account: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.orchardTokenService,
            kSecAttrAccount as String: account,
        ]
        applySearchScope(to: &query)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError("delete", status)
        }
    }

    // MARK: Scope plumbing

    // The data-protection keychain can't target file-based login/system keychains,
    // so we use the legacy SecKeychain APIs (deprecated since 10.10 but the only way
    // to address a specific keychain file on macOS). Login uses the default list.

    private func applySearchScope(to query: inout [String: Any]) {
        if let keychain = systemKeychainIfNeeded() {
            query[kSecMatchSearchList as String] = [keychain]
        }
    }

    private func applyWriteScope(to attributes: inout [String: Any]) {
        if let keychain = systemKeychainIfNeeded() {
            attributes[kSecUseKeychain as String] = keychain
        }
    }

    private func systemKeychainIfNeeded() -> SecKeychain? {
        guard scope == .system else { return nil }
        var keychain: SecKeychain?
        // Deprecated API, intentional: the only way to address the system keychain file.
        let status = SecKeychainOpen("/Library/Keychains/System.keychain", &keychain)
        return status == errSecSuccess ? keychain : nil
    }

    private func keychainError(_ action: String, _ status: OSStatus) -> GraftError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        var message = "keychain \(action) failed: \(detail)"
        if status == errSecAuthFailed && scope == .system {
            message += " (writing the system keychain needs sudo)"
        }
        return GraftError(message)
    }
}
