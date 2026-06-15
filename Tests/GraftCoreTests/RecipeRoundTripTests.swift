import Foundation
import Testing
@testable import GraftCore

@Suite("Recipe round-trip (structured editor)")
struct RecipeRoundTripTests {
    @Test("the starter template parses, encodes, and re-parses")
    func templateRoundTrips() throws {
        let original = try ImageRecipe.parse(ImageRecipe.template())
        let yaml = try original.yamlString()
        let again = try ImageRecipe.parse(yaml)
        #expect(again.name == original.name)
        #expect(again.from == original.from)
    }

    @Test("toolchain + custom run + env + brew survive a round-trip")
    func fieldsSurvive() throws {
        let r = ImageRecipe(
            name: "ci", from: "ghcr.io/cirruslabs/macos-sequoia-xcode:latest",
            xcode: "16.2", node: "20", brew: ["wget", "jq"],
            warmSimulators: ["iPhone 16"],
            env: ["CI": "1"],
            run: ["echo hello", "sw_vers"]
        )
        let back = try ImageRecipe.parse(r.yamlString())
        #expect(back.xcode == "16.2")
        #expect(back.node == "20")
        #expect(back.brew == ["wget", "jq"])
        #expect(back.warmSimulators == ["iPhone 16"])
        #expect(back.env == ["CI": "1"])
        #expect(back.run == ["echo hello", "sw_vers"])
    }

    @Test("nil/empty fields are omitted from the YAML")
    func cleanOutput() throws {
        let r = ImageRecipe(name: "min", from: "base:latest")
        let yaml = try r.yamlString()
        #expect(!yaml.contains("xcode"))
        #expect(!yaml.contains("run"))
        #expect(!yaml.contains("null"))
        #expect(yaml.contains("name:"))
        #expect(yaml.contains("from:"))
    }
}
