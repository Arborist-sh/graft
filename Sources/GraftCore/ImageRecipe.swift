import Foundation
import Yams

/// A declarative image build: clone `from`, run `run` steps in the guest, snapshot the
/// result as a local image named `name`. JSON (no YAML dep). `mounts` expose host dirs
/// during the build (e.g. mount the repo to warm project caches into the image).
public struct ImageRecipe: Codable, Sendable {
    public let name: String
    public let from: String
    public let run: [String]
    /// Path to a shell script run in the guest (resolved relative to the recipe file).
    /// Use this to point at an existing `build-image.sh` instead of inlining `run`.
    /// Runs before any `run` steps.
    public let script: String?
    public let mounts: [Mount]?
    public let os: GuestOS?

    public init(name: String, from: String, run: [String] = [], script: String? = nil, mounts: [Mount]? = nil, os: GuestOS? = nil) {
        self.name = name
        self.from = from
        self.run = run
        self.script = script
        self.mounts = mounts
        self.os = os
    }

    public var guestOS: GuestOS { os ?? .macOS }

    // name + from are required; everything else defaults (a script-only recipe omits run).
    enum CodingKeys: String, CodingKey { case name, from, run, script, mounts, os }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        from = try c.decode(String.self, forKey: .from)
        // `run` may be a single block-scalar script (YAML `run: |`) or a list of steps.
        if let single = try? c.decode(String.self, forKey: .run) {
            run = [single]
        } else {
            run = try c.decodeIfPresent([String].self, forKey: .run) ?? []
        }
        script = try c.decodeIfPresent(String.self, forKey: .script)
        mounts = try c.decodeIfPresent([Mount].self, forKey: .mounts)
        os = try c.decodeIfPresent(GuestOS.self, forKey: .os)
    }

    /// Load a recipe from a `.yml`/`.yaml` (preferred — `run: |` can hold a whole
    /// script) or `.json` file.
    public static func load(from path: String) throws -> ImageRecipe {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else {
            throw GraftError("can't read image recipe at \(expanded)")
        }
        let isYAML = ["yml", "yaml"].contains((expanded as NSString).pathExtension.lowercased())
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

    /// A starter recipe for `graft image template` — YAML, so `run:` can hold a whole
    /// inline script.
    public static func template() -> String {
        """
        name: rn-detox
        from: ghcr.io/cirruslabs/macos-sequoia-xcode:latest
        run: |
          set -euo pipefail
          eval "$(fnm env)" && fnm install 20 && fnm default 20 && corepack enable
          npm install -g detox-cli
          sudo xcodebuild -runFirstLaunch
        """
    }
}
