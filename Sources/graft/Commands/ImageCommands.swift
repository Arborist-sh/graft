import ArgumentParser
import Foundation
import GraftCore

/// `graft sapling …` — grow and manage saplings (the golden images that leaves and
/// nests clone from). A sapling grows from a `.graft` seed.
struct Image: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sapling",
        abstract: "Grow and manage saplings — the golden images leaves clone from.",
        subcommands: [Build.self, Render.self, Inspect.self, List.self, Remove.self, Prune.self, Push.self, Pull.self, Template.self]
    )
}

/// Resolve a recipe's `script:` file relative to the recipe path, returning its body.
func recipeScriptBody(_ recipe: ImageRecipe, recipeFile: String) throws -> String? {
    guard let scriptRef = recipe.script else { return nil }
    let recipeDir = ((recipeFile as NSString).expandingTildeInPath as NSString).deletingLastPathComponent
    let raw = scriptRef.hasPrefix("/") ? scriptRef : (recipeDir as NSString).appendingPathComponent(scriptRef)
    let path = (raw as NSString).expandingTildeInPath
    guard let body = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw GraftError("can't read recipe script at \(path)")
    }
    return body
}

extension Image {
    struct Build: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "grow",
            abstract: "Grow a sapling from a .graft seed (also YAML / JSON)."
        )

        @Option(name: .shortAndLong, help: "Seed file (.graft / .yml / .json). See `graft sapling template`.")
        var seed: String

        @Option(name: .long, help: "Override the sapling name from the seed.")
        var name: String?

        @Option(name: .shortAndLong, help: "Config path for GitHub App creds (overrides profile resolution).")
        var config: String?

        @Option(name: .long, help: "Profile to read GitHub App creds from for private `repos:` (default: active profile).")
        var profile: String?

        func run() async throws {
            var recipe = try ImageRecipe.load(from: seed)
            if let name { recipe.name = name }

            let scriptBody = try recipeScriptBody(recipe, recipeFile: seed)
            // Only resolve GitHub App creds when there's a private repo to authenticate — keeps
            // image builds that don't use `repos:` fully decoupled from any profile/keychain.
            let repoToken = (recipe.repos?.isEmpty == false)
                ? Self.makeRepoTokenMinter(config: config, profile: profile)
                : nil
            printErr("growing sapling '\(recipe.name)' from \(recipe.from)…\n")
            try await ImageBuilder().build(recipe, scriptBody: scriptBody, repoToken: repoToken) { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            printErr("\n✓ grew '\(recipe.name)' — reference it in a pool's `image`, or `graft nest --image \(recipe.name)`")
        }

        /// Build a closure that mints a short-lived GitHub App installation token for a repo URL,
        /// so private `repos:` precache clones authenticate as graft's App — no deploy key. Resolves
        /// the App(s) from the active profile (or --config/--profile). Returns nil (→ anonymous
        /// clones) if no GitHub App is configured; mints nil per-repo if no App can mint for it.
        static func makeRepoTokenMinter(config: String?, profile: String?)
            -> (@Sendable (String) async -> String?)?
        {
            let path = GraftConfig.resolvePath(explicit: config, profile: profile)
            guard let cfg = try? GraftConfig.load(from: path) else { return nil }
            // Candidate Apps: the profile default plus any per-pool overrides, unique by id.
            // Each App's key lives in its own recorded keychain scope.
            var seen = Set<Int>()
            let clients = ([cfg.github] + cfg.pools.map { cfg.gitHub(for: $0) })
                .compactMap { $0 }
                .filter { seen.insert($0.appId).inserted }
                .map { gh in GitHubAppClient(appID: gh.appId, secrets: KeychainSecretStore(scope: gh.scope)) }
            guard !clients.isEmpty else { return nil }
            return { url in
                guard let slug = ImageRecipe.githubSlug(from: url) else { return nil }
                let target = GitHubTarget.repo(owner: slug.owner, name: slug.name)
                for client in clients {
                    if let token = try? await client.installationAccessToken(for: target) { return token }
                }
                Log.warn("no GitHub App could mint a token for \(url) — cloning anonymously (a private repo will fail)")
                return nil
            }
        }
    }

    struct Render: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the provisioning script a recipe compiles to (no build).")

        @Option(name: .shortAndLong, help: "Seed file (.graft / .yml / .json).")
        var seed: String

        func run() throws {
            let recipe = try ImageRecipe.load(from: seed)
            let scriptBody = try recipeScriptBody(recipe, recipeFile: seed)
            print("# image '\(recipe.name)' from \(recipe.from)")
            print(recipe.provisioning(scriptBody: scriptBody) ?? "# (nothing to provision)")
        }
    }

    struct Inspect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Boot an image and report the tools/versions baked into it."
        )

        @Argument(help: "Local image name (a base or a grown sapling).")
        var image: String

        func run() async throws {
            guard try await Tart.exists(name: image) else {
                throw GraftError("no local image '\(image)' — `graft sapling pull <ref>` first, or check `graft sapling list`")
            }
            let provider = LocalTartProvider()
            let temp = "graft-inspect-" + UUID().uuidString.prefix(8).lowercased()

            printErr("cloning \(image) → probe VM…")
            try await Tart.clone(image: image, to: temp)
            // Always clean up the throwaway probe VM.
            defer { Task { try? await Tart.stop(name: temp); try? await Tart.delete(name: temp) } }

            printErr("booting (a cold image can take ~60–90s)…")
            try Tart.run(name: temp)
            try await provider.waitForGuest(RunningVM(name: temp, ip: "", os: .macOS), timeout: .seconds(180))

            let probe = """
            echo "macOS:     $(sw_vers -productVersion 2>/dev/null)"
            echo "Xcode:     $(xcodebuild -version 2>/dev/null | head -1 | sed 's/Xcode //')"
            echo "Swift:     $(swift --version 2>/dev/null | head -1 | sed -E 's/.*Swift version ([0-9.]+).*/\\1/')"
            echo "Node:      $(node --version 2>/dev/null | sed 's/v//')"
            echo "Ruby:      $(ruby --version 2>/dev/null | awk '{print $2}')"
            echo "Python:    $(python3 --version 2>/dev/null | awk '{print $2}')"
            echo "Java:      $(java -version 2>&1 | head -1 | awk -F'\\"' '{print $2}')"
            echo "Go:        $(go version 2>/dev/null | awk '{print $3}' | sed 's/go//')"
            echo "Rust:      $(rustc --version 2>/dev/null | awk '{print $2}')"
            echo "CocoaPods: $(pod --version 2>/dev/null)"
            echo "Fastlane:  $(fastlane --version 2>/dev/null | awk '/fastlane [0-9]/{print $2}' | tail -1)"
            echo ""
            echo "Homebrew formulae:"
            brew list --formula 2>/dev/null | tr '\\n' ' '
            echo ""
            if [ -f /etc/graft-image ]; then echo ""; echo "graft image metadata:"; cat /etc/graft-image; fi
            """
            let result = try await provider.exec(on: RunningVM(name: temp, ip: "", os: .macOS),
                                                 ["bash", "-lc", probe], timeout: .seconds(60))
            print("# \(image)")
            print(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List local images and VMs.")

        func run() async throws {
            let vms = try await Tart.list()
            guard !vms.isEmpty else { printErr("no images"); return }
            for vm in vms.sorted(by: { $0.name < $1.name }) {
                let size = vm.size.map { "\($0)G" } ?? "-"
                print("\(vm.name)\t\(vm.source ?? "-")\t\(size)\t\(vm.state)")
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a local image/VM.")

        @Argument(help: "Image (VM) name.")
        var name: String

        func run() async throws {
            try? await Tart.stop(name: name)
            guard try await Tart.exists(name: name) else { throw GraftError("no image named '\(name)'") }
            try await Tart.delete(name: name)
            printErr("✓ removed '\(name)'")
        }
    }

    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove leftover throwaway build VMs from failed builds.")

        @Flag(help: "Also remove *running* build VMs — may kill an in-progress build.")
        var force = false

        func run() async throws {
            let temps = (try? await Tart.list())?.filter { ImageBuilder.isOrphanTemp($0.name) } ?? []
            guard !temps.isEmpty else { printErr("no orphaned build VMs"); return }
            // Skip running temps by default — a running graft-imgbuild is most likely an
            // active build, not a leftover.
            let removed = await ImageBuilder().sweepOrphans(includeRunning: force)
            printErr("✓ pruned \(removed.count) orphaned build VM(s)")
            let skipped = temps.filter { $0.isRunning && !removed.contains($0.name) }
            if !skipped.isEmpty {
                printErr("⚠ skipped \(skipped.count) running build VM(s) (likely an active build) — `graft image prune --force` to remove: \(skipped.map(\.name).joined(separator: ", "))")
            }
        }
    }

    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Push a local image to a registry.")

        @Argument(help: "Local image name.")
        var name: String

        @Argument(help: "Registry ref, e.g. ghcr.io/me/rn-detox:latest")
        var ref: String

        func run() async throws {
            printErr("pushing '\(name)' → \(ref)…")
            try await Tart.push(name: name, to: ref)
            printErr("✓ pushed")
        }
    }

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pull an image from a registry.")

        @Argument(help: "Registry ref, e.g. ghcr.io/cirruslabs/macos-tahoe-xcode:latest")
        var ref: String

        func run() async throws {
            printErr("pulling \(ref)…")
            try await withInterruptHandling { try await Tart.pull(ref: ref) }
            printErr("✓ pulled \(ref)")
        }
    }

    struct Template: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a starter image recipe.")

        func run() {
            print(ImageRecipe.template())
        }
    }
}
