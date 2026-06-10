import Foundation
import Testing
@testable import GraftCore

// MARK: - Mocks

private actor Recorder {
    var acquired: [String] = []
    var released: [String] = []
    func acquire(_ name: String) { acquired.append(name) }
    func release(_ name: String) { released.append(name) }
}

private struct MockProvider: VMProvider {
    let recorder: Recorder
    let macCapacity: Int

    func capacity(for os: GuestOS) async -> Int { os == .macOS ? macCapacity : 4 }

    func acquire(image: String, os: GuestOS) async throws -> RunningVM {
        let name = "graft-mock-" + UUID().uuidString.prefix(8).lowercased()
        await recorder.acquire(name)
        return RunningVM(name: name, ip: "10.0.0.2", os: os)
    }

    func release(_ vm: RunningVM) async throws { await recorder.release(vm.name) }
    func exec(on vm: RunningVM, _ command: [String]) async throws -> ShellResult {
        ShellResult(exitCode: 0, stdout: "", stderr: "")
    }
    func execStreaming(on vm: RunningVM, script: String) async throws -> Int32 { 0 }
}

private struct MockJIT: JITConfigProvider {
    func generateJITConfig(pool: PoolConfig, runnerName: String) async throws -> String {
        "jit-\(runnerName)"
    }
}

/// Holds the VM (one job in flight) until the slot is cancelled, so each slot
/// acquires exactly one VM — making counts deterministic.
private struct BlockingRunner: RunnerRunner {
    func runEphemeralRunner(on vm: RunningVM, jitConfig: String) async throws -> Int32 {
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
        return 0
    }
}

// MARK: - Tests

@Suite("PoolSupervisor")
struct PoolSupervisorTests {
    private func tempStateDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("graft-test-" + UUID().uuidString)
    }

    @Test("budgets macOS capacity across pools and fills every slot")
    func capacityBudgetingAndFill() async throws {
        let recorder = Recorder()
        let provider = MockProvider(recorder: recorder, macCapacity: 2)
        let stateDir = tempStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }

        // 2 macOS pools each want 2 (host cap 2 → second clamps to 0) + linux wants 3.
        // Expected slots: 2 + 0 + 3 = 5.
        let cfg = GraftConfig(pools: [
            PoolConfig(name: "mac-a", image: "i", os: .macOS, count: 2,
                       github: GitHubConfig(appId: 1, target: "org:acme")),
            PoolConfig(name: "mac-b", image: "i", os: .macOS, count: 2,
                       github: GitHubConfig(appId: 1, target: "org:acme")),
            PoolConfig(name: "linux", image: "i", os: .linux, count: 3,
                       github: GitHubConfig(appId: 1, target: "org:acme")),
        ])

        let supervisor = PoolSupervisor(
            config: cfg,
            provider: provider,
            github: { _ in MockJIT() },
            runner: BlockingRunner(),
            state: StateManager(directory: stateDir)
        )

        let task = Task { await supervisor.run() }

        // Wait for all 5 slots to acquire (each then blocks).
        for _ in 0..<300 {
            if await recorder.acquired.count >= 5 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recorder.acquired.count == 5)

        // Graceful shutdown releases every VM.
        task.cancel()
        await task.value
        #expect(await recorder.released.count == 5)

        // State is cleaned up.
        let persisted = StateManager(directory: stateDir).load()
        #expect(persisted?.runners.isEmpty ?? true)
    }
}
