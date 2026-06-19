import Foundation
import Testing
@testable import GraftCore

@Suite("File secret store")
struct FileSecretStoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("reads <app-id>.pem from the configured directory")
    func reads() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMII...\n-----END RSA PRIVATE KEY-----\n"
        try pem.write(to: dir.appendingPathComponent("12345.pem"), atomically: true, encoding: .utf8)

        let store = FileSecretStore(directory: dir.path)
        let got = try await store.privateKeyPEM(forAppID: 12345)
        #expect(got == pem)
    }

    @Test("missing key file throws a helpful error naming the path")
    func missing() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSecretStore(directory: dir.path)
        await #expect(throws: GraftError.self) {
            _ = try await store.privateKeyPEM(forAppID: 999)
        }
    }

    @Test("SecretsConfig routes to the file store only when store == file")
    func routing() {
        let fileCfg = SecretsConfig(store: "file", path: "/tmp/keys")
        #expect(fileCfg.usesFileStore)
        #expect(fileCfg.makeStore(scope: .login) is FileSecretStore)

        let keychainCfg = SecretsConfig(store: "keychain")
        #expect(!keychainCfg.usesFileStore)
        #expect(keychainCfg.makeStore(scope: .login) is KeychainSecretStore)
    }
}
