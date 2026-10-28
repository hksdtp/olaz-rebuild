import SwiftUI
import WebKit

/// One WKWebView running the official renderer, kept behind the native UI.
final class RendererHost: NSObject {
    let state: ShellState
    private var webView: WKWebView?
    private var archive: AsarArchive?
    private var bridge: ZaloBridge?
    private var network: NetworkProxy?
    private var worker: SharedWorkerHost?
    private var workerWebView: WKWebView?

    init(state: ShellState) {
        self.state = state
        super.init()
    }

    var view: WKWebView? { webView }

    func start(runtime: RuntimeInstaller.Runtime) throws {
        let archive = try AsarArchive(url: runtime.asar)
        self.archive = archive

        Self.runtimeVersion = runtime.version
        let bridge = ZaloBridge(archive: archive, table: try loadTable())
        self.bridge = bridge
        let network = NetworkProxy()
        self.network = network

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.setURLSchemeHandler(AsarSchemeHandler(archive: archive, bridge: bridge), forURLScheme: "zalo-app")
        config.userContentController = makeUserContentController(runtime: runtime, bridge: bridge, network: network)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        // Runs behind the native UI, like the original: invisible but laid out and live.
        webView.alphaValue = 0
        self.webView = webView
        bridge.attach(webView: webView)
        network.attach(webView: webView)
        startSharedWorker(runtime: runtime, archive: archive, page: webView)
        Task { @MainActor in state.rendererReady = true }

        bridge.onLoginSuccess = { [weak self] in self?.openMainPage() }
        bridge.onSessionCleared = { [weak self] in self?.returnToLogin() }
        // Sessions saved before domain cookies were used are host-only; widen them once.
        let hostOnly = (HTTPCookieStorage.shared.cookies ?? []).filter { $0.name == "zpw_sek" && !$0.domain.hasPrefix(".") }
        hostOnly.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        if let secret = hostOnly.first?.value { ZaloBridge.storeAppCookie(secret) }
        // main-dist/main.js: "cookie found, load main" - zpw_sek decides the page.
        let page = Self.hasSession() ? "index.html" : "login.html"
        Log.write("opening \(page) (zpw_sek: \(Self.hasSession()))")
        webView.load(URLRequest(url: Self.pageURL(page, alreadyLogin: page == "index.html")))
    }

    /// `login-success` from the renderer means the session cookie is written; the
    /// official main process then loads the main page (main-dist/main.js onLoginSuccess).
    func openMainPage() {
        guard let webView, webView.url?.path != "/index.html" else { return }
        Log.write("login-success → loading main page")
        webView.load(URLRequest(url: Self.pageURL("index.html", alreadyLogin: true)))
    }

    /// "Đăng xuất": drop the jar, clear renderer storage, restart at login.
    func signOut() {
        guard webView != nil else { return }
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor in self?.returnToLogin() }
        }
    }

    /// Runs `body` as an async function in the page (arguments become locals), e.g.
    /// `run("return await window.__zaloChat.open(id)", ["id": convId])`.
    @MainActor
    @discardableResult
    func run(_ body: String, _ arguments: [String: Any] = [:]) async -> Any? {
        guard let webView else { return nil }
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
        } catch {
            Log.write("js failed: \(error.localizedDescription) [\(body.prefix(60))]")
            return nil
        }
    }

    /// Logout or a rejected session: the official client clears cookies and shows login.
    func returnToLogin() {
        guard let webView, webView.url?.path != "/login.html" else { return }
        Log.write("session cleared → loading login page")
        webView.load(URLRequest(url: Self.pageURL("login.html")))
    }

    /// The host picks the entry page from the same signal the official client uses:
    /// a live Zalo session cookie.
    static func hasSession() -> Bool {
        let cookies: [HTTPCookie] = HTTPCookieStorage.shared.cookies ?? []
        return cookies.contains(where: { $0.domain.contains("zalo") && ($0.expiresDate ?? .distantFuture) > Date() })
    }

    /// Boots the official `shared-worker.html` in its own web view and registers it
    /// with the page (`shared-worker-handle`), like main-dist/main.js does.
    private func startSharedWorker(runtime: RuntimeInstaller.Runtime, archive: AsarArchive, page: WKWebView) {
        let host = SharedWorkerHost()
        host.attach(page: page)
        worker = host

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.setURLSchemeHandler(AsarSchemeHandler(archive: archive, bridge: bridge!), forURLScheme: "zalo-app")
        let controller = WKUserContentController()
        controller.addScriptMessageHandler(host, contentWorld: .page, name: "zbridge")
        controller.add(ScriptMessageProxy { message in
            Log.write("sw-zlog \(message)")
            return nil
        }, name: "zlog")
        // Own proxy: socket ids restart at 1 per page and events must reach the page that opened them.
        let network = NetworkProxy()
        controller.addScriptMessageHandler(network, contentWorld: .page, name: "znet")
        for (file, name) in [(nil, "spec"), ("local-modules", "local"), ("bridge", "bridge"), ("network-shim", "net"), ("instrument", "instrument")] {
            var body = bridge?.specScript() ?? ""
            if let file, let url = hostScriptURL(file),
               let source = try? String(contentsOf: url, encoding: .utf8) { body = source }
            controller.addUserScript(WKUserScript(source: body + "\n//# sourceURL=olaz-sw-\(name).js",
                                                 injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController = controller

        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = Self.userAgent
        web.alphaValue = 0
        workerWebView = web
        host.attach(webView: web)
        bridge?.attach(worker: host, page: page)

        web.navigationDelegate = self
        network.attach(webView: web)
        web.load(URLRequest(url: Self.pageURL("shared-worker.html")))
        Log.write("shared worker page loading")
    }

    /// The renderer reads its client identity out of the page query string
    /// (`Xe = location.search`) and forwards `type`/`client_version` on every
    /// request; without them the login server answers "update Zalo PC".
    /// Values from main-dist/main.js (getClientType / getClientVersion) and Info.plist.
    static func pageURL(_ page: String, alreadyLogin: Bool = false) -> URL {
        var query = [
            "type=23",                 // MAC_CLIENT_TYPE
            "client_version=694",      // getClientVersion()
            "app_version=26.10.20",
            "about_version=",
            "new_install=0",
        ]
        // main.js Zt(): the main page is loaded with `already_login=y`, which is what
        // tells the renderer to skip the login flow. Without it the page sits on
        // "Đang đăng nhập..." forever.
        if alreadyLogin { query.append("already_login=y") }
        if let info = Self.runtimeVersion { query.append("version=\(info)") }
        return URL(string: "zalo-app://local/\(page)?\(query.joined(separator: "&"))")!
    }

    nonisolated(unsafe) static var runtimeVersion: String?

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private func loadTable() throws -> [String: Any] {
        guard let url = resourceBundle.url(forResource: "bridge-table", withExtension: "json", subdirectory: "Resources/dist") else {
            throw RuntimeError("bridge-table.json missing")
        }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let table = root["table"] as? [String: Any] else {
            throw RuntimeError("bridge-table.json không đọc được")
        }
        return table
    }

    private func makeUserContentController(
        runtime: RuntimeInstaller.Runtime,
        bridge: ZaloBridge,
        network: NetworkProxy
    ) -> WKUserContentController {
        let controller = WKUserContentController()
        let state = self.state

        controller.add(ScriptMessageProxy { [weak self] name, body in
            self?.handleMessage(name: name, body: body, state: state)
            return nil
        }, name: "zstate")
        controller.add(ScriptMessageProxy { message in
            Log.write("zlog \(message)")
            return nil
        }, name: "zlog")
        controller.addScriptMessageHandler(network, contentWorld: .page, name: "znet")
        controller.addScriptMessageHandler(bridge, contentWorld: .page, name: "zbridge")

        // Order matters: transport, bridge, page-state, then the feature adapters
        // (each attaches to the previous one's internals, e.g. chat → card actions).
        let files: [(String, String?)] = [
            ("instrument", "instrument"),
            ("spec", nil),
            ("net", "network-shim"),
            ("bridge", "bridge"),
            ("local", "local-modules"),
            ("state", "state-adapter"),
            ("conversations", "conversations-adapter"),
            ("chat", "chat-adapter"),
            ("card-actions", "card-actions-adapter"),
            ("message-actions", "message-actions-adapter"),
            ("composer", "composer-adapter"),
            ("sticker", "sticker-adapter"),
            ("poll", "poll-adapter"),
            ("contacts", "contacts-adapter"),
            ("conversation-actions", "conversation-actions-adapter"),
            ("group-create", "group-create-adapter"),
            ("media-store", "media-store-adapter"),
            ("transfer", "transfer-adapter"),
            ("zcloud", "zcloud-adapter"),
            ("notification", "notification-adapter"),
            ("call", "call-adapter"),
        ]
        for (name, file) in files {
            var body = bridge.specScript()
            if let file {
                guard let url = hostScriptURL(file),
                      let source = try? String(contentsOf: url, encoding: .utf8) else {
                    Log.write("missing host script \(file)")
                    continue
                }
                body = source
            }
            controller.addUserScript(WKUserScript(
                source: body + "\n//# sourceURL=olaz-\(name).js",
                injectionTime: .atDocumentStart,
                // `network-shim` must reach workers; everything else is main-frame only.
                forMainFrameOnly: name != "net"
            ))
        }
        return controller
    }

    private func handleMessage(name: String, body: Any, state: ShellState) {
        guard name == "zstate", let payload = body as? [String: Any] else { return }
        Task { @MainActor in state.apply(payload) }
    }
}

extension RendererHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "?"
        Log.write("page finishedLoading \(url)")
        if url.contains("shared-worker.html") {
            Log.write("shared worker page ready")
            if let workerWebView {
                workerWebView.evaluateJavaScript("JSON.stringify({bridge: typeof window.__zaloBridge, spec: Object.keys((window.__zaloBridgeSpec||{}).ipc||{}).length, app: (document.getElementById('app')||{}).innerHTML ? document.getElementById('app').innerHTML.length : 0})") { v, e in
                    Log.write("sw probe: \(v ?? "nil") \(e.map { "\($0)" } ?? "")")
                }
            }
        }
        if url.contains("index.html"), let bridge {
            // main-dist/main.js onLoginSuccess: after the main page finishes loading,
            // main pushes `login-success`, the renderer's cue to finish signing in.
            // The renderer registers its listeners while booting, so one early push is
            // lost. Repeat until the store reports a user.
            for delay in [0.3, 1.5, 3.0, 6.0, 10.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.state.page != "login" || self.state.conversations.isEmpty else { return }
                    bridge.send("login-success", [])
                    Log.write("sent login-success (\(delay)s)")
                }
            }
        }
        // Give the renderer time to boot before judging it; the main page shows a
        // splash for a few seconds and is empty until Redux has state.
        for delay in [8.0, 16.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.recoverIfSessionRejected(webView, attempt: Int(delay))
            }
        }
        guard ProcessInfo.processInfo.environment["OLAZ_PROBE"] != nil else { return }
        let script = Self.probeScript
        for delay in [1.0, 4.0, 9.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                webView.evaluateJavaScript(script) { value, error in
                    Log.write("probe(\(Int(delay))s): \(value ?? "nil") \(error.map { "err=\($0)" } ?? "")")
                }
            }
        }
    }

    /// A rendered-but-dead session is a login page with no QR; drop it and restart
    /// at login so the user is never stuck on a blank shell.
    private func recoverIfSessionRejected(_ webView: WKWebView, attempt: Int) {
        guard webView.url?.path == "/index.html",
              ProcessInfo.processInfo.environment["OLAZ_NO_RECOVER"] == nil else { return }
        Log.write("checking session (after \(attempt)s)")
        // Only a server-declared dead session counts. An empty `#app` just means the
        // renderer is still booting (it takes several seconds on the main page).
        let script = """
        (() => JSON.stringify(window.__olazRejections || []).includes('102') ? 'rejected' : 'ok')()
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard (value as? String) == "rejected" else { return }
            Log.write("session rejected, clearing cookies and returning to login")
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
            self?.returnToLogin()
        }
    }

    /// What the native UI can actually read right now, independent of the web UI.
    static let adapterProbe = """
    JSON.stringify({
      chat: typeof (window.__zaloChat || {}).open,
      convs: typeof (window.__zaloConversations || {}).setFilter,
      contacts: typeof (window.__zaloContacts || {}).refresh,
      store: !!(window.__zaloStore && window.__zaloStore.getState),
      slice: (() => { try { const s = window.__zaloStore.getState(); return Object.keys(s || {}).slice(0, 14); } catch (e) { return String(e); } })(),
      user: (() => { try { const u = window.__zaloStore.getState().user || {}; return { id: u.userId, name: u.displayName || u.zaloName }; } catch (e) { return null; } })(),
      convCount: (() => { try { const c = window.__zaloStore.getState().conversations; return c && c.data ? c.data.size : -1; } catch (e) { return -2; } })()
    })
    """

    private static let probeScript = """
    JSON.stringify({
      page: location.pathname,
      app: (document.getElementById('app')||{}).innerHTML ? document.getElementById('app').innerHTML.length : 0,
      qrPage: !!document.querySelector('.login-qr-page'),
      splash: (document.getElementById('login-splash-screen')||{style:{}}).style.display,
      images: Array.from(document.images).filter(i => i.naturalWidth > 40).map(i => i.naturalWidth + 'x' + i.naturalHeight + ' ' + String(i.src).slice(0, 24)),
      text: (document.body.innerText || '').replace(/ +/g, ' ').slice(0, 160),
      state: window.__olazStatePayload || null,
      qrCandidates: Array.from(document.querySelectorAll('.login-qr-page img, .qr-image img, canvas')).map((el) => el.tagName + ' ' + (el.naturalWidth||el.width||0) + 'x' + (el.naturalHeight||el.height||0) + ' ' + String(el.className).slice(0, 20) + ' ' + String(el.src || '').slice(0, 32)),
      rejections: (window.__olazRejections || []).slice(-2),
      cookie: document.cookie.length,
      ls: Object.keys(localStorage).filter(k => /uid|login|zpw|session/i.test(k)).slice(0, 8),
      uid: localStorage.getItem('z_uuid') || null,
      already: localStorage.getItem('sh_already_login') || localStorage.getItem('0_first_login_time') || null,
      vals: Object.fromEntries(Object.keys(localStorage).slice(0, 14).map(k => [k, String(localStorage.getItem(k)).slice(0, 40)])),
      idb: (() => { try { return Object.keys(window.indexedDB.databases ? {} : {}); } catch { return 'x'; } })(),
      stores: (() => {
        const out = [];
        for (const k of Object.keys(window.__zaloRequire ? window.__zaloRequire.c : {})) {
          const ex = window.__zaloRequire.c[k] && window.__zaloRequire.c[k].exports;
          if (ex && ex.default && typeof ex.default.getInstance === 'function' && String(ex.default.getInstance).includes('createQueryBuilder')) out.push(k);
        }
        return out.slice(0, 4);
      })()
    })
    """

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.write("page failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("page provisional failed: \(error)")
    }
}

/// `WKScriptMessageHandler` cannot be added twice for the same name, so each name
/// gets a small closure box.
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private let handler: (String, Any) -> Any?

    init(_ handler: @escaping (Any) -> Any?) {
        self.handler = { _, body in handler(body) }
    }

    init(_ handler: @escaping (String, Any) -> Any?) {
        self.handler = handler
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        _ = handler(message.name, message.body)
    }

    /// Lets `callAsync`'s `postMessage` promise resolve with a value.
    static func reply(_ message: WKScriptMessage, _ value: Any?) -> Any? {
        message.webView?.evaluateJavaScript(
            "window.webkit.messageHandlers.zbridge.__resolve && 0", completionHandler: nil
        )
        return value
    }
}

// Scripts shipped verbatim by Olaz live in Resources/dist; our own ones sit beside it.
private func hostScriptURL(_ name: String) -> URL? {
    resourceBundle.url(forResource: name, withExtension: "js", subdirectory: "Resources/dist")
        ?? resourceBundle.url(forResource: name, withExtension: "js", subdirectory: "Resources")
}

/// SwiftPM's `Bundle.module` only looks at the .app root, where codesign refuses files;
/// the packaged app (build-app.sh) keeps the resource bundle in Contents/Resources.
let resourceBundle: Bundle = Bundle.main.url(forResource: "OlazRebuild_OlazRebuild", withExtension: "bundle")
    .flatMap(Bundle.init(url:)) ?? .module
