import Foundation
import Testing
@testable import GraftCore

@Suite("App manifest flow")
struct AppManifestFlowTests {
    @Test("manifest encodes snake_case keys, webhook off, and runner permissions")
    func manifestEncoding() throws {
        let manifest = GitHubAppManifest(
            name: "graft-test",
            url: "https://example.com",
            redirectURL: "http://127.0.0.1:5555/callback",
            public: false,
            defaultPermissions: GitHubAppManifest.runnerPermissions,
            defaultEvents: [],
            hookAttributes: .init(url: "https://example.com", active: false)
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]

        #expect(json["redirect_url"] as? String == "http://127.0.0.1:5555/callback")
        #expect(json["public"] as? Bool == false)
        let perms = json["default_permissions"] as! [String: String]
        #expect(perms["administration"] == "write")
        #expect(perms["organization_self_hosted_runners"] == "write")
        let hook = json["hook_attributes"] as! [String: Any]
        #expect(hook["active"] as? Bool == false)
    }

    @Test("omitting the name leaves it out of the manifest (named on GitHub instead)")
    func manifestOmitsNilName() throws {
        let manifest = GitHubAppManifest(
            name: nil, url: "https://example.com", redirectURL: "http://127.0.0.1:1/callback",
            public: false, defaultPermissions: [:], defaultEvents: [],
            hookAttributes: .init(url: "https://example.com", active: false)
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
        #expect(json["name"] == nil)
    }

    @Test("parseRequestLine pulls path + code/state out of the callback request")
    func parseCallback() {
        let raw = "GET /callback?code=abc123&state=xyz-789 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let (path, query) = AppManifestFlow.parseRequestLine(raw)
        #expect(path == "/callback")
        #expect(query["code"] == "abc123")
        #expect(query["state"] == "xyz-789")
    }

    @Test("parseRequestLine handles the no-query start route")
    func parseStart() {
        let (path, query) = AppManifestFlow.parseRequestLine("GET /start HTTP/1.1\r\n\r\n")
        #expect(path == "/start")
        #expect(query.isEmpty)
    }

    @Test("startHTML escapes the manifest JSON and targets the right account URL")
    func startPageEscaping() {
        let html = AppManifestFlow.startHTML(
            action: "https://github.com/organizations/acme/settings/apps/new",
            state: "st8",
            manifest: #"{"name":"a&b","url":"<x>"}"#
        )
        #expect(html.contains("action=\"https://github.com/organizations/acme/settings/apps/new?state=st8\""))
        #expect(html.contains("&amp;"))
        #expect(html.contains("&lt;x&gt;"))
        #expect(!html.contains("<x>"))   // raw angle brackets from the manifest must be escaped
    }

    @Test("install URL is derived from the App slug")
    func installURL() {
        let created = AppManifestFlow.Created(
            appID: 42, slug: "my-app", name: "My App", pem: "-----BEGIN-----",
            htmlURL: "https://github.com/apps/my-app", clientID: nil, webhookSecret: nil
        )
        #expect(created.installURL == "https://github.com/apps/my-app/installations/new")
    }

    @Test("loopback server serves /start and resolves the code on a matching /callback")
    func loopbackRoundTrip() async throws {
        let server = LoopbackServer(expectedState: "tok")
        let port = try server.start()
        defer { server.stop() }
        server.setStartPage("<html>hi-start</html>")

        let (startData, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/start")!)
        #expect(String(decoding: startData, as: UTF8.self).contains("hi-start"))

        async let code = server.waitForCode()
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=THECODE&state=tok")!)
        let resolved = try await code
        #expect(resolved == "THECODE")
    }

    @Test("a callback with the wrong state does not resolve the code")
    func loopbackStateMismatch() async throws {
        let server = LoopbackServer(expectedState: "right")
        let port = try server.start()
        defer { server.stop() }
        server.setStartPage("x")

        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=C&state=WRONG")!)
        await #expect(throws: (any Error).self) {
            try await server.waitForCode()
        }
    }
}
