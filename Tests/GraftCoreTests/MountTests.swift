import Foundation
import Testing
@testable import GraftCore

@Suite("Mount")
struct MountTests {
    @Test("tartDirArg formats name:absolute-path with optional :ro")
    func dirArg() {
        let rw = Mount(name: "repo", source: "/Users/x/proj")
        #expect(rw.tartDirArg == "repo:/Users/x/proj")

        let ro = Mount(name: "pods", source: "/opt/cache/pods", readOnly: true)
        #expect(ro.tartDirArg == "pods:/opt/cache/pods:ro")
    }

    @Test("expands ~ and resolves relative paths to absolute")
    func pathResolution() {
        let home = Mount(name: "h", source: "~/thing").tartDirArg
        #expect(home.hasPrefix("h:/"))            // ~ expanded to an absolute path
        #expect(!home.contains("~"))

        let rel = Mount(name: "r", source: "sub/dir").tartDirArg
        #expect(rel.hasPrefix("r:/"))             // relative resolved against cwd → absolute
    }

    @Test("guest path is under /Volumes/My Shared Files")
    func guestPath() {
        #expect(Mount(name: "repo", source: "/x").guestPath == "/Volumes/My Shared Files/repo")
    }

    @Test("parses CLI --mount specs")
    func specParsing() throws {
        // bare path → name derived from last component
        #expect(try Mount(spec: "/Users/x/proj").name == "proj")
        #expect(try Mount(spec: "/Users/x/proj").readOnly == false)
        // path:ro
        #expect(try Mount(spec: "/opt/pods:ro").readOnly == true)
        #expect(try Mount(spec: "/opt/pods:ro").name == "pods")
        // name:path
        let np = try Mount(spec: "cache:/opt/pods")
        #expect(np.name == "cache" && np.source == "/opt/pods" && np.readOnly == false)
        // name:path:ro
        let npr = try Mount(spec: "cache:/opt/pods:ro")
        #expect(npr.name == "cache" && npr.source == "/opt/pods" && npr.readOnly == true)
    }

    @Test("round-trips through JSON")
    func codable() throws {
        let m = Mount(name: "pods", source: "/opt/pods", readOnly: true)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(Mount.self, from: data)
        #expect(back == m)
    }
}
