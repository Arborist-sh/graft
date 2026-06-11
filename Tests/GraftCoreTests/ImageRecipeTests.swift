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
        #expect(r.run.count == 1)                       // template uses a run: | block
    }
}
