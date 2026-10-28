import Foundation
import WebKit

/// Second web view hosting the official `shared-worker.html`.
///
/// The renderer's `$zsharedWorker` does not use the browser SharedWorker API:
/// main registers the worker page over `shared-worker-handle`, then relays every
/// task between the two pages (`onRequestRunTask` → worker → `shared-worker-resp`).
/// While this host is missing, the main page has no DAL/sync engine and its Redux
/// store stays empty.
final class SharedWorkerHost: NSObject, WKScriptMessageHandlerWithReply {
    /// Channels main.js uses to talk to the worker page.
    static let handle = "shared-worker-handle"
    static let run = "shared-worker-run"
    static let resp = "shared-worker-resp"
    static let progress = "shared-worker-progress"
    static let abort = "shared-worker-abort"
    static let ping = "shared-worker-ping"
    static let started = "shared-worker-start"

    private weak var webView: WKWebView?
    private weak var page: WKWebView?      // the renderer, where tasks originate
    private var handlers: [String: String] = [:]   // type → handlerId registered by the worker
    private let lock = NSLock()

    var isReady: Bool { handlers.isEmpty == false }

    func attach(webView: WKWebView) { self.webView = webView }
    func attach(page: WKWebView) { self.page = page }

    // MARK: worker → main

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any] else {
            replyHandler(nil, "bad worker message")
            return
        }
        let kind = body["kind"] as? String ?? "send"
        if ProcessInfo.processInfo.environment["OLAZ_TRACE_BRIDGE"] != nil {
            let argsText = (try? JSONSerialization.data(withJSONObject: body["args"] ?? []))
                .flatMap { String(data: $0, encoding: .utf8) }?.prefix(140) ?? "?"
            Log.write("sw-in \(kind) \(body["channel"] as? String ?? "?") \(argsText)")
        }
        guard let channel = body["channel"] as? String else {
            // Path-keyed calls from the worker page are not relayed.
            replyHandler(nil, nil)
            return
        }
        switch (kind, channel) {
        case ("send", Self.handle), ("invoke", Self.handle), ("call", Self.handle):
            // `register(type)`: the worker page announces a task type it serves.
            let args = (body["args"] as? [Any]) ?? []
            if let type = args.first as? String {
                lock.lock(); handlers[type] = type; lock.unlock()
            }
            replyHandler(nil, nil)
        case ("send", Self.progress), ("invoke", Self.progress):
            let args = (body["args"] as? [Any]) ?? []
            relay(Self.progress, args)
            replyHandler(nil, nil)
        case ("send", Self.resp), ("invoke", Self.resp):
            let args = (body["args"] as? [Any]) ?? []
            relay(Self.resp, args)
            replyHandler(nil, nil)
        case ("send", Self.ping):
            replyHandler(nil, nil)
        default:
            replyHandler(nil, nil)
        }
    }

    // MARK: main → worker

    /// `sharedWorkerManager.onRequestRunTask`: forward the task to the worker page.
    func runTask(_ payload: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let script = "window.__zaloBridge && window.__zaloBridge.ipcEmit(\(Self.json(Self.run)), [\(String(decoding: data, as: UTF8.self))])"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    func abort(_ payload: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let script = "window.__zaloBridge && window.__zaloBridge.ipcEmit(\(Self.json(Self.abort)), [\(String(decoding: data, as: UTF8.self))])"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    /// Delivers worker output back to the page that asked for it.
    private func relay(_ channel: String, _ args: [Any]) {
        guard let page else { return }
        let payload = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("[]".utf8)
        let script = "window.__zaloBridge && window.__zaloBridge.ipcEmit(\(Self.json(channel)), \(String(decoding: payload, as: UTF8.self)))"
        DispatchQueue.main.async {
            page.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private static func json(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
}
