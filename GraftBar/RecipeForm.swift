import Foundation
import GraftCore

/// A key/value row for env / write / labels editing.
struct KVRow: Identifiable, Equatable { let id = UUID(); var key = ""; var value = "" }

/// A precache-repo row.
struct RepoRow: Identifiable, Equatable {
    let id = UUID()
    var url = ""
    var ref = ""
    var run = ""      // multiline, one command per line
    var sshKey = ""
}

/// Mutable, SwiftUI-bindable mirror of `ImageRecipe` for the structured Seeds editor.
/// Optionals become "" / [] / false; converts to/from a real `ImageRecipe` so the form
/// round-trips through clean YAML. Comprehensive — covers the whole schema; `mounts` is
/// carried through verbatim (no UI, rare in image builds) so it survives a form-save.
struct RecipeForm: Equatable {
    var name = "", from = ""
    // Toolchain
    var xcode = "", node = "", ruby = "", python = "", java = "", rust = "", packageManager = "", cocoapods = ""
    var go = false, fastlane = false, xcodeFirstLaunch = false
    var brew: [String] = [], gems: [String] = [], npm: [String] = []
    // Simulators
    var simulatorRuntimes: [String] = [], warmSimulators: [String] = []
    // System config
    var env: [KVRow] = [], write: [KVRow] = [], labels: [KVRow] = []
    var gitUser = "", gitEmail = ""
    var knownHosts: [String] = []
    var timezone = "", hostname = "", description = "", display = ""
    var disableSpotlight = false, disableSleep = false
    // Caches
    var podRepoWarm = false, cleanup = false
    var prefetch: [String] = [], verify: [String] = []
    var repos: [RepoRow] = []
    // VM shape
    var cpu = "", memory = "", disk = ""
    // Escape hatches
    var script = ""       // path to a shell file
    var runScript = ""    // inline custom script (the `run:` block)
    // Build
    var os: GuestOS?
    var network = ""
    // Carried through (not edited in the form)
    var mounts: [Mount]?

    init() {}

    init(from r: ImageRecipe) {
        name = r.name; from = r.from
        xcode = r.xcode ?? ""; node = r.node ?? ""; ruby = r.ruby ?? ""; python = r.python ?? ""
        java = r.java ?? ""; rust = r.rust ?? ""; packageManager = r.packageManager ?? ""; cocoapods = r.cocoapods ?? ""
        go = r.go ?? false; fastlane = r.fastlane ?? false; xcodeFirstLaunch = r.xcodeFirstLaunch ?? false
        brew = r.brew ?? []; gems = r.gems ?? []; npm = r.npm ?? []
        simulatorRuntimes = r.simulatorRuntimes ?? []; warmSimulators = r.warmSimulators ?? []
        env = Self.rows(r.env); write = Self.rows(r.write); labels = Self.rows(r.labels)
        gitUser = r.git?.user ?? ""; gitEmail = r.git?.email ?? ""
        knownHosts = r.knownHosts ?? []
        timezone = r.timezone ?? ""; hostname = r.hostname ?? ""; description = r.description ?? ""; display = r.display ?? ""
        disableSpotlight = r.disableSpotlight ?? false; disableSleep = r.disableSleep ?? false
        podRepoWarm = r.podRepoWarm ?? false; cleanup = r.cleanup ?? false
        prefetch = r.prefetch ?? []; verify = r.verify ?? []
        repos = (r.repos ?? []).map { RepoRow(url: $0.url, ref: $0.ref ?? "", run: $0.run.joined(separator: "\n"), sshKey: $0.sshKey ?? "") }
        cpu = r.cpu.map(String.init) ?? ""; memory = r.memory.map(String.init) ?? ""; disk = r.disk.map(String.init) ?? ""
        script = r.script ?? ""
        runScript = r.run.joined(separator: "\n")
        os = r.os
        network = r.network?.specString ?? ""
        mounts = r.mounts
    }

    func toRecipe() -> ImageRecipe {
        ImageRecipe(
            name: name.trimmingCharacters(in: .whitespaces),
            from: from.trimmingCharacters(in: .whitespaces),
            xcode: s(xcode), node: s(node), ruby: s(ruby), python: s(python),
            java: s(java), go: b(go), rust: s(rust), packageManager: s(packageManager),
            brew: a(brew), cocoapods: s(cocoapods), fastlane: b(fastlane),
            gems: a(gems), npm: a(npm),
            xcodeFirstLaunch: b(xcodeFirstLaunch), simulatorRuntimes: a(simulatorRuntimes), warmSimulators: a(warmSimulators),
            env: m(env), git: gitConfig, knownHosts: a(knownHosts),
            write: m(write), timezone: s(timezone), hostname: s(hostname),
            disableSpotlight: b(disableSpotlight), disableSleep: b(disableSleep),
            description: s(description), labels: m(labels),
            podRepoWarm: b(podRepoWarm), prefetch: a(prefetch), repos: repoList,
            verify: a(verify), cleanup: b(cleanup),
            cpu: i(cpu), memory: i(memory), disk: i(disk), display: s(display),
            run: runScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [runScript],
            script: s(script), mounts: mounts, os: os,
            network: s(network).flatMap { try? VMNetwork(spec: $0) }
        )
    }

    // MARK: helpers

    private func s(_ v: String) -> String? {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
    }
    private func b(_ v: Bool) -> Bool? { v ? true : nil }
    private func i(_ v: String) -> Int? { Int(v.trimmingCharacters(in: .whitespaces)) }
    private func a(_ v: [String]) -> [String]? {
        let f = v.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return f.isEmpty ? nil : f
    }
    private func m(_ rows: [KVRow]) -> [String: String]? {
        var d: [String: String] = [:]
        for r in rows {
            let k = r.key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { d[k] = r.value }
        }
        return d.isEmpty ? nil : d
    }
    private var gitConfig: ImageRecipe.GitConfig? {
        guard s(gitUser) != nil || s(gitEmail) != nil else { return nil }
        return ImageRecipe.GitConfig(user: s(gitUser), email: s(gitEmail))
    }
    private var repoList: [ImageRecipe.PrecacheRepo]? {
        let list = repos.compactMap { row -> ImageRecipe.PrecacheRepo? in
            guard let url = s(row.url) else { return nil }
            let run = row.run.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return ImageRecipe.PrecacheRepo(url: url, ref: s(row.ref), run: run, sshKey: s(row.sshKey))
        }
        return list.isEmpty ? nil : list
    }
    private static func rows(_ map: [String: String]?) -> [KVRow] {
        (map ?? [:]).sorted { $0.key < $1.key }.map { KVRow(key: $0.key, value: $0.value) }
    }
}
