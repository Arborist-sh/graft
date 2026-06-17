import Foundation
import Testing
@testable import GraftCore

@Suite("Image recipe")
struct ImageRecipeTests {
    @Test("decodes a minimal recipe with defaults")
    func minimal() throws {
        let json = #"{"name":"rn-detox","from":"base:latest","run":["a","b"]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        #expect(r.name == "rn-detox")
        #expect(r.from == "base:latest")
        #expect(r.run == ["a", "b"])
        #expect(r.mounts == nil)
        #expect(r.guestOS == .macOS)        // default when os omitted
    }

    @Test("decodes os + mounts")
    func full() throws {
        let json = #"{"name":"x","from":"b","run":[],"os":"linux","mounts":[{"name":"repo","source":"/x","readOnly":true}]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        #expect(r.guestOS == .linux)
        #expect(r.mounts?.first == Mount(name: "repo", source: "/x", readOnly: true))
    }

    @Test("loads a YAML recipe with a run: block scalar as one inline script")
    func loadYAML() throws {
        let yaml = """
        name: rn-detox
        from: base:latest
        run: |
          set -euo pipefail
          echo step1
          echo step2
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("recipe.yml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let r = try ImageRecipe.load(from: file.path)
        #expect(r.name == "rn-detox")
        #expect(r.from == "base:latest")
        #expect(r.run.count == 1)                       // block scalar → one script string
        #expect(r.run[0].contains("echo step1"))
        #expect(r.run[0].contains("echo step2"))
    }

    @Test("compiles declarative toolchain fields into provisioning steps")
    func compile() throws {
        let r = ImageRecipe(
            name: "x", from: "b",
            node: "20.19.4", ruby: "3.4.3", brew: ["watchman"], npm: ["detox-cli"],
            xcodeFirstLaunch: true, warmSimulators: ["iPhone 17 Pro"]
        )
        let p = try #require(r.provisioning(scriptBody: nil))
        #expect(p.contains("set -eo pipefail"))
        #expect(p.contains("fnm install 20.19.4"))
        #expect(p.contains("/usr/local/bin"))                 // the node-symlink best practice
        #expect(p.contains("rbenv install -s 3.4.3"))
        #expect(p.contains("gem install bundler"))
        #expect(p.contains("brew install watchman"))
        #expect(p.contains("npm install -g detox-cli"))
        #expect(p.contains("xcodebuild -runFirstLaunch"))
        #expect(p.contains("simctl boot \"iPhone 17 Pro\""))
        // node before ruby before xcode (toolchain ordering)
        #expect(p.range(of: "fnm install")!.lowerBound < p.range(of: "rbenv install")!.lowerBound)
    }

    @Test("compiled steps come before script + run, and run appends after")
    func order() throws {
        let r = ImageRecipe(name: "x", from: "b", node: "20", run: ["echo custom"])
        let p = try #require(r.provisioning(scriptBody: "echo from-script"))
        #expect(p.range(of: "fnm install")!.lowerBound < p.range(of: "echo from-script")!.lowerBound)
        #expect(p.range(of: "echo from-script")!.lowerBound < p.range(of: "echo custom")!.lowerBound)
    }

    @Test("loads a .graft file; tolerates a bare-int version")
    func loadGraft() throws {
        let graft = """
        name: g1
        from: base:latest
        node: 20
        ruby: 3.4.3
        xcode-first-launch: true
        warm-simulators: ["iPhone 17 Pro"]
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("image.graft")
        try graft.write(to: file, atomically: true, encoding: .utf8)

        let r = try ImageRecipe.load(from: file.path)
        #expect(r.node == "20")                  // bare int coerced to string
        #expect(r.ruby == "3.4.3")
        #expect(r.xcodeFirstLaunch == true)
        #expect(r.warmSimulators == ["iPhone 17 Pro"])
    }

    @Test("compiles the full field set, in the right order")
    func fullFieldSet() throws {
        let yaml = """
        name: x
        from: b
        xcode: "16.2"
        node: "20.19.4"
        ruby: "3.4.3"
        python: "3.12"
        java: "21"
        go: true
        rust: stable
        package-manager: pnpm
        cocoapods: "1.15.2"
        fastlane: true
        simulator-runtimes: ["iOS 26", "watchOS 11"]
        env:
          LANG: en_US.UTF-8
          FOO: bar
        git: { user: CI, email: ci@example.com }
        known-hosts: [github.com]
        write:
          "~/.npmrc": "registry=https://example.com"
        timezone: UTC
        hostname: ci-mac
        disable-spotlight: true
        disable-sleep: true
        description: "RN CI base"
        labels: { team: mobile }
        pod-repo-warm: true
        prefetch: ["bundle install"]
        verify: ["node --version", "pod --version"]
        cleanup: true
        cpu: 8
        memory: 16384
        disk: 120
        display: 1920x1080
        mounts: [{ name: repo, source: /tmp/repo }]
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("full.graft")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        let r = try ImageRecipe.load(from: file.path)
        let p = try #require(r.provisioning(scriptBody: nil))

        // toolchain
        #expect(p.contains("xcodes select 16.2"))
        #expect(p.contains("pyenv install -s 3.12"))
        #expect(p.contains("openjdk@21"))
        #expect(p.contains("brew install go"))
        #expect(p.contains("rustup default stable"))
        #expect(p.contains("corepack prepare pnpm@latest"))
        #expect(p.contains("gem install cocoapods -v 1.15.2"))
        #expect(p.contains("gem install fastlane"))
        #expect(p.contains("xcodebuild -downloadPlatform iOS"))
        #expect(p.contains("xcodebuild -downloadPlatform watchOS"))
        // system config
        #expect(p.contains("export LANG='en_US.UTF-8'"))
        #expect(p.contains("/etc/zshenv"))
        #expect(p.contains("git config --global user.name 'CI'"))
        #expect(p.contains("ssh-keyscan 'github.com'"))
        #expect(p.contains(".npmrc"))
        #expect(p.contains("settimezone 'UTC'"))
        #expect(p.contains("scutil --set HostName 'ci-mac'"))
        #expect(p.contains("mdutil -a -i off"))
        #expect(p.contains("pmset -a sleep 0"))
        // cache warming / verify / cleanup
        #expect(p.contains("cd '/Volumes/My Shared Files/repo'"))
        #expect(p.contains("pod repo update"))
        #expect(p.contains("bundle install"))
        #expect(p.contains("✓ node --version") || p.contains("node --version"))
        #expect(p.contains("brew cleanup"))

        // ordering: env → toolchain → verify → cleanup
        #expect(p.range(of: "export LANG")!.lowerBound < p.range(of: "fnm install")!.lowerBound)
        #expect(p.range(of: "fnm install")!.lowerBound < p.range(of: "Verifying image")!.lowerBound)
        #expect(p.range(of: "Verifying image")!.lowerBound < p.range(of: "Cleanup")!.lowerBound)

        // VM settings → tart set
        let vm = try #require(r.vmSettings)
        #expect(vm.cpu == 8)
        #expect(vm.memory == 16384)
        #expect(vm.diskSize == 120)
        #expect(vm.display == "1920x1080")
    }

    @Test("compiles repos: into clone → install → discard (warm-cache precache)")
    func reposPrecache() throws {
        let yaml = """
        name: x
        from: b
        repos:
          - url: git@github.com:org/app.git
            ref: main
            ssh-key: "/Volumes/My Shared Files/ssh/id_ed25519"
            run:
              - yarn install
              - cd ios && bundle exec pod install
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("r.graft")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        let r = try ImageRecipe.load(from: file.path)
        let p = try #require(r.provisioning(scriptBody: nil))

        #expect(p.contains("git clone --depth 1 --branch 'main' 'git@github.com:org/app.git'"))
        #expect(p.contains("GIT_SSH_COMMAND='ssh -i /Volumes/My Shared Files/ssh/id_ed25519 -o IdentitiesOnly=yes'"))
        #expect(p.contains("yarn install"))
        #expect(p.contains("bundle exec pod install"))
        #expect(p.contains("rm -rf \"$_graft_pc\""))      // source discarded
        #expect(p.contains("unset GIT_SSH_COMMAND"))
        #expect(r.repos?.first?.run.count == 2)
    }

    @Test("repos: with an App token clones over https via http.extraheader (raw token never appears)")
    func reposAppToken() throws {
        let json = #"{"name":"x","from":"b","repos":[{"url":"https://github.com/org/app.git","ref":"main","run":["yarn install"]}]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let token = "ghs_TESTTOKEN123"
        let p = try #require(r.provisioning(scriptBody: nil, repoTokens: ["https://github.com/org/app.git": token]))
        let b64 = Data("x-access-token:\(token)".utf8).base64EncodedString()

        // Token rides in a command-scoped http.extraheader (like actions/checkout), over https.
        #expect(p.contains("git -c http.extraheader='AUTHORIZATION: basic \(b64)' clone --depth 1 --branch 'main' 'https://github.com/org/app.git'"))
        #expect(!p.contains("git clone --depth 1"))   // not the anonymous form
        #expect(!p.contains(token))                    // raw token never written, only base64'd in the header
        #expect(p.contains("yarn install"))
        #expect(p.contains("rm -rf \"$_graft_pc\""))   // source still discarded
    }

    @Test("an explicit ssh-key takes precedence over an App token")
    func sshKeyBeatsToken() throws {
        let json = #"{"name":"x","from":"b","repos":[{"url":"git@github.com:org/app.git","ssh-key":"/Volumes/My Shared Files/id","run":["yarn install"]}]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let p = try #require(r.provisioning(scriptBody: nil, repoTokens: ["git@github.com:org/app.git": "tok"]))
        #expect(p.contains("GIT_SSH_COMMAND='ssh -i /Volumes/My Shared Files/id -o IdentitiesOnly=yes'"))
        #expect(p.contains("git clone --depth 1 'git@github.com:org/app.git'"))
        #expect(!p.contains("http.extraheader"))       // token path not taken when ssh-key is set
    }

    @Test("a repo with no token and no ssh-key clones anonymously")
    func reposAnonymous() throws {
        let json = #"{"name":"x","from":"b","repos":[{"url":"https://github.com/octocat/Hello-World.git","run":["echo hi"]}]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let p = try #require(r.provisioning(scriptBody: nil))   // no tokens supplied
        #expect(p.contains("git clone --depth 1 'https://github.com/octocat/Hello-World.git'"))
        #expect(!p.contains("http.extraheader"))
    }

    @Test("githubSlug parses owner/name from https + ssh urls, nil for other hosts")
    func githubSlug() {
        func slug(_ u: String) -> String? { ImageRecipe.githubSlug(from: u).map { "\($0.owner)/\($0.name)" } }
        #expect(slug("https://github.com/org/app.git") == "org/app")
        #expect(slug("https://github.com/org/app") == "org/app")
        #expect(slug("git@github.com:org/app.git") == "org/app")
        #expect(slug("ssh://git@github.com/org/app.git") == "org/app")
        #expect(slug("https://gitlab.com/org/app.git") == nil)
        #expect(slug("not a url") == nil)
    }

    @Test("parses VM network specs and decodes them from a recipe")
    func network() throws {
        #expect(try VMNetwork(spec: "nat").tartFlags == [])
        #expect(try VMNetwork(spec: "bridged:en8").tartFlags == ["--net-bridged=en8"])
        #expect(try VMNetwork(spec: "bridged=Wi-Fi").tartFlags == ["--net-bridged=Wi-Fi"])
        #expect(try VMNetwork(spec: "softnet").tartFlags == ["--net-softnet"])
        #expect(throws: GraftError.self) { try VMNetwork(spec: "bogus") }

        let json = #"{"name":"x","from":"b","network":"bridged:en8"}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        #expect(r.network == .bridged("en8"))
    }

    @Test("vmSettings is nil when no VM-shape fields are set")
    func noVMSettings() throws {
        let r = ImageRecipe(name: "x", from: "b", node: "20")
        #expect(r.vmSettings == nil)
    }

    @Test("recognizes throwaway build VMs for the orphan sweep")
    func orphanDetection() {
        #expect(ImageBuilder.isOrphanTemp("graft-imgbuild-d1489b32"))
        #expect(!ImageBuilder.isOrphanTemp("g1-mobile-ci"))
        #expect(!ImageBuilder.isOrphanTemp("graft-dev-macos-tahoe-xcode"))
    }

    @Test("the starter template is valid YAML that loads")
    func template() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("template.yml")
        try ImageRecipe.template().write(to: file, atomically: true, encoding: .utf8)

        let r = try ImageRecipe.load(from: file.path)
        #expect(!r.name.isEmpty)
        #expect(!r.from.isEmpty)
        #expect(r.node != nil)                          // template showcases declarative fields
        #expect(r.provisioning(scriptBody: nil) != nil) // and compiles to something runnable
    }
}
