import Foundation
import Testing
@testable import GraftCore

// MARK: - Mocks

private actor Recorder {
    var acquired: [String] = []
    var released: [String] = []
    private var inFlight: [String: Int] = [:]
    /// Peak number of overlapping `release` calls for any single VM. Two concurrent
    /// releases of the same VM are what wedge `tart` on its per-VM lock during
    /// shutdown — so this must stay 1.
    private(set) var maxConcurrentReleasePerName = 0

    func acquire(_ name: String) { acquired.append(name) }

    func releaseBegin(_ name: String) {
        let n = (inFlight[name] ?? 0) + 1
        inFlight[name] = n
        maxConcurrentReleasePerName = max(maxConcurrentReleasePerName, n)
    }
    func releaseEnd(_ name: String) {
        inFlight[name] = (inFlight[name] ?? 1) - 1
        released.append(name)
    }

    private(set) var deregisteredRunnerIDs: [Int] = []
    func deregister(_ id: Int) { deregisteredRunnerIDs.append(id) }

    private(set) var minted: [String] = []
    func mint(_ name: String) { minted.append(name) }
}

private struct MockProvider: VMProvider {
    let recorder: Recorder
    let macCapacity: Int

    func capacity(for os: GuestOS) async -> Int { os == .macOS ? macCapacity : 4 }

    func acquire(name: String, image: String, os: GuestOS, mounts: [Mount], network: VMNetwork, resources: VMResources, startupScript: String?, onProgress: (@Sendable (AcquireProgress) -> Void)?) async throws -> RunningVM {
        await recorder.acquire(name)
        return RunningVM(name: name, ip: "10.0.0.2", os: os)
    }

    func release(_ vm: RunningVM) async throws {
        await recorder.releaseBegin(vm.name)
        // Widen the teardown window so a duplicate release would actually overlap
        // (and be caught) rather than slipping through as two fast sequential calls.
        try? await Task.sleep(for: .milliseconds(30))
        await recorder.releaseEnd(vm.name)
    }
    func exec(on vm: RunningVM, _ command: [String], timeout: Duration?) async throws -> ShellResult {
        ShellResult(exitCode: 0, stdout: "", stderr: "")
    }
    func execStreaming(on vm: RunningVM, script: String, onLine: (@Sendable (String) -> Void)?) async throws -> Int32 { 0 }
}

/// A capacity ceiling a test can change at runtime, to simulate a fleet whose branches
/// join or leave while the supervisor runs.
private actor CapacityBox {
    private var value: Int
    init(_ v: Int) { value = v }
    func get() -> Int { value }
    func set(_ v: Int) { value = v }
}

/// Like `MockProvider`, but its macOS ceiling is read live from a `CapacityBox` — so a
/// test can start at 0 (empty fleet) and bump it later (a branch joins).
private struct ElasticMockProvider: VMProvider {
    let recorder: Recorder
    let macCap: CapacityBox

    func capacity(for os: GuestOS) async -> Int { os == .macOS ? await macCap.get() : 0 }

    func acquire(name: String, image: String, os: GuestOS, mounts: [Mount], network: VMNetwork, resources: VMResources, startupScript: String?, onProgress: (@Sendable (AcquireProgress) -> Void)?) async throws -> RunningVM {
        await recorder.acquire(name)
        return RunningVM(name: name, ip: "10.0.0.2", os: os)
    }
    func release(_ vm: RunningVM) async throws {
        await recorder.releaseBegin(vm.name)
        await recorder.releaseEnd(vm.name)
    }
    func exec(on vm: RunningVM, _ command: [String], timeout: Duration?) async throws -> ShellResult {
        ShellResult(exitCode: 0, stdout: "", stderr: "")
    }
    func execStreaming(on vm: RunningVM, script: String, onLine: (@Sendable (String) -> Void)?) async throws -> Int32 { 0 }
}

private struct MockJIT: JITConfigProvider {
    let recorder: Recorder
    func generateJITRunner(github: GitHubConfig, labels: [String], runnerName: String) async throws -> GitHubAppClient.JITRunner {
        await recorder.mint(runnerName)
        // Stable per-name id so the deregister assertion is deterministic.
        return GitHubAppClient.JITRunner(runnerID: abs(runnerName.hashValue % 1_000_000), encodedConfig: "jit-\(runnerName)")
    }
    func deleteRunner(id: Int, target: GitHubTarget) async throws {
        // Simulate a cancellation-aware network call (URLSession throws when its task
        // is cancelled). On graceful shutdown the slot's task is cancelled, so this
        // only records if the supervisor shields the cleanup in a detached task.
        try Task.checkCancellation()
        await recorder.deregister(id)
    }
    /// Every minted runner reads as online — so each slot sees its runner come up and then
    /// holds (polling) until shutdown, mirroring the old BlockingRunner.
    func listRunners(target: GitHubTarget) async throws -> [GitHubAppClient.Runner] {
        (await recorder.minted).map { GitHubAppClient.Runner(id: 0, name: $0, status: "online", busy: false) }
    }
    func currentRunningJob(runnerName: String, target: GitHubTarget) async -> String? { nil }
}

// MARK: - Tests

@Suite("PoolSupervisor")
struct PoolSupervisorTests {
    private func tempStateDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("graft-test-" + UUID().uuidString)
    }

    @Test("throttles to the capacity ceiling and parks the rest, but spawns every desired slot")
    func capacityBudgetingAndFill() async throws {
        let recorder = Recorder()
        let provider = MockProvider(recorder: recorder, macCapacity: 2)
        let stateDir = tempStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }

        // 2 macOS pools each want 2 + linux wants 3 → 7 desired slots all spawn. The macOS
        // ceiling is 2 (shared across both macOS pools), so 2 of the 4 macOS slots acquire
        // and 2 park in `waitingForCapacity`; linux (ceiling 4) fills all 3. So: 7 slots
        // exist, exactly 5 hold a leaf. (Old behavior clamped the *spawn count* to 5 and
        // mac-b vanished; now capacity is a throttle, not a cap on how many slots exist.)
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
            github: { _ in MockJIT(recorder: recorder) },
            state: StateManager(directory: stateDir)
        )

        let task = Task { await supervisor.run() }

        // Wait for the 5 acquirable slots to acquire and all 7 slots to report a phase.
        for _ in 0..<300 {
            if await recorder.acquired.count >= 5,
               (StateManager(directory: stateDir).load()?.slots.count ?? 0) >= 7 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recorder.acquired.count == 5)

        // Per-slot phase is persisted to the state file (what the menu bar reads), even
        // with no live dashboard: all 7 desired slots are present — 5 with a leaf, 2 parked
        // waiting for capacity.
        let live = StateManager(directory: stateDir).load()
        #expect(live?.slots.count == 7)
        #expect(live?.slots.allSatisfy { !$0.phaseLabel.isEmpty } == true)
        #expect(live?.slots.filter { $0.phaseKind == "waiting" }.count == 2)

        // Graceful shutdown releases every VM. The slot's own teardown and the
        // shutdown watcher both target it, so assert coverage (every VM released)…
        task.cancel()
        await task.value
        let acquired = await recorder.acquired
        let released = await recorder.released
        #expect(Set(released) == Set(acquired))

        // …and that the two teardown paths never released the same VM concurrently
        // (that collision is what hangs `tart` on its per-VM lock). Regression guard
        // for the `releaseOnce` de-dupe.
        #expect(await recorder.maxConcurrentReleasePerName == 1)

        // Every runner that ran is deregistered from GitHub on teardown, so no
        // offline husk is left behind.
        #expect(await recorder.deregisteredRunnerIDs.count == acquired.count)

        // State is cleaned up.
        let persisted = StateManager(directory: stateDir).load()
        #expect(persisted?.runners.isEmpty ?? true)
    }

    @Test("parks with no capacity, then acquires when a branch joins (elastic)")
    func elasticPicksUpNewCapacity() async throws {
        let recorder = Recorder()
        let cap = CapacityBox(0)                 // fleet starts empty — no branches connected
        let provider = ElasticMockProvider(recorder: recorder, macCap: cap)
        let stateDir = tempStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }

        let cfg = GraftConfig(pools: [
            PoolConfig(name: "mac", image: "i", os: .macOS, count: 1,
                       github: GitHubConfig(appId: 1, target: "org:acme")),
        ])
        // Fast polling so the test doesn't wait the production 10–15s.
        let supervisor = PoolSupervisor(
            config: cfg, provider: provider,
            github: { _ in MockJIT(recorder: recorder) },
            state: StateManager(directory: stateDir),
            timing: .init(ceilingRefresh: .milliseconds(20), capacityPoll: .milliseconds(20)))
        let task = Task { await supervisor.run() }

        // With 0 capacity the slot is spawned but parks — nothing acquired. (Old behavior:
        // 0 slots spawned, so it could never recover without a restart.)
        for _ in 0..<200 {
            if StateManager(directory: stateDir).load()?.slots.first?.phaseKind == "waiting" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recorder.acquired.isEmpty)
        #expect(StateManager(directory: stateDir).load()?.slots.first?.phaseKind == "waiting")

        // A branch joins → the ceiling becomes 1. The parked slot picks it up with no restart.
        await cap.set(1)
        for _ in 0..<300 {
            if await recorder.acquired.count >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recorder.acquired.count == 1)

        task.cancel()
        await task.value
        let acquired = await recorder.acquired
        let released = await recorder.released
        #expect(Set(released) == Set(acquired))
    }

    @Test("re-adopts a still-online leaf from a prior run instead of re-acquiring")
    func reAdoptsLiveLeaf() async throws {
        let recorder = Recorder()
        let provider = MockProvider(recorder: recorder, macCapacity: 2)
        let stateDir = tempStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }

        // Seed state as if a prior run left one leaf for pool "mac", and mark its runner
        // minted so the mock GitHub reports it online (still live).
        let leaf = RunningVM(name: "graft-leftover-1", ip: "10.0.0.9", os: .macOS)
        let state = StateManager(directory: stateDir)
        try state.save(PoolState(runners: [RunnerRecord(vm: leaf, pool: "mac", startedAt: Date())],
                                 slots: [], updatedAt: Date()))
        await recorder.mint(leaf.name)

        let cfg = GraftConfig(pools: [
            PoolConfig(name: "mac", image: "i", os: .macOS, count: 1,
                       github: GitHubConfig(appId: 1, target: "org:acme")),
        ])
        let supervisor = PoolSupervisor(
            config: cfg, provider: provider,
            github: { _ in MockJIT(recorder: recorder) },
            state: state)
        let task = Task { await supervisor.run() }

        // The leftover leaf is re-adopted (tracked again), not re-acquired.
        for _ in 0..<300 {
            if (state.load()?.runners.contains { $0.vm.name == leaf.name }) == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect((state.load()?.runners.contains { $0.vm.name == leaf.name }) == true)
        #expect(await recorder.acquired.isEmpty)   // the slot adopted it — no fresh acquire

        // On shutdown the adopted leaf is torn down.
        task.cancel()
        await task.value
        #expect(await recorder.released.contains(leaf.name))
    }
}
