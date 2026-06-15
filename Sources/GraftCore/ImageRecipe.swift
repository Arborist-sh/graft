import Foundation
import Yams

/// A declarative image build (a `.graft` / YAML / JSON file): clone `from`, set up a
/// toolchain + system config, snapshot the result as a local image named `name`.
///
/// High-level fields (`ruby`, `node`, `cocoapods`, `env`, …) are *compiled* by graft into
/// the right provisioning commands — including non-obvious best practices like exposing
/// `node` at a stable `/usr/local/bin` path for Xcode build phases, or activating rbenv
/// shims so gems land on the right ruby. Drop to `run:` (a `|` block or list) or `script:`
/// (a file) for anything custom.
///
/// Everything runs in **one guest shell**, in this order:
///   env → toolchain → system config → script → run → prefetch → verify → cleanup
/// VM-shape fields (`cpu`/`memory`/`disk`/`display`) are applied to the finished image
/// via `tart set`, not the guest shell.
public struct ImageRecipe: Codable, Sendable {
    public var name: String
    public let from: String

    // MARK: Toolchain (compiled to provisioning steps, in declaration order below)
    public let xcode: String?            // xcodes select <version>
    public let node: String?             // fnm install + default + corepack + stable symlink
    public let ruby: String?             // rbenv install + global + bundler
    public let python: String?           // pyenv install + global + pip upgrade
    public let java: String?             // brew openjdk@<v> + JavaVirtualMachines symlink
    public let go: Bool?                 // brew install go
    public let rust: String?             // rustup toolchain install + default
    public let packageManager: String?   // pnpm|yarn (corepack) | bun (brew)
    public let brew: [String]?           // brew install …
    public let cocoapods: String?        // gem install cocoapods -v <v>
    public let fastlane: Bool?           // gem install fastlane
    public let gems: [String]?           // gem install … --no-document
    public let npm: [String]?            // npm install -g …
    public let xcodeFirstLaunch: Bool?   // sudo xcodebuild -runFirstLaunch
    public let simulatorRuntimes: [String]? // xcodebuild -downloadPlatform <platform>
    public let warmSimulators: [String]? // boot once + shutdown (warms on-disk caches)

    // MARK: System config (baked into the image)
    public let env: [String: String]?    // persisted to /etc/zshenv + exported for the build
    public let git: GitConfig?           // git config --global user.name/.email
    public let knownHosts: [String]?     // ssh-keyscan → ~/.ssh/known_hosts
    public let write: [String: String]?  // path → file contents (written in the guest)
    public let timezone: String?         // systemsetup -settimezone
    public let hostname: String?         // scutil --set HostName/LocalHostName/ComputerName
    public let disableSpotlight: Bool?   // mdutil -a -i off (CI perf)
    public let disableSleep: Bool?       // pmset: never sleep
    public let description: String?      // metadata baked to /etc/graft-image
    public let labels: [String: String]? // metadata baked to /etc/graft-image

    // MARK: Cache warming
    public let podRepoWarm: Bool?        // pod repo update / setup
    public let prefetch: [String]?       // cache-warming commands, run in the repo mount dir
    public let repos: [PrecacheRepo]?    // clone a repo into the guest, warm caches, discard source

    /// A repo to clone into the build guest purely to warm global package-manager caches
    /// (yarn/CocoaPods/bundler/SPM). The working tree is **discarded** after `run` — only
    /// the global caches in `$HOME` survive into the image, so a runner's `yarn/pod install`
    /// hits a warm cache regardless of where `actions/checkout` puts the repo. No source is
    /// baked. For a private repo, mount your credentials read-only (mounts are NOT baked
    /// into the image) and point `ssh-key` at the mounted key.
    public struct PrecacheRepo: Codable, Sendable, Equatable {
        public let url: String
        public let ref: String?          // branch or tag (shallow clone; SHAs not supported here)
        public let run: [String]         // install commands, run in the clone to warm caches
        public let sshKey: String?       // guest path to an SSH key (e.g. a mounted one) for private clones

        enum CodingKeys: String, CodingKey { case url, ref, run, sshKey = "ssh-key" }

        public init(url: String, ref: String? = nil, run: [String] = [], sshKey: String? = nil) {
            self.url = url; self.ref = ref; self.run = run; self.sshKey = sshKey
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            ref = try c.decodeIfPresent(String.self, forKey: .ref)
            sshKey = try c.decodeIfPresent(String.self, forKey: .sshKey)
            if let single = try? c.decode(String.self, forKey: .run) {
                run = [single]
            } else {
                run = try c.decodeIfPresent([String].self, forKey: .run) ?? []
            }
        }
    }

    // MARK: Image hygiene / verification
    public let verify: [String]?         // assertions — each must exit 0 or the build fails
    public let cleanup: Bool?            // brew cleanup + clear caches (smaller image)

    // MARK: VM shape (applied via `tart set`, not the guest shell)
    public let cpu: Int?                 // tart set --cpu
    public let memory: Int?              // tart set --memory  (megabytes)
    public let disk: Int?                // tart set --disk-size (GB, grow-only)
    public let display: String?          // tart set --display  (WIDTHxHEIGHT)

    // MARK: Escape hatches (after the compiled steps; script then run)
    public let script: String?           // path to a shell script (relative to the recipe)
    public let run: [String]             // inline: a `|` block (one string) or a list

    public let mounts: [Mount]?
    public let os: GuestOS?
    /// VM networking during the build (default shared NAT). Set `bridged:<iface>` when
    /// building on a host where NAT is blocked (e.g. behind Zscaler).
    public let network: VMNetwork?

    public struct GitConfig: Codable, Sendable, Equatable {
        public let user: String?
        public let email: String?
        public init(user: String? = nil, email: String? = nil) { self.user = user; self.email = email }
    }

    public init(
        name: String, from: String,
        xcode: String? = nil, node: String? = nil, ruby: String? = nil, python: String? = nil,
        java: String? = nil, go: Bool? = nil, rust: String? = nil, packageManager: String? = nil,
        brew: [String]? = nil, cocoapods: String? = nil, fastlane: Bool? = nil,
        gems: [String]? = nil, npm: [String]? = nil,
        xcodeFirstLaunch: Bool? = nil, simulatorRuntimes: [String]? = nil, warmSimulators: [String]? = nil,
        env: [String: String]? = nil, git: GitConfig? = nil, knownHosts: [String]? = nil,
        write: [String: String]? = nil, timezone: String? = nil, hostname: String? = nil,
        disableSpotlight: Bool? = nil, disableSleep: Bool? = nil,
        description: String? = nil, labels: [String: String]? = nil,
        podRepoWarm: Bool? = nil, prefetch: [String]? = nil, repos: [PrecacheRepo]? = nil,
        verify: [String]? = nil, cleanup: Bool? = nil,
        cpu: Int? = nil, memory: Int? = nil, disk: Int? = nil, display: String? = nil,
        run: [String] = [], script: String? = nil, mounts: [Mount]? = nil, os: GuestOS? = nil,
        network: VMNetwork? = nil
    ) {
        self.name = name; self.from = from
        self.xcode = xcode; self.node = node; self.ruby = ruby; self.python = python
        self.java = java; self.go = go; self.rust = rust; self.packageManager = packageManager
        self.brew = brew; self.cocoapods = cocoapods; self.fastlane = fastlane
        self.gems = gems; self.npm = npm
        self.xcodeFirstLaunch = xcodeFirstLaunch; self.simulatorRuntimes = simulatorRuntimes
        self.warmSimulators = warmSimulators
        self.env = env; self.git = git; self.knownHosts = knownHosts; self.write = write
        self.timezone = timezone; self.hostname = hostname
        self.disableSpotlight = disableSpotlight; self.disableSleep = disableSleep
        self.description = description; self.labels = labels
        self.podRepoWarm = podRepoWarm; self.prefetch = prefetch; self.repos = repos
        self.verify = verify; self.cleanup = cleanup
        self.cpu = cpu; self.memory = memory; self.disk = disk; self.display = display
        self.run = run; self.script = script; self.mounts = mounts; self.os = os
        self.network = network
    }

    public var guestOS: GuestOS { os ?? .macOS }

    enum CodingKeys: String, CodingKey {
        case name, from, xcode, node, ruby, python, java, go, rust, brew, cocoapods, fastlane
        case gems, npm, env, git, write, timezone, hostname, description, labels, prefetch
        case verify, cleanup, cpu, memory, disk, display, script, run, mounts, os, network, repos
        case packageManager = "package-manager"
        case xcodeFirstLaunch = "xcode-first-launch"
        case simulatorRuntimes = "simulator-runtimes"
        case warmSimulators = "warm-simulators"
        case knownHosts = "known-hosts"
        case disableSpotlight = "disable-spotlight"
        case disableSleep = "disable-sleep"
        case podRepoWarm = "pod-repo-warm"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        from = try c.decode(String.self, forKey: .from)
        xcode = Self.version(c, .xcode)
        node = Self.version(c, .node)        // tolerate `node: 20` (int) as well as "20.19.4"
        ruby = Self.version(c, .ruby)
        python = Self.version(c, .python)
        java = Self.version(c, .java)
        go = try c.decodeIfPresent(Bool.self, forKey: .go)
        rust = Self.version(c, .rust)
        packageManager = try c.decodeIfPresent(String.self, forKey: .packageManager)
        brew = try c.decodeIfPresent([String].self, forKey: .brew)
        cocoapods = Self.version(c, .cocoapods)
        fastlane = try c.decodeIfPresent(Bool.self, forKey: .fastlane)
        gems = try c.decodeIfPresent([String].self, forKey: .gems)
        npm = try c.decodeIfPresent([String].self, forKey: .npm)
        xcodeFirstLaunch = try c.decodeIfPresent(Bool.self, forKey: .xcodeFirstLaunch)
        simulatorRuntimes = try c.decodeIfPresent([String].self, forKey: .simulatorRuntimes)
        warmSimulators = try c.decodeIfPresent([String].self, forKey: .warmSimulators)
        env = try c.decodeIfPresent([String: String].self, forKey: .env)
        git = try c.decodeIfPresent(GitConfig.self, forKey: .git)
        knownHosts = try c.decodeIfPresent([String].self, forKey: .knownHosts)
        write = try c.decodeIfPresent([String: String].self, forKey: .write)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
        disableSpotlight = try c.decodeIfPresent(Bool.self, forKey: .disableSpotlight)
        disableSleep = try c.decodeIfPresent(Bool.self, forKey: .disableSleep)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels)
        podRepoWarm = try c.decodeIfPresent(Bool.self, forKey: .podRepoWarm)
        prefetch = try c.decodeIfPresent([String].self, forKey: .prefetch)
        repos = try c.decodeIfPresent([PrecacheRepo].self, forKey: .repos)
        verify = try c.decodeIfPresent([String].self, forKey: .verify)
        cleanup = try c.decodeIfPresent(Bool.self, forKey: .cleanup)
        cpu = try c.decodeIfPresent(Int.self, forKey: .cpu)
        memory = try c.decodeIfPresent(Int.self, forKey: .memory)
        disk = try c.decodeIfPresent(Int.self, forKey: .disk)
        display = try c.decodeIfPresent(String.self, forKey: .display)
        script = try c.decodeIfPresent(String.self, forKey: .script)
        // `run` may be a single block-scalar script (YAML `run: |`) or a list of steps.
        if let single = try? c.decode(String.self, forKey: .run) {
            run = [single]
        } else {
            run = try c.decodeIfPresent([String].self, forKey: .run) ?? []
        }
        mounts = try c.decodeIfPresent([Mount].self, forKey: .mounts)
        os = try c.decodeIfPresent(GuestOS.self, forKey: .os)
        network = try c.decodeIfPresent(VMNetwork.self, forKey: .network)
    }

    /// Clean YAML serialization for the GUI's structured editor: omit nil/empty fields so a
    /// form-save produces a tidy `.graft` (no `xcode: null`, no `run: []`). Mirrors the
    /// decoder's key set.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(from, forKey: .from)
        try c.encodeIfPresent(xcode, forKey: .xcode)
        try c.encodeIfPresent(node, forKey: .node)
        try c.encodeIfPresent(ruby, forKey: .ruby)
        try c.encodeIfPresent(python, forKey: .python)
        try c.encodeIfPresent(java, forKey: .java)
        try c.encodeIfPresent(go, forKey: .go)
        try c.encodeIfPresent(rust, forKey: .rust)
        try c.encodeIfPresent(packageManager, forKey: .packageManager)
        try encodeNonEmpty(&c, brew, .brew)
        try c.encodeIfPresent(cocoapods, forKey: .cocoapods)
        try c.encodeIfPresent(fastlane, forKey: .fastlane)
        try encodeNonEmpty(&c, gems, .gems)
        try encodeNonEmpty(&c, npm, .npm)
        try c.encodeIfPresent(xcodeFirstLaunch, forKey: .xcodeFirstLaunch)
        try encodeNonEmpty(&c, simulatorRuntimes, .simulatorRuntimes)
        try encodeNonEmpty(&c, warmSimulators, .warmSimulators)
        try encodeNonEmptyMap(&c, env, .env)
        try c.encodeIfPresent(git, forKey: .git)
        try encodeNonEmpty(&c, knownHosts, .knownHosts)
        try encodeNonEmptyMap(&c, write, .write)
        try c.encodeIfPresent(timezone, forKey: .timezone)
        try c.encodeIfPresent(hostname, forKey: .hostname)
        try c.encodeIfPresent(disableSpotlight, forKey: .disableSpotlight)
        try c.encodeIfPresent(disableSleep, forKey: .disableSleep)
        try c.encodeIfPresent(description, forKey: .description)
        try encodeNonEmptyMap(&c, labels, .labels)
        try c.encodeIfPresent(podRepoWarm, forKey: .podRepoWarm)
        try encodeNonEmpty(&c, prefetch, .prefetch)
        if let repos, !repos.isEmpty { try c.encode(repos, forKey: .repos) }
        try encodeNonEmpty(&c, verify, .verify)
        try c.encodeIfPresent(cleanup, forKey: .cleanup)
        try c.encodeIfPresent(cpu, forKey: .cpu)
        try c.encodeIfPresent(memory, forKey: .memory)
        try c.encodeIfPresent(disk, forKey: .disk)
        try c.encodeIfPresent(display, forKey: .display)
        try c.encodeIfPresent(script, forKey: .script)
        if !run.isEmpty { try c.encode(run, forKey: .run) }
        if let mounts, !mounts.isEmpty { try c.encode(mounts, forKey: .mounts) }
        try c.encodeIfPresent(os, forKey: .os)
        try c.encodeIfPresent(network, forKey: .network)
    }

    private func encodeNonEmpty(_ c: inout KeyedEncodingContainer<CodingKeys>, _ value: [String]?, _ key: CodingKeys) throws {
        if let value, !value.isEmpty { try c.encode(value, forKey: key) }
    }

    private func encodeNonEmptyMap(_ c: inout KeyedEncodingContainer<CodingKeys>, _ value: [String: String]?, _ key: CodingKeys) throws {
        if let value, !value.isEmpty { try c.encode(value, forKey: key) }
    }

    /// Parse a `.graft` (YAML or JSON) from a string — the in-memory counterpart to `load`.
    public static func parse(_ text: String) throws -> ImageRecipe {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            return try JSONDecoder().decode(ImageRecipe.self, from: Data(text.utf8))
        }
        return try YAMLDecoder().decode(ImageRecipe.self, from: text)
    }

    /// Serialize this recipe to YAML for the structured editor (form-save).
    public func yamlString() throws -> String {
        try YAMLEncoder().encode(self)
    }

    private static func version(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decode(String.self, forKey: key) { return s }
        if let i = try? c.decode(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decode(Double.self, forKey: key) { return String(d) }
        return nil
    }

    // MARK: Compilation

    /// The full provisioning script for the guest, or nil if there's nothing to do.
    /// Order: env → toolchain → system config → script → run → prefetch → verify → cleanup.
    public func provisioning(scriptBody: String?) -> String? {
        var work = envSteps + compiledSteps + systemSteps
        if let scriptBody, !scriptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            work.append(scriptBody)
        }
        work.append(contentsOf: run)
        work.append(contentsOf: prefetchSteps)
        work.append(contentsOf: repoPrecacheSteps)
        work.append(contentsOf: verifySteps)
        work.append(contentsOf: cleanupSteps)
        guard !work.isEmpty else { return nil }   // nothing to provision
        return (["set -eo pipefail", Self.environmentBootstrap] + work).joined(separator: "\n")
    }

    /// The `tart set` settings to apply to the finished image (nil if none requested).
    public var vmSettings: VMSettings? {
        guard cpu != nil || memory != nil || disk != nil || display != nil else { return nil }
        return VMSettings(cpu: cpu, memory: memory, diskSize: disk, display: display)
    }

    public struct VMSettings: Sendable, Equatable {
        public let cpu: Int?
        public let memory: Int?
        public let diskSize: Int?
        public let display: String?
    }

    /// Load Homebrew + non-interactive flags into the provisioning shell. graft runs steps
    /// via `tart exec … bash -s` (a non-login shell), so version managers installed under
    /// Homebrew are on PATH but their shell hooks aren't loaded — `brew shellenv` fixes that
    /// portably (and covers Intel's `/usr/local` too).
    private static let environmentBootstrap = """
        # Non-interactive image build: trust the base image's taps and skip the auto-update
        # churn that otherwise warns/gates on every `brew install`.
        export HOMEBREW_NO_REQUIRE_TAP_TRUST=1
        export HOMEBREW_NO_AUTO_UPDATE=1
        export HOMEBREW_NO_ENV_HINTS=1
        export NONINTERACTIVE=1
        for _bp in /opt/homebrew /usr/local; do
          if [ -x "$_bp/bin/brew" ]; then eval "$("$_bp/bin/brew" shellenv)"; break; fi
        done
        """

    /// Persisted environment variables (exported now + written to /etc/zshenv so runner
    /// shells inherit them). Runs first so the rest of provisioning sees them.
    var envSteps: [String] {
        guard let env, !env.isEmpty else { return [] }
        var lines = ["echo \"==> Environment variables\"", "sudo touch /etc/zshenv"]
        for key in env.keys.sorted() {
            let val = env[key]!
            lines.append("export \(key)=\(Self.shq(val))")
            lines.append("echo \(Self.shq("export \(key)=\(Self.shq(val))")) | sudo tee -a /etc/zshenv >/dev/null")
        }
        return [lines.joined(separator: "\n")]
    }

    /// The high-level toolchain fields expanded into bash blocks (in install order).
    public var compiledSteps: [String] {
        var steps: [String] = []
        if let xcode { steps.append("echo \"==> Selecting Xcode \(xcode)\"\nsudo xcodes select \(xcode)") }
        if let node { steps.append(Self.nodeStep(node)) }
        if let ruby { steps.append(Self.rubyStep(ruby)) }
        if let python { steps.append(Self.pythonStep(python)) }
        if let java { steps.append(Self.javaStep(java)) }
        if go == true { steps.append("echo \"==> Go\"\nbrew install go") }
        if let rust { steps.append(Self.rustStep(rust)) }
        if let packageManager { steps.append(Self.packageManagerStep(packageManager)) }
        if let brew, !brew.isEmpty {
            let list = brew.joined(separator: " ")
            steps.append("echo \"==> brew install \(list)\"\nbrew install \(list)")
        }
        if let cocoapods {
            steps.append("echo \"==> CocoaPods \(cocoapods)\"\ngem install cocoapods -v \(cocoapods) --no-document")
        }
        if fastlane == true {
            steps.append("echo \"==> fastlane\"\ngem install fastlane --no-document")
        }
        if let gems, !gems.isEmpty {
            let list = gems.joined(separator: " ")
            steps.append("echo \"==> gem install \(list)\"\ngem install \(list) --no-document")
        }
        if let npm, !npm.isEmpty {
            let list = npm.joined(separator: " ")
            steps.append("echo \"==> npm install -g \(list)\"\nnpm install -g \(list)")
        }
        if xcodeFirstLaunch == true {
            steps.append("echo \"==> Xcode first-launch components\"\nsudo xcodebuild -runFirstLaunch")
        }
        if let simulatorRuntimes, !simulatorRuntimes.isEmpty {
            steps.append(Self.simulatorRuntimesStep(simulatorRuntimes))
        }
        if let warmSimulators, !warmSimulators.isEmpty {
            steps.append(Self.warmSimsStep(warmSimulators))
        }
        return steps
    }

    /// System-configuration steps (git, ssh known-hosts, files, host settings, metadata).
    var systemSteps: [String] {
        var steps: [String] = []
        if let git, git.user != nil || git.email != nil {
            var lines = ["echo \"==> git config\""]
            if let u = git.user { lines.append("git config --global user.name \(Self.shq(u))") }
            if let e = git.email { lines.append("git config --global user.email \(Self.shq(e))") }
            steps.append(lines.joined(separator: "\n"))
        }
        if let knownHosts, !knownHosts.isEmpty {
            var lines = ["echo \"==> known_hosts\"", "mkdir -p ~/.ssh && chmod 700 ~/.ssh"]
            for host in knownHosts {
                lines.append("ssh-keyscan \(Self.shq(host)) >> ~/.ssh/known_hosts 2>/dev/null || true")
            }
            lines.append("sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts 2>/dev/null || true")
            steps.append(lines.joined(separator: "\n"))
        }
        if let write, !write.isEmpty {
            for path in write.keys.sorted() {
                steps.append(Self.writeFileStep(path: path, contents: write[path]!))
            }
        }
        if let timezone {
            steps.append("echo \"==> Timezone \(timezone)\"\nsudo systemsetup -settimezone \(Self.shq(timezone)) || true")
        }
        if let hostname {
            steps.append("""
                echo "==> Hostname \(hostname)"
                sudo scutil --set HostName \(Self.shq(hostname))
                sudo scutil --set LocalHostName \(Self.shq(hostname))
                sudo scutil --set ComputerName \(Self.shq(hostname))
                """)
        }
        if disableSpotlight == true {
            steps.append("echo \"==> Disabling Spotlight indexing\"\nsudo mdutil -a -i off || true")
        }
        if disableSleep == true {
            steps.append("echo \"==> Disabling sleep\"\nsudo pmset -a sleep 0 displaysleep 0 disksleep 0 || true")
        }
        if let meta = metadataStep { steps.append(meta) }
        return steps
    }

    /// Bake `description` + `labels` into /etc/graft-image (shown by `graft image list`-ish
    /// tooling and handy for runtime introspection).
    private var metadataStep: String? {
        guard description != nil || (labels?.isEmpty == false) else { return nil }
        var body = ["name=\(name)"]
        if let description { body.append("description=\(description)") }
        if let labels { for k in labels.keys.sorted() { body.append("\(k)=\(labels[k]!)") } }
        let heredoc = body.joined(separator: "\n")
        return """
            echo "==> Image metadata"
            sudo tee /etc/graft-image >/dev/null <<'GRAFT_META_EOF'
            \(heredoc)
            GRAFT_META_EOF
            """
    }

    /// Cache-warming commands, run in the repo mount's guest dir when one is mounted.
    var prefetchSteps: [String] {
        guard let prefetch, !prefetch.isEmpty else { return [] }
        var lines = ["echo \"==> Prefetch (cache warming)\""]
        if let repo = mounts?.first(where: { $0.name == "repo" }) ?? mounts?.first {
            lines.append("cd \(Self.shq(repo.guestPath))")
        }
        if podRepoWarm == true {
            lines.append("echo \"==> Warming CocoaPods spec repo\"")
            lines.append("pod repo update || pod setup || true")
        }
        lines.append(contentsOf: prefetch)
        return [lines.joined(separator: "\n")]
    }

    /// Clone each repo into a throwaway dir, run its install commands to warm the global
    /// caches, then delete the working tree — only the `$HOME` caches survive into the image.
    var repoPrecacheSteps: [String] {
        guard let repos, !repos.isEmpty else { return [] }
        return repos.map { Self.repoStep($0) }
    }

    private static func repoStep(_ r: PrecacheRepo) -> String {
        var lines = ["echo \"==> Pre-caching \(r.url) (warm caches; source discarded)\""]
        if let key = r.sshKey {
            lines.append("export GIT_SSH_COMMAND=\(shq("ssh -i \(key) -o IdentitiesOnly=yes"))")
        }
        lines.append("_graft_pc=\"$(mktemp -d)\"")
        let branch = r.ref.map { " --branch \(Self.shq($0))" } ?? ""
        lines.append("git clone --depth 1\(branch) \(Self.shq(r.url)) \"$_graft_pc\"")
        if !r.run.isEmpty {
            lines.append("(")
            lines.append("  cd \"$_graft_pc\"")
            for cmd in r.run { lines.append("  \(cmd)") }
            lines.append(")")
        }
        lines.append("rm -rf \"$_graft_pc\"")   // discard the working tree — keep only warmed $HOME caches
        if r.sshKey != nil { lines.append("unset GIT_SSH_COMMAND") }
        return lines.joined(separator: "\n")
    }

    var verifySteps: [String] {
        guard let verify, !verify.isEmpty else { return [] }
        var lines = ["echo \"==> Verifying image\""]
        for cmd in verify {
            // The bare `cmd` runs (so it must stay unquoted); the echoed label is
            // shell-quoted so commands containing quotes/`;` can't break or inject.
            let label = Self.shq(cmd)
            lines.append("if \(cmd); then printf '  ✓ %s\\n' \(label); else printf '  ✗ verify failed: %s\\n' \(label); exit 1; fi")
        }
        return [lines.joined(separator: "\n")]
    }

    var cleanupSteps: [String] {
        guard cleanup == true else { return [] }
        return ["""
            echo "==> Cleanup (shrinking image)"
            brew cleanup -s 2>/dev/null || true
            rm -rf ~/Library/Caches/* 2>/dev/null || true
            sudo rm -rf /Library/Caches/Homebrew/* 2>/dev/null || true
            """]
    }

    // MARK: Step builders

    private static func nodeStep(_ v: String) -> String {
        """
        echo "==> Node \(v)"
        command -v fnm >/dev/null 2>&1 || brew install fnm
        eval "$(fnm env --shell bash)"
        fnm install \(v)
        fnm use \(v)
        fnm default \(v)
        corepack enable
        # Expose node at a stable path — Xcode build phases & non-login shells don't see fnm.
        NODE_REAL="$(node -e 'console.log(require("fs").realpathSync(process.execPath))')"
        sudo mkdir -p /usr/local/bin
        for b in node npm npx; do [ -e "$(dirname "$NODE_REAL")/$b" ] && sudo ln -sf "$(dirname "$NODE_REAL")/$b" "/usr/local/bin/$b"; done
        """
    }

    private static func rubyStep(_ v: String) -> String {
        """
        echo "==> Ruby \(v)"
        command -v rbenv >/dev/null 2>&1 || brew install rbenv ruby-build
        eval "$(rbenv init - bash)"
        rbenv install -s \(v)
        rbenv global \(v)
        rbenv rehash
        gem install bundler --no-document
        """
    }

    private static func pythonStep(_ v: String) -> String {
        """
        echo "==> Python \(v)"
        command -v pyenv >/dev/null 2>&1 || brew install pyenv
        eval "$(pyenv init - bash)"
        pyenv install -s \(v)
        pyenv global \(v)
        python -m pip install --upgrade pip
        """
    }

    private static func javaStep(_ v: String) -> String {
        """
        echo "==> Java (OpenJDK \(v))"
        brew install openjdk@\(v)
        sudo mkdir -p /Library/Java/JavaVirtualMachines
        sudo ln -sfn "$(brew --prefix)/opt/openjdk@\(v)/libexec/openjdk.jdk" "/Library/Java/JavaVirtualMachines/openjdk-\(v).jdk"
        """
    }

    private static func rustStep(_ v: String) -> String {
        """
        echo "==> Rust \(v)"
        command -v rustup >/dev/null 2>&1 || { brew install rustup && rustup-init -y --no-modify-path --default-toolchain none; }
        source "$HOME/.cargo/env" 2>/dev/null || true
        rustup toolchain install \(v)
        rustup default \(v)
        """
    }

    private static func packageManagerStep(_ pm: String) -> String {
        switch pm.lowercased() {
        case "bun":
            return "echo \"==> bun\"\nbrew install oven-sh/bun/bun"
        default:    // pnpm, yarn — managed by corepack (ships with node)
            return """
                echo "==> \(pm) (via corepack)"
                corepack enable
                corepack prepare \(pm)@latest --activate
                """
        }
    }

    private static func simulatorRuntimesStep(_ entries: [String]) -> String {
        // Entries like "iOS 26" / "watchOS 11" → download by platform name (the exact
        // version comes from the selected Xcode).
        var platforms: [String] = []
        for e in entries {
            let p = e.split(separator: " ").first.map(String.init) ?? e
            if !platforms.contains(p) { platforms.append(p) }
        }
        var lines = ["echo \"==> Downloading simulator runtimes: \(entries.joined(separator: ", "))\""]
        for p in platforms { lines.append("xcodebuild -downloadPlatform \(p)") }
        return lines.joined(separator: "\n")
    }

    private static func warmSimsStep(_ devices: [String]) -> String {
        var lines = ["echo \"==> Warming simulators\""]
        for d in devices {
            lines.append("xcrun simctl boot \"\(d)\"")
            lines.append("xcrun simctl bootstatus \"\(d)\" -b")
        }
        lines.append("xcrun simctl shutdown all")
        return lines.joined(separator: "\n")
    }

    private static func writeFileStep(path: String, contents: String) -> String {
        """
        echo "==> Writing \(path)"
        mkdir -p "$(dirname \(shq(path)))"
        cat > \(shq(path)) <<'GRAFT_WRITE_EOF'
        \(contents)
        GRAFT_WRITE_EOF
        """
    }

    /// Single-quote a value for safe interpolation into bash.
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Load

    /// Load a recipe from a `.graft` / `.yml` / `.yaml` (YAML) or `.json` file. A file
    /// literally named `Graftfile` is treated as YAML too.
    public static func load(from path: String) throws -> ImageRecipe {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else {
            throw GraftError("can't read image recipe at \(expanded)")
        }
        let ext = (expanded as NSString).pathExtension.lowercased()
        let isYAML = ["graft", "yml", "yaml"].contains(ext)
            || (expanded as NSString).lastPathComponent == "Graftfile"
        do {
            return isYAML
                ? try YAMLDecoder().decode(ImageRecipe.self, from: data)
                : try JSONDecoder().decode(ImageRecipe.self, from: data)
        } catch let error as DecodingError {
            throw GraftError("invalid image recipe at \(expanded): \(error.readableDescription)")
        } catch {
            throw GraftError("invalid image recipe at \(expanded): \(error)")
        }
    }

    /// A starter `.graft` recipe for `graft image template`.
    public static func template() -> String {
        """
        # A .graft image recipe — declarative toolchain + system config, expanded by graft
        # into the right provisioning steps. Drop to `run:` / `script:` for anything custom.
        name: rn-detox
        from: ghcr.io/cirruslabs/macos-tahoe-xcode:latest

        # ── Toolchain ──────────────────────────────────────────────
        node: "20.19.4"            # fnm install + default + corepack + stable /usr/local/bin symlink
        ruby: "3.3.5"              # rbenv install + global + bundler
        # python: "3.12"           # pyenv install + global + pip upgrade
        cocoapods: "1.15.2"        # gem install cocoapods -v …
        fastlane: true             # gem install fastlane
        npm: [detox-cli]           # npm install -g …
        brew: [applesimutils, watchman]
        xcode-first-launch: true   # sudo xcodebuild -runFirstLaunch
        # simulator-runtimes: ["iOS 26"]   # xcodebuild -downloadPlatform iOS
        warm-simulators: ["iPhone 17 Pro"] # cold-boot once to warm caches

        # ── System config (baked in) ───────────────────────────────
        env:
          LANG: en_US.UTF-8
        known-hosts: [github.com]  # ssh-keyscan → ~/.ssh/known_hosts
        disable-spotlight: true    # mdutil -a -i off (CI perf)
        # git: { user: "CI", email: "ci@example.com" }

        # ── VM shape (applied via `tart set`) ──────────────────────
        # cpu: 8
        # memory: 16384            # megabytes
        # disk: 120                # GB (grow-only)

        # ── Verify + shrink ────────────────────────────────────────
        verify:
          - node --version
          - pod --version
        cleanup: true              # brew cleanup + clear caches → smaller image

        # Escape hatch — raw bash for anything not covered (runs last):
        # run: |
        #   echo custom step
        """
    }
}
