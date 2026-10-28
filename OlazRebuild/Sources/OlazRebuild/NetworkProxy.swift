import Foundation
import WebKit

/// Plays the Electron renderer's network stack. `network-shim.js` posts every
/// http(s)/ws(s) request here because a WKWebView page cannot reach Zalo servers
/// cross-origin; URLSession does the real work and keeps the cookie jar.
final class NetworkProxy: NSObject, WKScriptMessageHandlerWithReply {
    private let session: URLSession
    private weak var webView: WKWebView?
    private var sockets: [Int: URLSessionWebSocketTask] = [:]
    private let lock = NSLock()

    override init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 60
        // main.js `webContents.setUserAgent("ZaloPC-" + platform + "-" + clientType + "v" + clientVersion)`.
        config.httpAdditionalHeaders = ["User-Agent": "ZaloPC-darwin-23v694"]
        session = URLSession(configuration: config)
        super.init()
    }

    func attach(webView: WKWebView) { self.webView = webView }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "bad network message")
            return
        }
        if ProcessInfo.processInfo.environment["OLAZ_TRACE_NET"] != nil {
            Log.write("net \(op) \(body["url"] as? String ?? body["id"].map { "ws#\($0)" } ?? "?")")
        }
        switch op {
        case "http":
            // URLSession answers off the main thread; the reply is main-actor bound.
            http(body) { payload in Task { @MainActor in replyHandler(payload, nil) } }
        case "ws.open": openSocket(body); replyHandler(nil, nil)
        case "ws.send": sendSocket(body); replyHandler(nil, nil)
        case "ws.close": closeSocket(body); replyHandler(nil, nil)
        default: replyHandler(nil, "unsupported op \(op)")
        }
    }

    // MARK: HTTP

    private func http(_ body: [String: Any], done: @escaping @Sendable (Any?) -> Void) {
        guard let raw = body["url"] as? String, let url = URL(string: raw) else {
            done(["error": "bad url"])
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = (body["method"] as? String) ?? "GET"
        for (key, value) in (body["headers"] as? [String: String]) ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let timeout = body["timeout"] as? Double, timeout > 0 {
            request.timeoutInterval = timeout / 1000
        }
        if let encoded = body["body"] as? [String: Any] {
            apply(encoded, to: &request)
        }

        session.dataTask(with: request) { data, response, error in
            if ProcessInfo.processInfo.environment["OLAZ_TRACE_NET"] != nil {
                Log.write("net <= \((response as? HTTPURLResponse)?.statusCode ?? -1) \(url.host ?? "")\(url.path) \(data?.count ?? 0)B \(error.map { "\($0)" } ?? "")")
            }
            guard let http = response as? HTTPURLResponse else {
                done(["error": error?.localizedDescription ?? "no response"])
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers["\(key)".lowercased()] = "\(value)"
            }
            done([
                "status": http.statusCode,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                "url": http.url?.absoluteString ?? raw,
                "headers": headers,
                "body": (data ?? Data()).base64EncodedString(),
            ])
        }.resume()
    }

    /// The shim encodes bodies as `{kind: text|base64|formdata, …}`.
    private func apply(_ encoded: [String: Any], to request: inout URLRequest) {
        switch encoded["kind"] as? String {
        case "text":
            let text = encoded["text"] as? String ?? ""
            request.httpBody = Data(text.utf8)
            if let type = encoded["contentType"] as? String {
                request.setValue(type, forHTTPHeaderField: "Content-Type")
            }
        case "base64":
            request.httpBody = Data(base64Encoded: encoded["data"] as? String ?? "")
            if let type = encoded["contentType"] as? String {
                request.setValue(type, forHTTPHeaderField: "Content-Type")
            }
        case "formdata":
            let boundary = "----OlazFormBoundary\(UInt32.random(in: 0..<UInt32.max))"
            var body = Data()
            for part in (encoded["parts"] as? [[String: Any]]) ?? [] {
                body.append(Data("--\(boundary)\r\n".utf8))
                let name = part["name"] as? String ?? "field"
                if let filename = part["filename"] as? String {
                    let type = part["type"] as? String ?? "application/octet-stream"
                    body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
                    body.append(Data("Content-Type: \(type)\r\n\r\n".utf8))
                    body.append(Data(base64Encoded: part["data"] as? String ?? "") ?? Data())
                } else {
                    body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
                    body.append(Data((part["value"] as? String ?? "").utf8))
                }
                body.append(Data("\r\n".utf8))
            }
            body.append(Data("--\(boundary)--\r\n".utf8))
            request.httpBody = body
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        default:
            break
        }
    }

    // MARK: WebSocket

    private func openSocket(_ body: [String: Any]) {
        guard let id = body["id"] as? Int, let raw = body["url"] as? String, let url = URL(string: raw) else { return }
        var request = URLRequest(url: url)
        if let protocols = body["protocols"] as? [String], !protocols.isEmpty {
            request.setValue(protocols.joined(separator: ","), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        // The Electron page lives at file://; the chat socket answers 403 without an Origin.
        request.setValue("file://", forHTTPHeaderField: "Origin")
        // URLSession leaves the cookie jar out of WebSocket handshakes; Electron sends zpw_sek.
        var cookieURL = URLComponents(url: url, resolvingAgainstBaseURL: false)
        cookieURL?.scheme = url.scheme == "ws" ? "http" : "https"
        if let lookup = cookieURL?.url, let cookies = HTTPCookieStorage.shared.cookies(for: lookup), !cookies.isEmpty {
            for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: key)
            }
        } else {
            Log.write("ws#\(id) no cookies for \(url.host ?? "")")
        }
        let task = session.webSocketTask(with: request)
        lock.lock(); sockets[id] = task; lock.unlock()
        task.resume()
        emit(["id": id, "type": "open", "payload": ["protocol": ""]])
        receive(id: id, task: task)
    }

    private func receive(id: Int, task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if ProcessInfo.processInfo.environment["OLAZ_TRACE_NET"] != nil {
                    Log.write(String("net ws#\(id) in \(message)".prefix(120)))
                }
                switch message {
                case .string(let text):
                    self.emit(["id": id, "type": "text", "payload": ["text": text]])
                case .data(let data):
                    self.emit(["id": id, "type": "binary", "payload": ["data": data.base64EncodedString()]])
                @unknown default:
                    break
                }
                self.receive(id: id, task: task)
            case .failure(let error):
                let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
                Log.write("ws#\(id) closed: \(error.localizedDescription) (http \(status))")
                self.emit(["id": id, "type": "close", "payload": ["code": 1006, "reason": "\(error)", "wasClean": false]])
                self.lock.lock(); self.sockets[id] = nil; self.lock.unlock()
            }
        }
    }

    private func sendSocket(_ body: [String: Any]) {
        guard let id = body["id"] as? Int else { return }
        lock.lock(); let task = sockets[id]; lock.unlock()
        guard let task else { return }
        if let text = body["text"] as? String {
            task.send(.string(text)) { _ in }
        } else if let data = Data(base64Encoded: body["data"] as? String ?? "") {
            task.send(.data(data)) { _ in }
        }
    }

    private func closeSocket(_ body: [String: Any]) {
        guard let id = body["id"] as? Int else { return }
        lock.lock(); let task = sockets.removeValue(forKey: id); lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        emit(["id": id, "type": "close", "payload": ["code": body["code"] as? Int ?? 1000, "wasClean": true]])
    }

    /// `window.__zaloNet.socketEvent(id, type, payload)`.
    private func emit(_ event: [String: Any]) {
        guard let id = event["id"] as? Int, let type = event["type"] as? String,
              let data = try? JSONSerialization.data(withJSONObject: event["payload"] ?? [:]) else { return }
        let script = "window.__zaloNet && window.__zaloNet.socketEvent(\(id), \"\(type)\", \(String(decoding: data, as: UTF8.self)))"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(script, completionHandler: nil)
        }
    }
}
