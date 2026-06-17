import Foundation
import Network

/// A GitHub App "manifest" — the pre-filled spec GitHub turns into a real App during the
/// one-click [manifest flow]. graft fills in exactly the permissions runners need (so they
/// can't be set wrong by hand) and disables webhooks, since graft polls rather than
/// listening. The user still clicks "Create GitHub App" in their browser — GitHub requires
/// a human — but the App ID and private key come back automatically.
///
/// [manifest flow]: https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest
public struct GitHubAppManifest: Encodable, Sendable {
    public var name: String?
    public var url: String
    public var redirectURL: String
    public var `public`: Bool
    public var defaultPermissions: [String: String]
    public var defaultEvents: [String]
    public var hookAttributes: HookAttributes

    public struct HookAttributes: Encodable, Sendable {
        public var url: String
        public var active: Bool
    }

    enum CodingKeys: String, CodingKey {
        case name, url
        case redirectURL = "redirect_url"
        case `public`
        case defaultPermissions = "default_permissions"
        case defaultEvents = "default_events"
        case hookAttributes = "hook_attributes"
    }

    /// What graft runners need: repo-level **Administration** (write) registers repo
    /// runners; org-level **Self-hosted runners** (write) registers org runners. Requesting
    /// both means one App works for either target shape.
    public static let runnerPermissions: [String: String] = [
        "administration": "write",
        "organization_self_hosted_runners": "write",
    ]
}

/// Drives the GitHub App manifest flow end to end: stand up a loopback HTTP server, hand
/// the caller a URL to open in the browser, catch GitHub's redirect, and exchange the
/// temporary code for the new App's id + private key. Surface-agnostic — the caller injects
/// how to open a browser (`open(1)` for the CLI, `NSWorkspace` for the app).
public enum AppManifestFlow {
    /// Where to create the App: the signed-in user's account, or an org they admin.
    public enum Account: Sendable {
        case user
        case org(String)

        var newAppURL: String {
            switch self {
            case .user: return "https://github.com/settings/apps/new"
            case .org(let o): return "https://github.com/organizations/\(o)/settings/apps/new"
            }
        }
    }

    /// The freshly-created App, as `POST /app-manifests/{code}/conversions` reports it.
    public struct Created: Sendable {
        public let appID: Int
        public let slug: String
        public let name: String
        public let pem: String
        public let htmlURL: String
        public let clientID: String?
        public let webhookSecret: String?

        /// Where the user installs the App on their org/repo (the remaining manual step).
        public var installURL: String { "https://github.com/apps/\(slug)/installations/new" }
    }

    /// Run the whole flow. Returns once GitHub has created the App and handed back its
    /// credentials. Throws on timeout, a state mismatch, or a conversion error.
    ///
    /// - Parameters:
    ///   - openBrowser: invoked with the local start URL — the caller opens it however it
    ///     opens URLs. Called once the loopback server is ready to serve.
    public static func run(
        account: Account,
        name: String?,
        homepage: String = "https://github.com/arborist-sh/graft",
        apiBase: URL = URL(string: "https://api.github.com")!,
        timeout: TimeInterval = 300,
        openBrowser: @escaping @Sendable (URL) -> Void
    ) async throws -> Created {
        let state = UUID().uuidString
        let server = LoopbackServer(expectedState: state)
        let port = try server.start()
        defer { server.stop() }

        let manifest = GitHubAppManifest(
            name: name,
            url: homepage,
            redirectURL: "http://127.0.0.1:\(port)/callback",
            public: false,
            defaultPermissions: GitHubAppManifest.runnerPermissions,
            defaultEvents: [],
            hookAttributes: .init(url: homepage, active: false)
        )
        let manifestJSON = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
        server.setStartPage(startHTML(action: account.newAppURL, state: state, manifest: manifestJSON))

        guard let startURL = URL(string: "http://127.0.0.1:\(port)/start") else {
            throw GraftError("couldn't form the loopback start URL")
        }

        let code = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await server.waitForCode() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw GraftError("timed out after \(Int(timeout))s waiting for GitHub — no App was created")
            }
            openBrowser(startURL)
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        return try await convert(code: code, apiBase: apiBase)
    }

    // MARK: Code → credentials

    private static func convert(code: String, apiBase: URL) async throws -> Created {
        guard let url = URL(string: apiBase.absoluteString + "/app-manifests/\(code)/conversions") else {
            throw GraftError("bad conversion URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("graft", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GraftError("no HTTP response from GitHub manifest conversion")
        }
        guard (200..<300).contains(http.statusCode) else {
            let apiMessage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw GraftError("GitHub manifest conversion failed (\(http.statusCode))" + (apiMessage.map { ": \($0)" } ?? ""))
        }

        struct Conversion: Decodable {
            let id: Int
            let slug: String
            let name: String
            let pem: String
            let htmlURL: String
            let clientID: String?
            let webhookSecret: String?
            enum CodingKeys: String, CodingKey {
                case id, slug, name, pem
                case htmlURL = "html_url"
                case clientID = "client_id"
                case webhookSecret = "webhook_secret"
            }
        }
        let c = try JSONDecoder().decode(Conversion.self, from: data)
        return Created(
            appID: c.id, slug: c.slug, name: c.name, pem: c.pem,
            htmlURL: c.htmlURL, clientID: c.clientID, webhookSecret: c.webhookSecret
        )
    }

    // MARK: Pages

    /// The local page the browser lands on first: a hidden form carrying the manifest that
    /// auto-POSTs to GitHub's "new App" page. (The manifest is too large for a query string,
    /// so GitHub's flow requires a form POST.)
    static func startHTML(action: String, state: String, manifest: String) -> String {
        let esc = manifest
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Creating GitHub App…</title></head>
        <body style="font-family:-apple-system,system-ui,sans-serif;padding:3rem;text-align:center;color:#444">
        <p>Taking you to GitHub to create the App…</p>
        <form id="f" method="post" action="\(action)?state=\(state)">
        <input type="hidden" name="manifest" value="\(esc)">
        <noscript><button type="submit">Continue to GitHub</button></noscript>
        </form>
        <script>document.getElementById('f').submit();</script>
        </body></html>
        """
    }

    static let successHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>Done</title></head>
    <body style="font-family:-apple-system,system-ui,sans-serif;padding:3rem;text-align:center;color:#444">
    <h2>✓ App created</h2><p>You can close this tab and return to graft.</p>
    </body></html>
    """

    static func errorHTML(_ why: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Error</title></head>
        <body style="font-family:-apple-system,system-ui,sans-serif;padding:3rem;text-align:center;color:#b00">
        <h2>Something went wrong</h2><p>\(why)</p><p>Return to graft and try again.</p>
        </body></html>
        """
    }

    /// Pull the path + query out of an HTTP request's first line ("GET /callback?… HTTP/1.1").
    static func parseRequestLine(_ raw: String) -> (path: String, query: [String: String]) {
        guard let firstLine = raw.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first else { return ("/", [:]) }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return ("/", [:]) }
        let target = String(parts[1])
        guard let comps = URLComponents(string: "http://localhost" + target) else { return (target, [:]) }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] { query[item.name] = item.value }
        return (comps.path, query)
    }
}

/// A throwaway HTTP/1.1 server bound to an ephemeral loopback port. Serves exactly two
/// routes for the manifest flow: `/start` (the auto-submit page) and `/callback` (GitHub's
/// redirect carrying the code). Lives only for the duration of one `AppManifestFlow.run`.
final class LoopbackServer: @unchecked Sendable {
    private let expectedState: String
    private let queue = DispatchQueue(label: "dev.graft.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var startPage = ""
    private var continuation: CheckedContinuation<String, Error>?
    private var pending: Result<String, Error>?
    private var resumed = false

    init(expectedState: String) { self.expectedState = expectedState }

    /// Start listening on a loopback ephemeral port; returns the assigned port. Synchronous
    /// — blocks until the listener is ready (or fails).
    func start() throws -> Int {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }

        // The semaphore gives a happens-before edge, so the box is safe to read post-wait.
        final class StartResult: @unchecked Sendable { var port: UInt16 = 0; var error: Error? }
        let result = StartResult()
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: result.port = listener.port?.rawValue ?? 0; ready.signal()
            case .failed(let e): result.error = e; ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        ready.wait()
        if let error = result.error { throw GraftError("loopback listener failed: \(error)") }
        guard result.port != 0 else { throw GraftError("loopback listener got no port") }
        return Int(result.port)
    }

    func setStartPage(_ html: String) {
        lock.lock(); startPage = html; lock.unlock()
    }

    /// Suspend until GitHub's `/callback` arrives with a valid code (or the server stops).
    /// Handles a callback that races ahead of this call by stashing the result in `pending`.
    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if resumed { lock.unlock(); cont.resume(throwing: GraftError("loopback already finished")); return }
            if let p = pending { resumed = true; pending = nil; lock.unlock(); cont.resume(with: p); return }
            continuation = cont
            lock.unlock()
        }
    }

    func stop() {
        fulfill(.failure(GraftError("loopback server stopped before callback")))
        lock.lock(); let l = listener; listener = nil; lock.unlock()
        l?.cancel()
    }

    private func fulfill(_ result: Result<String, Error>) {
        lock.lock()
        if resumed { lock.unlock(); return }
        if let cont = continuation {
            resumed = true; continuation = nil
            lock.unlock()
            cont.resume(with: result)
            return
        }
        // No waiter yet — stash the first result (a real success must survive a later stop()).
        if pending == nil { pending = result }
        lock.unlock()
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let (path, query) = AppManifestFlow.parseRequestLine(raw)

            if path == "/callback" {
                if query["state"] == self.expectedState, let code = query["code"], !code.isEmpty {
                    self.respond(conn, AppManifestFlow.successHTML)
                    self.fulfill(.success(code))
                } else {
                    self.respond(conn, AppManifestFlow.errorHTML("State mismatch or missing code."))
                    self.fulfill(.failure(GraftError("GitHub callback failed: state mismatch or missing code")))
                }
            } else {
                self.lock.lock(); let page = self.startPage; self.lock.unlock()
                self.respond(conn, page)
            }
        }
    }

    private func respond(_ conn: NWConnection, _ body: String) {
        let bytes = Array(body.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + Data(bytes), completion: .contentProcessed { _ in conn.cancel() })
    }
}
