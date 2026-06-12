import Foundation
import Testing
@testable import GraftCore

@Suite("Orchard provider")
struct OrchardProviderTests {
    static func provider(maxVMs: Int? = nil) -> OrchardProvider {
        OrchardProvider(config: OrchardConfig(
            controllerURL: URL(string: "https://orchard.example.com:6120")!,
            serviceAccount: "graft",
            token: "secret-token",
            maxVMs: maxVMs
        ))
    }

    // MARK: create args

    @Test("create args: macOS maps to --os darwin, name last, no restart-policy (Orchard defaults to Never)")
    func createArgsMacOS() {
        let args = OrchardProvider.createArgs(
            name: "graft-abc", image: "ghcr.io/org/img:latest", os: .macOS, mounts: [], network: .nat
        )
        #expect(args == [
            "create", "vm",
            "--image", "ghcr.io/org/img:latest",
            "--os", "darwin",
            "graft-abc",
        ])
        #expect(!args.contains("--restart-policy"))   // omitted on purpose — Orchard defaults to Never
    }

    @Test("create args: linux maps to --os linux")
    func createArgsLinux() {
        let args = OrchardProvider.createArgs(name: "graft-x", image: "i", os: .linux, mounts: [], network: .nat)
        let i = args.firstIndex(of: "--os")!
        #expect(args[i + 1] == "linux")
        #expect(args.last == "graft-x")        // name is always the trailing positional
    }

    @Test("create args: mounts become --host-dirs in tart --dir syntax")
    func createArgsMounts() {
        let m = Mount(name: "cache", source: "/Volumes/cache", readOnly: true)
        let args = OrchardProvider.createArgs(name: "graft-x", image: "i", os: .macOS, mounts: [m], network: .nat)
        let i = args.firstIndex(of: "--host-dirs")!
        #expect(args[i + 1] == m.tartDirArg)
    }

    @Test("create args: network flags map to orchard's --net-* (and nat adds none)")
    func createArgsNetwork() {
        let nat = OrchardProvider.createArgs(name: "n", image: "i", os: .macOS, mounts: [], network: .nat)
        #expect(!nat.contains { $0.hasPrefix("--net") })

        let bridged = OrchardProvider.createArgs(name: "n", image: "i", os: .macOS, mounts: [], network: .bridged("en0"))
        let b = bridged.firstIndex(of: "--net-bridged")!
        #expect(bridged[b + 1] == "en0")

        let softnet = OrchardProvider.createArgs(name: "n", image: "i", os: .macOS, mounts: [], network: .softnet)
        #expect(softnet.contains("--net-softnet"))
    }

    @Test("VM names carry the graft- prefix so the orphan sweep can find them")
    func namePrefix() {
        #expect(OrchardProvider.namePrefix == "graft-")
    }

    @Test("graftVMNames parses graft's own VMs out of the `orchard list vms` table")
    func graftVMNamesParsing() {
        let listing = """
        Name                                       Created        Image                                       Status  Restart policy     Assigned worker
        graft-c8e22de4-8edb-45a8-9253-4c4d448b3c74 12 seconds ago ghcr.io/cirruslabs/macos-tahoe-xcode:latest running Never (0 restarts) slate.local
        some-other-vm                              1 hour ago     ubuntu:latest                               running Never (0 restarts) slate.local
        """
        #expect(OrchardProvider.graftVMNames(in: listing) == ["graft-c8e22de4-8edb-45a8-9253-4c4d448b3c74"])
        #expect(OrchardProvider.graftVMNames(in: "Name Created Image Status\n").isEmpty)   // header only
        #expect(OrchardProvider.graftVMNames(in: "").isEmpty)
    }

    @Test("ssh args never pass --wait 0 (Orchard treats --wait as the port-forward deadline)")
    func sshArgsNoWaitZero() {
        let args = OrchardProvider.sshArgs(vmName: "graft-x", remoteCommand: "true")
        #expect(args == ["ssh", "vm", "graft-x", "true"])
        #expect(!args.contains("--wait"))   // 0 would starve the rendezvous → instant deadline-exceeded
    }

    // MARK: env injection

    @Test("auth + endpoint are injected into the orchard environment")
    func envInjection() {
        let env = Self.provider().env
        #expect(env[OrchardEnv.url] == "https://orchard.example.com:6120")
        #expect(env[OrchardEnv.accountName] == "graft")
        #expect(env[OrchardEnv.accountToken] == "secret-token")
    }

    // MARK: capacity — live free slots (GFT-12)

    /// A provider pointed at a closed localhost port — `orchard` fails instantly
    /// (connection refused), so `capacity` exercises its unreachable-controller fallback
    /// without a 15s network timeout.
    static func unreachableProvider(maxVMs: Int? = nil) -> OrchardProvider {
        OrchardProvider(config: OrchardConfig(
            controllerURL: URL(string: "http://127.0.0.1:1")!,
            serviceAccount: "graft", token: "t", maxVMs: maxVMs
        ))
    }

    @Test("capacity falls back to the configured ceiling when the controller is unreachable")
    func capacityFallback() async {
        #expect(await Self.unreachableProvider(maxVMs: 7).capacity(for: .macOS) == 7)
        #expect(await Self.unreachableProvider().capacity(for: .macOS) == 100)   // default ceiling
    }

    @Test("schedulableWorkers: names of unpaused workers, header + paused skipped")
    func schedulableWorkers() {
        let listing = """
        Name        \tLast seen     \tScheduling paused
        slate.local \t14 seconds ago\tfalse
        granite.local\t2 minutes ago \ttrue
        basalt.local\t5 seconds ago \tfalse
        """
        #expect(OrchardProvider.schedulableWorkers(in: listing) == ["slate.local", "basalt.local"])
        #expect(OrchardProvider.schedulableWorkers(in: "Name\tLast seen\tScheduling paused\n").isEmpty)
        #expect(OrchardProvider.schedulableWorkers(in: "").isEmpty)
    }

    @Test("tartVMSlots: parses org.cirruslabs.tart-vms out of the worker Resources block")
    func tartVMSlots() {
        let detail = """
        Name             \tslate.local
        Scheduling paused\tfalse
        Resources        \torg.cirruslabs.logical-cores: 12
                         \torg.cirruslabs.memory-mib: 24576
                         \torg.cirruslabs.tart-vms: 2
        Labels           \tnone
        """
        #expect(OrchardProvider.tartVMSlots(inWorkerDetail: detail) == 2)
        #expect(OrchardProvider.tartVMSlots(inWorkerDetail: "Resources\torg.cirruslabs.logical-cores: 8") == nil)
    }

    @Test("vmCount: counts VM rows in `orchard list vms`, header excluded")
    func vmCount() {
        let listing = """
        Name                                       Created        Image     Status  Restart policy     Assigned worker
        graft-c8e22de4-8edb-45a8-9253-4c4d448b3c74 12 seconds ago img:latest running Never (0 restarts) slate.local
        some-other-vm                              1 hour ago     ubuntu    running Never (0 restarts) slate.local
        """
        #expect(OrchardProvider.vmCount(in: listing) == 2)   // both VMs consume host slots, not just graft's
        #expect(OrchardProvider.vmCount(in: "Name Created Image Status\n") == 0)
        #expect(OrchardProvider.vmCount(in: "") == 0)
    }

    // MARK: error message helper

    @Test("error message prefers stderr, falls back to stdout")
    func message() {
        #expect(OrchardProvider.message(ShellResult(exitCode: 1, stdout: "out", stderr: "boom")) == "boom")
        #expect(OrchardProvider.message(ShellResult(exitCode: 1, stdout: "out", stderr: "")) == "out")
    }
}

@Suite("Orchard config + validation")
struct OrchardConfigTests {
    @Test("decodes an orchard config block, maxVMs optional")
    func decode() throws {
        let json = #"""
        {
          "provider": "orchard",
          "pools": [{"name":"m","image":"i","os":"macos","count":2,"github":{"appId":1,"target":"org:o"}}],
          "orchard": {"controllerURL":"https://c:6120","serviceAccount":"graft","token":"t","maxVMs":12}
        }
        """#
        let cfg = try JSONDecoder().decode(GraftConfig.self, from: Data(json.utf8))
        #expect(cfg.provider == "orchard")
        #expect(cfg.orchard?.serviceAccount == "graft")
        #expect(cfg.orchard?.maxVMs == 12)
        #expect(cfg.validate().isEmpty)
    }

    @Test("maxVMs absent decodes to nil")
    func maxVMsOptional() throws {
        let json = #"{"controllerURL":"https://c:6120","serviceAccount":"g","token":"t"}"#
        let oc = try JSONDecoder().decode(OrchardConfig.self, from: Data(json.utf8))
        #expect(oc.maxVMs == nil)
    }

    @Test("orchard provider without an orchard block is a validation problem")
    func missingBlock() {
        let cfg = GraftConfig(provider: "orchard", pools: [samplePool()], orchard: nil)
        #expect(cfg.validate().contains { $0.contains("no orchard config") })
    }

    @Test("orchard provider with empty serviceAccount/token is flagged")
    func emptyCreds() {
        let oc = OrchardConfig(controllerURL: URL(string: "https://c:6120")!, serviceAccount: "", token: "")
        let cfg = GraftConfig(provider: "orchard", pools: [samplePool()], orchard: oc)
        let problems = cfg.validate()
        #expect(problems.contains { $0.contains("serviceAccount is empty") })
        #expect(problems.contains { $0.contains("token is empty") })
    }

    @Test("an unknown provider is rejected")
    func unknownProvider() {
        let cfg = GraftConfig(provider: "vmware", pools: [samplePool()])
        #expect(cfg.validate().contains { $0.contains("unknown provider") })
    }

    private func samplePool() -> PoolConfig {
        PoolConfig(name: "m", image: "i", os: .macOS, count: 1,
                   github: GitHubConfig(appId: 1, target: "org:o"))
    }
}
