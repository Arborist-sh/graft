import Foundation
import Testing
@testable import GraftCore

@Suite("Tart.ensureInstalled")
struct TartTests {
    @Test("throws a clear, actionable error when tart isn't on PATH")
    func throwsWhenMissing() async throws {
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graft-tart-preflight-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        await #expect(throws: TartError.self) {
            try await Tart.ensureInstalled(path: emptyDir.path)
        }

        do {
            try await Tart.ensureInstalled(path: emptyDir.path)
            Issue.record("expected ensureInstalled to throw")
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            #expect(description.contains("brew install cirruslabs/cli/tart"))
        }
    }

    @Test("passes when a `tart` executable is on PATH")
    func passesWhenPresent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graft-tart-preflight-present-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stub = dir.appendingPathComponent("tart")
        try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        try await Tart.ensureInstalled(path: dir.path)
    }
}
