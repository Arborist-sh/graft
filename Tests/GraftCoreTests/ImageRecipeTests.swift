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

    @Test("repos: path: workspace keeps the tree at the runner's _work dir instead of discarding it")
    func reposPathWorkspace() throws {
        let json = #"{"name":"x","from":"b","repos":[{"url":"https://github.com/me/app.git","run":["yarn install"],"path":"workspace"}]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let p = try #require(r.provisioning(scriptBody: nil))
        let dest = "\"$HOME/actions-runner/_work/app/app\""

        #expect(p.contains("$HOME/actions-runner/_work/app/app"))
        #expect(p.contains("mkdir -p \"$(dirname \(dest))\""))
        #expect(p.contains("if [ -d \(dest)/.git ]; then"))
        #expect(p.contains("git -C \(dest) fetch --depth 1 'https://github.com/me/app.git' 'HEAD'"))
        #expect(p.contains("git -C \(dest) reset --hard FETCH_HEAD"))
        #expect(p.contains("git -C \(dest) remote set-url origin 'https://github.com/me/app'"))
        #expect(p.contains("yarn install"))
        #expect(!p.contains("rm -rf \"$_graft_pc\""))   // tree is kept, not discarded
        #expect(p.contains("source kept at"))
    }

    @Test("repos: path: ~/src/app expands the leading ~ to $HOME")
    func reposPathLiteralTilde() throws {
        let json = #"{"name":"x","from":"b","repos":[{"url":"https://github.com/me/app.git","run":["yarn install"],"path":"~/src/app"}]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let p = try #require(r.provisioning(scriptBody: nil))

        #expect(p.contains("$HOME/src/app"))
        #expect(!p.contains("rm -rf \"$_graft_pc\""))
    }

    @Test("repos: path: ~bob/src is NOT tilde-expanded (only a bare ~ or ~/ is)")
    func reposPathTildeUser() throws {
        let json = #"{"name":"x","from":"b","repos":[{"url":"https://github.com/me/app.git","run":["echo hi"],"path":"~bob/src"}]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let p = try #require(r.provisioning(scriptBody: nil))

        #expect(p.contains("\"~bob/src\""))
        #expect(!p.contains("$HOMEbob"))
    }

    @Test("repos: with no path still discards the working tree (rm -rf)")
    func reposDefaultStillDiscards() throws {
        let json = #"{"name":"x","from":"b","repos":[{"url":"https://github.com/me/app.git","run":["yarn install"]}]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let p = try #require(r.provisioning(scriptBody: nil))

        #expect(p.contains("rm -rf \"$_graft_pc\""))
        #expect(p.contains("warm caches; source discarded"))
        #expect(!p.contains("remote set-url origin"))   // default (discard) leg never touches origin
    }

    @Test("repos: App token + path: workspace never leaks the raw token, still uses http.extraheader on both clone and fetch")
    func reposAppTokenWithPath() throws {
        let json = #"{"name":"x","from":"b","repos":[{"url":"https://github.com/org/app.git","ref":"main","run":["yarn install"],"path":"workspace"}]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let token = "ghs_TESTTOKEN123"
        let p = try #require(r.provisioning(scriptBody: nil, repoTokens: ["https://github.com/org/app.git": token]))
        let b64 = Data("x-access-token:\(token)".utf8).base64EncodedString()
        let dest = "\"$HOME/actions-runner/_work/app/app\""
        let header = "http.extraheader='AUTHORIZATION: basic \(b64)'"

        #expect(p.contains("git -c \(header) clone --depth 1 --branch 'main' 'https://github.com/org/app.git' \(dest)"))
        #expect(p.contains("git -C \(dest) -c \(header) fetch --depth 1 'https://github.com/org/app.git' 'main'"))
        #expect(p.contains("git -C \(dest) reset --hard FETCH_HEAD"))
        #expect(p.contains("git -C \(dest) remote set-url origin 'https://github.com/org/app'"))
        #expect(!p.contains(token))                      // raw token never written, only base64'd
        #expect(p.contains("$HOME/actions-runner/_work/app/app"))
        #expect(!p.contains("rm -rf \"$_graft_pc\""))
    }

    @Test("repos: path: + ssh-key normalises origin to https but fetches over the original ssh URL")
    func reposPathSSHKey() throws {
        let json = #"{"name":"x","from":"b","repos":[{"url":"git@github.com:org/app.git","ssh-key":"/Volumes/My Shared Files/id","ref":"main","run":["yarn install"],"path":"workspace"}]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let p = try #require(r.provisioning(scriptBody: nil, repoTokens: ["git@github.com:org/app.git": "tok"]))
        let dest = "\"$HOME/actions-runner/_work/app/app\""

        #expect(p.contains("git clone --depth 1 --branch 'main' 'git@github.com:org/app.git' \(dest)"))
        #expect(p.contains("git -C \(dest) fetch --depth 1 'git@github.com:org/app.git' 'main'"))
        #expect(!p.contains("http.extraheader"))         // ssh-key path never takes the token branch
        #expect(p.contains("git -C \(dest) remote set-url origin 'https://github.com/org/app'"))
    }

    @Test("repos: path: workspace for a non-github scp URL resolves the workspace name and never rewrites origin")
    func reposPathNonGithubWorkspaceName() throws {
        let json = #"{"name":"x","from":"b","repos":[{"url":"git@gitlab.com:org/app.git","run":["echo hi"],"path":"workspace"}]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let p = try #require(r.provisioning(scriptBody: nil))
        let dest = "\"$HOME/actions-runner/_work/app/app\""

        #expect(p.contains("git clone --depth 1 'git@gitlab.com:org/app.git' \(dest)"))
        #expect(p.contains("git -C \(dest) fetch --depth 1 'git@gitlab.com:org/app.git' 'HEAD'"))
        #expect(!p.contains("remote set-url origin"))    // only normalised for github.com URLs
    }

    @Test("repos: path: with a literal space keeps every quoted form intact")
    func reposPathLiteralWithSpace() throws {
        let json = #"{"name":"x","from":"b","repos":[{"url":"https://github.com/org/app.git","run":["echo hi"],"path":"a path with space"}]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let p = try #require(r.provisioning(scriptBody: nil))
        let dest = "\"a path with space\""

        #expect(p.contains("if [ -d \(dest)/.git ]; then"))
        #expect(p.contains("git -C \(dest) fetch --depth 1 'https://github.com/org/app.git' 'HEAD'"))
        #expect(p.contains("git clone --depth 1 'https://github.com/org/app.git' \(dest)"))
        #expect(p.contains("git -C \(dest) remote set-url origin 'https://github.com/org/app'"))
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
        #expect(slug("https://github.com/org/app.git/") == "org/app")   // trailing slash before the .git check
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

    @Test("cleanup: true preserves warm build caches instead of wiping ~/Library/Caches")
    func cleanupPreservesWarmCaches() throws {
        let r = try JSONDecoder().decode(
            ImageRecipe.self,
            from: Data(#"{"name":"x","from":"b","run":[],"cleanup":true}"#.utf8)
        )
        let p = try #require(r.provisioning(scriptBody: nil))

        #expect(!p.contains(#"rm -rf "$HOME/Library/Caches""#))
        #expect(!p.contains("rm -rf ~/Library/Caches"))
        // Pin the actual mechanism (a quoted case-pattern skip list), not just that the
        // names appear somewhere in the script — a wholesale `rm -rf` followed by an
        // unrelated echo of these names would satisfy a looser assertion.
        #expect(p.contains("'CocoaPods'|'Yarn'|'ccache'|'org.swift.swiftpm') continue ;;"))
        #expect(p.contains("Library/Developer/Xcode/DerivedData"))
    }

    @Test("cleanup: { preserve: [...] } appends to the default preserve list and stays enabled")
    func cleanupObjectFormAddsPreservePaths() throws {
        let json = #"{"name":"x","from":"b","run":[],"cleanup":{"preserve":["Library/Caches/MyThing"]}}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let cleanup = try #require(r.cleanup)

        #expect(cleanup.isEnabled)
        #expect(cleanup.preserve == ["Library/Caches/MyThing"])
        #expect(cleanup.preservePaths.contains("Library/Caches/CocoaPods"))
        #expect(cleanup.preservePaths.contains("Library/Caches/MyThing"))

        let p = try #require(r.provisioning(scriptBody: nil))
        // The custom entry must land as its own quoted case alternative, alongside the
        // defaults — not merely appear in the echoed "preserving" message.
        #expect(p.contains("'CocoaPods'|'MyThing'|'Yarn'|'ccache'|'org.swift.swiftpm') continue ;;"))
    }

    @Test("cleanup: false and an absent cleanup field both emit no cleanup step")
    func cleanupDisabledOrAbsent() throws {
        let disabled = try JSONDecoder().decode(
            ImageRecipe.self,
            from: Data(#"{"name":"x","from":"b","run":[],"cleanup":false}"#.utf8)
        )
        #expect(disabled.cleanupSteps.isEmpty)
        #expect(disabled.provisioning(scriptBody: nil)?.contains("Cleanup") != true)

        let absent = try JSONDecoder().decode(
            ImageRecipe.self,
            from: Data(#"{"name":"x","from":"b","run":[]}"#.utf8)
        )
        #expect(absent.cleanup == nil)
        #expect(absent.cleanupSteps.isEmpty)
        #expect(absent.provisioning(scriptBody: nil)?.contains("Cleanup") != true)
    }

    @Test("preserve entries containing bash-hostile characters are quoted as exact literals")
    func cleanupQuotesHostilePreserveEntries() throws {
        let json = #"""
        {"name":"x","from":"b","run":[],
         "cleanup":{"preserve":["Library/Caches/Google Chrome","Library/Caches/O'Reilly","Library/Caches/*.tmp"]}}
        """#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let p = try #require(r.provisioning(scriptBody: nil))

        #expect(p.contains("'Google Chrome'"))               // space stays inside one literal
        #expect(p.contains(#"'O'\''Reilly'"#))                // embedded ' escaped bash-style
        #expect(p.contains("'*.tmp'"))                        // glob metachar quoted, not expanded
    }

    @Test("preserve paths normalise a leading ~/, ./, or $HOME/ and reject absolute paths")
    func cleanupNormalisesPreservePaths() throws {
        let json = #"""
        {"name":"x","from":"b","run":[],
         "cleanup":{"preserve":["~/Library/Caches/Tilde","./Library/Caches/Dot","$HOME/Library/Caches/HomeVar"]}}
        """#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        let cleanup = try #require(r.cleanup)
        #expect(cleanup.preserve == ["Library/Caches/Tilde", "Library/Caches/Dot", "Library/Caches/HomeVar"])

        let p = try #require(r.provisioning(scriptBody: nil))
        #expect(p.contains("'Tilde'"))
        #expect(p.contains("'Dot'"))
        #expect(p.contains("'HomeVar'"))

        let absoluteJSON = #"{"name":"x","from":"b","run":[],"cleanup":{"preserve":["/etc/passwd"]}}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ImageRecipe.self, from: Data(absoluteJSON.utf8))
        }
    }

    @Test("encoding CleanupConfig(enabled: false, preserve: [...]) emits the bare bool, and round-trips disabled")
    func cleanupDisabledEncodesAsBareBoolEvenWithPreserve() throws {
        let config = ImageRecipe.CleanupConfig(enabled: false, preserve: ["Library/Caches/Kept"])
        let data = try JSONEncoder().encode(config)
        #expect(String(decoding: data, as: UTF8.self) == "false")

        let roundTripped = try JSONDecoder().decode(ImageRecipe.CleanupConfig.self, from: data)
        #expect(roundTripped.isEnabled == false)
        #expect(roundTripped.preserve.isEmpty)   // the bare-bool form carries no preserve list
    }

    @Test("the cleanup step actually preserves the named cache and wipes the rest, under real bash")
    func cleanupStepExecutesCorrectlyUnderBash() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("graft-cleanup-test-\(UUID().uuidString)")
        let home = tempRoot.appendingPathComponent("home")
        let bin = tempRoot.appendingPathComponent("bin")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // Seed ~/Library/Caches with one preserved dir and two that must be wiped —
        // including one with a space, to prove the quoting fix actually holds under bash.
        for sub in ["CocoaPods", "junk", "with space"] {
            let dir = home.appendingPathComponent("Library/Caches/\(sub)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("x"))
        }

        // No-op `sudo`/`brew` shims ahead of the real ones on PATH: the cleanup step's
        // `sudo rm -rf /Library/Caches/Homebrew/*` would otherwise either prompt for a
        // password or (harmlessly, via `|| true`) fail — the shim keeps the test
        // hermetic and fast either way.
        for tool in ["sudo", "brew"] {
            let shim = bin.appendingPathComponent(tool)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: shim)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        }

        let r = try JSONDecoder().decode(
            ImageRecipe.self,
            from: Data(#"{"name":"x","from":"b","run":[],"cleanup":true}"#.utf8)
        )
        let script = try #require(r.cleanupSteps.first)
        let scriptFile = tempRoot.appendingPathComponent("cleanup.sh")
        try Data(script.utf8).write(to: scriptFile)

        let result = try await Shell.run(
            "/bin/bash", ["-eo", "pipefail", scriptFile.path],
            environment: [
                "HOME": home.path,
                "PATH": "\(bin.path):/usr/bin:/bin",
            ],
            timeout: .seconds(10)
        )
        #expect(result.succeeded)

        #expect(fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/CocoaPods/x").path))
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/junk").path))
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/with space").path))
    }
}
