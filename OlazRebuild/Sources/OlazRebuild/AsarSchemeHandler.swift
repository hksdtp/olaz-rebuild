import Foundation
import WebKit

/// Serves `zalo-app://local/<path>` out of the official `app.asar`.
final class AsarSchemeHandler: NSObject, WKURLSchemeHandler {
    private let archive: AsarArchive
    private weak var bridge: ZaloBridge?

    init(archive: AsarArchive, bridge: ZaloBridge) {
        self.archive = archive
        self.bridge = bridge
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(RuntimeError("URL rỗng"))
            return
        }
        // The shim's synchronous bridge calls arrive as POSTs to this virtual path.
        if url.path == "/__olaz/bridge-sync" {
            serveSync(task, url: url)
            return
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        // The official pages live under `pc-dist/` inside the asar; the scheme maps
        // root URLs onto that directory exactly like the Electron file:// load did.
        let candidates = [path, "/pc-dist" + path]

        for candidate in candidates where archive.contains(candidate) {
            do {
                let data = try archive.read(candidate)
                if ProcessInfo.processInfo.environment["OLAZ_TRACE_ASAR"] != nil {
                    Log.write("serve \(candidate) \(data.count)B")
                }
                let response = URLResponse(
                    url: url,
                    mimeType: Self.mime(for: candidate),
                    expectedContentLength: data.count,
                    textEncodingName: "utf-8"
                )
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
                return
            } catch {
                Log.write("asar read failed \(candidate): \(error)")
            }
        }
        Log.write("404 \(path)")
        task.didFailWithError(RuntimeError("404 \(path)"))
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// Synchronous XHR body: `{path|channel, args}` answered with `{value}` or `{error}`.
    private func serveSync(_ task: WKURLSchemeTask, url: URL) {
        let data = task.request.httpBody ?? Data()
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            respond(task, url: url, payload: ["error": "bad sync request"])
            return
        }
        guard let bridge else {
            respond(task, url: url, payload: ["error": "bridge unavailable"])
            return
        }
        let result: [String: Any]
        if let path = request["path"] as? String {
            if let outcome = bridge.syncResult(path: path, args: request["args"]) {
                result = outcome.error.map { ["error": $0] } ?? ["value": outcome.value ?? NSNull()]
            } else {
                Log.write("unhandled sync bridge call \(path)")
                result = [:]
            }
        } else if let channel = request["channel"] as? String {
            result = ["value": bridge.invoke(channel: channel, args: request["args"]) ?? NSNull()]
        } else {
            result = ["error": "bad sync request"]
        }
        respond(task, url: url, payload: result)
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, payload: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        task.didReceive(URLResponse(url: url, mimeType: "application/json", expectedContentLength: body.count, textEncodingName: "utf-8"))
        task.didReceive(body)
        task.didFinish()
    }

    private static func mime(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "wasm": return "application/wasm"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "ico": return "image/x-icon"
        case "map": return "application/json"
        default: return "application/octet-stream"
        }
    }
}
