import Foundation

/// A declarative image build: clone `from`, run `run` steps in the guest, snapshot the
/// result as a local image named `name`. JSON (no YAML dep). `mounts` expose host dirs
/// during the build (e.g. mount the repo to warm project caches into the image).
public struct ImageRecipe: Codable, Sendable {
    public let name: String
    public let from: String
    public let run: [String]
    public let mounts: [Mount]?
    public let os: GuestOS?

    public init(name: String, from: String, run: [String] = [], mounts: [Mount]? = nil, os: GuestOS? = nil) {
        self.name = name
        self.from = from
        self.run = run
        self.mounts = mounts
        self.os = os
    }

    public var guestOS: GuestOS { os ?? .macOS }

    public static func load(from path: String) throws -> ImageRecipe {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else {
            throw GraftError("can't read image recipe at \(expanded)")
        }
        do {
            return try JSONDecoder().decode(ImageRecipe.self, from: data)
        } catch let error as DecodingError {
            throw GraftError("invalid image recipe at \(expanded): \(error.readableDescription)")
        }
    }

    /// A starter recipe for `graft image template`.
    public static func template() -> String {
        """
        {
          "name": "galaxy-detox",
          "from": "ghcr.io/cirruslabs/macos-sequoia-xcode:latest",
          "run": [
            "brew install applesimutils",
            "npm install -g detox-cli"
          ]
        }
        """
    }
}
