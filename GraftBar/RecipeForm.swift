import Foundation
import GraftCore

/// A key/value row for env / write / labels.
struct KVRow: Identifiable, Equatable { let id = UUID(); var key = ""; var value = "" }

/// A precache-repo row.
struct RepoRow: Identifiable, Equatable {
    let id = UUID(); var url = ""; var ref = ""; var run = ""; var sshKey = ""
}

/// A custom script block (the `run:` list — one entry per block, multiline).
struct ScriptRow: Identifiable, Equatable { let id = UUID(); var body = "" }

/// The builder components a seed can have. The editor starts empty (just name/from) and the
/// user adds only what they want ("Add toolchain → Python"). Each maps to one recipe field
/// (or a small group). Presence in `RecipeForm.active` = it's in the recipe.
enum Comp: String, CaseIterable, Identifiable {
    // toolchain
    case xcode, node, ruby, python, java, rust, go, cocoapods, fastlane, packageManager, xcodeFirstLaunch
    // packages
    case brew, gems, npm
    // simulators
    case simulatorRuntimes, warmSimulators
    // scripts
    case scripts, scriptFile
    // caches
    case prefetch, verify, repos, podRepoWarm, cleanup
    // system
    case env, write, labels, git, timezone, hostname, knownHosts, disableSpotlight, disableSleep, description
    // vm
    case vmShape, os, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xcode: "Xcode"; case .node: "Node"; case .ruby: "Ruby"; case .python: "Python"
        case .java: "Java"; case .rust: "Rust"; case .go: "Go"; case .cocoapods: "CocoaPods"
        case .fastlane: "Fastlane"; case .packageManager: "Package manager"; case .xcodeFirstLaunch: "Xcode first-launch"
        case .brew: "Homebrew packages"; case .gems: "Gems"; case .npm: "npm (global)"
        case .simulatorRuntimes: "Simulator runtimes"; case .warmSimulators: "Warm simulators"
        case .scripts: "Custom scripts"; case .scriptFile: "Script file"
        case .prefetch: "Prefetch"; case .verify: "Verify"; case .repos: "Precache repos"
        case .podRepoWarm: "Warm CocoaPods spec repo"; case .cleanup: "Cleanup (smaller image)"
        case .env: "Env vars"; case .write: "Write files"; case .labels: "Labels"; case .git: "Git identity"
        case .timezone: "Timezone"; case .hostname: "Hostname"; case .knownHosts: "Known hosts"
        case .disableSpotlight: "Disable Spotlight"; case .disableSleep: "Disable sleep"; case .description: "Description"
        case .vmShape: "VM shape"; case .os: "Guest OS"; case .network: "Build network"
        }
    }

    /// A presence-only toggle (no value) — adding it just enables the behavior.
    var isFlag: Bool {
        switch self {
        case .go, .fastlane, .xcodeFirstLaunch, .podRepoWarm, .cleanup, .disableSpotlight, .disableSleep: true
        default: false
        }
    }

    enum Category: String, CaseIterable { case toolchain = "Toolchain", packages = "Packages", simulators = "Simulators", scripts = "Scripts", caches = "Caches", system = "System", vm = "VM & build" }

    var category: Category {
        switch self {
        case .xcode, .node, .ruby, .python, .java, .rust, .go, .cocoapods, .fastlane, .packageManager, .xcodeFirstLaunch: .toolchain
        case .brew, .gems, .npm: .packages
        case .simulatorRuntimes, .warmSimulators: .simulators
        case .scripts, .scriptFile: .scripts
        case .prefetch, .verify, .repos, .podRepoWarm, .cleanup: .caches
        case .env, .write, .labels, .git, .timezone, .hostname, .knownHosts, .disableSpotlight, .disableSleep, .description: .system
        case .vmShape, .os, .network: .vm
        }
    }
}

/// Mutable, bindable mirror of `ImageRecipe` for the builder. `active` tracks which
/// components the user has added; only those serialize. Round-trips through clean YAML.
struct RecipeForm: Equatable {
    var name = "", from = ""
    var active: Set<Comp> = []

    // Values (only meaningful when their Comp is active)
    var xcode = "", node = "", ruby = "", python = "", java = "", rust = "", packageManager = "", cocoapods = ""
    var brew: [String] = [], gems: [String] = [], npm: [String] = []
    var simulatorRuntimes: [String] = [], warmSimulators: [String] = []
    var env: [KVRow] = [], write: [KVRow] = [], labels: [KVRow] = []
    var gitUser = "", gitEmail = ""
    var knownHosts: [String] = []
    var timezone = "", hostname = "", description = "", display = ""
    var prefetch: [String] = [], verify: [String] = []
    var repos: [RepoRow] = []
    var cpu = "", memory = "", disk = ""
    var scriptFile = ""
    var scripts: [ScriptRow] = []
    var os: GuestOS = .macOS
    var network = ""
    var mounts: [Mount]?   // carried through verbatim

    init() {}

    init(from r: ImageRecipe) {
        name = r.name; from = r.from
        var a: Set<Comp> = []
        func set(_ c: Comp, _ on: Bool) { if on { a.insert(c) } }

        xcode = r.xcode ?? ""; set(.xcode, r.xcode != nil)
        node = r.node ?? ""; set(.node, r.node != nil)
        ruby = r.ruby ?? ""; set(.ruby, r.ruby != nil)
        python = r.python ?? ""; set(.python, r.python != nil)
        java = r.java ?? ""; set(.java, r.java != nil)
        rust = r.rust ?? ""; set(.rust, r.rust != nil)
        packageManager = r.packageManager ?? ""; set(.packageManager, r.packageManager != nil)
        cocoapods = r.cocoapods ?? ""; set(.cocoapods, r.cocoapods != nil)
        set(.go, r.go == true); set(.fastlane, r.fastlane == true); set(.xcodeFirstLaunch, r.xcodeFirstLaunch == true)
        set(.podRepoWarm, r.podRepoWarm == true); set(.cleanup, r.cleanup == true)
        set(.disableSpotlight, r.disableSpotlight == true); set(.disableSleep, r.disableSleep == true)

        brew = r.brew ?? []; set(.brew, !(r.brew ?? []).isEmpty)
        gems = r.gems ?? []; set(.gems, !(r.gems ?? []).isEmpty)
        npm = r.npm ?? []; set(.npm, !(r.npm ?? []).isEmpty)
        simulatorRuntimes = r.simulatorRuntimes ?? []; set(.simulatorRuntimes, !(r.simulatorRuntimes ?? []).isEmpty)
        warmSimulators = r.warmSimulators ?? []; set(.warmSimulators, !(r.warmSimulators ?? []).isEmpty)
        knownHosts = r.knownHosts ?? []; set(.knownHosts, !(r.knownHosts ?? []).isEmpty)
        prefetch = r.prefetch ?? []; set(.prefetch, !(r.prefetch ?? []).isEmpty)
        verify = r.verify ?? []; set(.verify, !(r.verify ?? []).isEmpty)

        env = Self.rows(r.env); set(.env, !(r.env ?? [:]).isEmpty)
        write = Self.rows(r.write); set(.write, !(r.write ?? [:]).isEmpty)
        labels = Self.rows(r.labels); set(.labels, !(r.labels ?? [:]).isEmpty)
        gitUser = r.git?.user ?? ""; gitEmail = r.git?.email ?? ""; set(.git, r.git != nil)
        timezone = r.timezone ?? ""; set(.timezone, r.timezone != nil)
        hostname = r.hostname ?? ""; set(.hostname, r.hostname != nil)
        description = r.description ?? ""; set(.description, r.description != nil)

        scripts = r.run.map { ScriptRow(body: $0) }; set(.scripts, !r.run.isEmpty)
        scriptFile = r.script ?? ""; set(.scriptFile, r.script != nil)
        repos = (r.repos ?? []).map { RepoRow(url: $0.url, ref: $0.ref ?? "", run: $0.run.joined(separator: "\n"), sshKey: $0.sshKey ?? "") }
        set(.repos, !(r.repos ?? []).isEmpty)

        cpu = r.cpu.map(String.init) ?? ""; memory = r.memory.map(String.init) ?? ""
        disk = r.disk.map(String.init) ?? ""; display = r.display ?? ""
        set(.vmShape, r.cpu != nil || r.memory != nil || r.disk != nil || r.display != nil)
        os = r.os ?? .macOS; set(.os, r.os != nil)
        network = r.network?.specString ?? ""; set(.network, r.network != nil)
        mounts = r.mounts
        active = a
    }

    func toRecipe() -> ImageRecipe {
        func on(_ c: Comp) -> Bool { active.contains(c) }
        func sv(_ c: Comp, _ v: String) -> String? { on(c) ? s(v) : nil }
        func av(_ c: Comp, _ v: [String]) -> [String]? { on(c) ? a(v) : nil }
        func flag(_ c: Comp) -> Bool? { on(c) ? true : nil }

        return ImageRecipe(
            name: name.trimmingCharacters(in: .whitespaces),
            from: from.trimmingCharacters(in: .whitespaces),
            xcode: sv(.xcode, xcode), node: sv(.node, node), ruby: sv(.ruby, ruby), python: sv(.python, python),
            java: sv(.java, java), go: flag(.go), rust: sv(.rust, rust), packageManager: sv(.packageManager, packageManager),
            brew: av(.brew, brew), cocoapods: sv(.cocoapods, cocoapods), fastlane: flag(.fastlane),
            gems: av(.gems, gems), npm: av(.npm, npm),
            xcodeFirstLaunch: flag(.xcodeFirstLaunch), simulatorRuntimes: av(.simulatorRuntimes, simulatorRuntimes), warmSimulators: av(.warmSimulators, warmSimulators),
            env: on(.env) ? m(env) : nil, git: on(.git) ? gitConfig : nil, knownHosts: av(.knownHosts, knownHosts),
            write: on(.write) ? m(write) : nil, timezone: sv(.timezone, timezone), hostname: sv(.hostname, hostname),
            disableSpotlight: flag(.disableSpotlight), disableSleep: flag(.disableSleep),
            description: sv(.description, description), labels: on(.labels) ? m(labels) : nil,
            podRepoWarm: flag(.podRepoWarm), prefetch: av(.prefetch, prefetch), repos: on(.repos) ? repoList : nil,
            verify: av(.verify, verify), cleanup: flag(.cleanup),
            cpu: on(.vmShape) ? i(cpu) : nil, memory: on(.vmShape) ? i(memory) : nil,
            disk: on(.vmShape) ? i(disk) : nil, display: on(.vmShape) ? s(display) : nil,
            run: on(.scripts) ? scripts.map(\.body).compactMap(s) : [],
            script: sv(.scriptFile, scriptFile), mounts: mounts, os: on(.os) ? os : nil,
            network: on(.network) ? s(network).flatMap { try? VMNetwork(spec: $0) } : nil
        )
    }

    /// Remove a component and clear its values so it doesn't reappear or serialize.
    mutating func remove(_ c: Comp) {
        active.remove(c)
        switch c {
        case .xcode: xcode = ""; case .node: node = ""; case .ruby: ruby = ""; case .python: python = ""
        case .java: java = ""; case .rust: rust = ""; case .packageManager: packageManager = ""; case .cocoapods: cocoapods = ""
        case .brew: brew = []; case .gems: gems = []; case .npm: npm = []
        case .simulatorRuntimes: simulatorRuntimes = []; case .warmSimulators: warmSimulators = []
        case .scripts: scripts = []; case .scriptFile: scriptFile = ""
        case .prefetch: prefetch = []; case .verify: verify = []; case .repos: repos = []
        case .env: env = []; case .write: write = []; case .labels: labels = []
        case .git: gitUser = ""; gitEmail = ""
        case .timezone: timezone = ""; case .hostname: hostname = ""; case .description: description = ""
        case .knownHosts: knownHosts = []
        case .vmShape: cpu = ""; memory = ""; disk = ""; display = ""
        case .network: network = ""
        case .go, .fastlane, .xcodeFirstLaunch, .podRepoWarm, .cleanup, .disableSpotlight, .disableSleep, .os: break
        }
    }

    // MARK: helpers
    private func s(_ v: String) -> String? { let t = v.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
    private func i(_ v: String) -> Int? { Int(v.trimmingCharacters(in: .whitespaces)) }
    private func a(_ v: [String]) -> [String]? {
        let f = v.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; return f.isEmpty ? nil : f
    }
    private func m(_ rows: [KVRow]) -> [String: String]? {
        var d: [String: String] = [:]
        for r in rows { let k = r.key.trimmingCharacters(in: .whitespaces); if !k.isEmpty { d[k] = r.value } }
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
