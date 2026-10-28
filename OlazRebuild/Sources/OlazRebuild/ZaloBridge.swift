import Foundation
import WebKit

/// Plays the Electron **main process** for the official renderer: it answers the
/// preload bridge (`window.$z*`) that the Zalo renderer expects.
///
/// Flow (mirrors the original):
///   JS `post({kind,call|invoke|send|subscribe,path|channel,args})` → `zbridge`
///   → `dispatch` → reply value → JS `decode()`.
/// Unhandled members log `unhandled …` and answer `undefined`, so a new requirement
/// shows up in the log instead of killing the page.
final class ZaloBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let archive: AsarArchive
    private let table: [String: Any]
    private weak var webView: WKWebView?
    private let support: URL
    private let ipcHandlers = NSMutableDictionary()   // channel → JS handler (PROVIDE)
    private let lock = NSLock()

    init(archive: AsarArchive, table: [String: Any]) {
        self.archive = archive
        self.table = table
        // Own userData, like the original's Olaz/ZaloData: the real Zalo PC may be running on
        // ~/Library/Application Support/ZaloData, and its SQLite-migrated state is unusable here.
        self.support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OlazRebuild/ZaloData", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    var onLoginSuccess: (() -> Void)?
    private weak var worker: SharedWorkerHost?
    private weak var page: WKWebView?

    func attach(worker: SharedWorkerHost, page: WKWebView) {
        self.worker = worker
        self.page = page
    }
    var onSessionCleared: (() -> Void)?

    func attach(webView: WKWebView) { self.webView = webView }

    // MARK: spec

    /// `window.__zaloBridgeSpec`: the member/values/globals/ipc map the bridge
    /// script needs before it can build `window.$*`.
    func specScript() -> String {
        var ipc: [String: Any] = [:]
        var globals = Set<String>()
        for (path, value) in table {
            guard let entry = value as? [String: Any] else { continue }
            let channel = entry["channel"] as? String
            let type = entry["type"] as? String ?? "REQUEST"
            guard let channel else { continue }
            ipc[path] = ["channel": channel, "type": type]
            if let root = path.split(separator: ".").first { globals.insert(String(root)) }
        }
        // Static members the renderer reads synchronously must return real values,
        // otherwise the hybrid Proxy makes every `===` check truthy and the
        // renderer takes wrong branches.
        let values = Self.staticValues(archive: archive, support: support)
        globals.formUnion(Self.exposedGlobals())
        globals.formUnion(["$zsub", "$zpreload", "$zsqlite", "$zsqlitebw"])
        // Members the binary injects under namespaces absent from the IPC table
        // (`$znode.fs`, `$zenv`, `$zFileManager`) default to async round trips.
        var members: [String: String] = values.mapValues { _ in "value" }
        for path in Self.extraMembers() where members[path] == nil { members[path] = "async" }
        let spec: [String: Any] = [
            "members": members,
            "values": values,
            "globals": globals.sorted(),
            "ipc": ipc,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys])) ?? Data("{}".utf8)
        return "window.__zaloBridgeSpec = \(String(decoding: data, as: UTF8.self));"
    }

    /// Globals the official preload exposes via `contextBridge.exposeInMainWorld`.
    private static func exposedGlobals() -> [String] {
        inventory()["globals"] as? [String] ?? []
    }

    private static func inventory() -> [String: Any] {
        guard let url = resourceBundle.url(forResource: "members", withExtension: "json", subdirectory: "Resources"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root
    }

    /// Namespace members recovered from the binary's bridge registration strings.
    private static func extraMembers() -> [String] {
        guard let url = resourceBundle.url(forResource: "members", withExtension: "json", subdirectory: "Resources"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["members"] as? [String] else { return [] }
        return list
    }

    /// Cheap members the renderer reads synchronously during boot.
    private static func staticValues(archive: AsarArchive, support: URL) -> [String: Any] {
        let resources = archive.url.deletingLastPathComponent()
        return [
            "$zenv.isPreloaded": true,
            "$zenv.isRenderer": true,
            "$zenv.isMain": false,
            "$zelectron.storePath": support.appendingPathComponent("config.json").path,
            "$zapp.appPath": support.path,
            "$zapp.resourceDir": resources.path,
            "$zapp.version": "26.10.20",
            "$znode.fs.constants": ["F_OK": 0, "R_OK": 4, "W_OK": 2, "X_OK": 1],
            "$znode.os.__info": ["platform": "darwin", "arch": "arm64", "release": "26.0", "type": "Darwin"],
        ]
    }

    // MARK: WKScriptMessageHandlerWithReply

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        if ProcessInfo.processInfo.environment["OLAZ_TRACE_BRIDGE"] != nil {
            Log.write("zbridge raw \(type(of: message.body))")
        }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            replyHandler(nil, "bad bridge message")
            return
        }
        if ProcessInfo.processInfo.environment["OLAZ_TRACE_BRIDGE"] != nil {
            let label = body["path"] as? String ?? body["channel"] as? String ?? "?"
            let args = String(describing: body["args"] ?? []).prefix(90)
            Log.write("zbridge \(kind) \(label) \(args)")
        }
        switch kind {
        case "call":
            let path = body["path"] as? String ?? ""
            if let result = syncResult(path: path, args: body["args"]) {
                replyHandler(result.value, result.error)
            } else if let result = asyncResult(path: path, args: body["args"]) {
                replyHandler(result.value, result.error)
            } else {
                Log.write("unhandled async bridge call \(path)")
                replyHandler(nil, nil)
            }
        case "invoke":
            let channel = body["channel"] as? String ?? ""
            replyHandler(invoke(channel: channel, args: body["args"]), nil)
        case "send":
            let channel = body["channel"] as? String ?? ""
            _ = invoke(channel: channel, args: body["args"])
            replyHandler(nil, nil)
        case "subscribe":
            replyHandler(nil, nil)
        case "provide":
            let channel = body["channel"] as? String ?? ""
            lock.lock(); ipcHandlers[channel] = true; lock.unlock()
            replyHandler(nil, nil)
        default:
            replyHandler(nil, "bad bridge message")
        }
    }

    // MARK: dispatch

    struct Result {
        let value: Any?
        let error: String?
    }

    /// Both the async (`zbridge`) and sync (`zalo-app://local/__olaz/bridge-sync`)
    /// entries land here; nil means "no handler" so the caller can log it.
    func syncResult(path: String, args: Any?) -> Result? {
        switch path {
        case "$zelectron.storeRead":
            let name = firstString(args) ?? "config"
            return Result(value: Self.readStore(name: name, root: support), error: nil)
        case "$zelectron.storeWrite":
            let list = (args as? [Any]) ?? []
            let name = list.first as? String ?? "config"
            Self.writeStore(name: name, value: list.dropFirst().first as? [String: Any] ?? [:], root: support)
            return Result(value: nil, error: nil)
        case "$zelectron.storePath":
            let name = firstString(args) ?? "config"
            return Result(value: Self.storeURL(name: name, root: support).path, error: nil)
        case "$zelectron.getPathSync", "$zelectron.getPath":
            let name = (args as? [Any])?.first as? String ?? ""
            return Result(value: electronPath(name), error: nil)
        case "$zelectron.getAppPathSync", "$zelectron.getAppPath":
            return Result(value: support.path, error: nil)
        case "$zelectron.getAppVersion":
            return Result(value: "26.10.20", error: nil)
        case "$znode.fs.existsSync", "$znode.fsExtra.existsSync", "$znode.fsExtra.pathExists":
            guard let p = firstString(args) else { return Result(value: false, error: nil) }
            return Result(value: FileManager.default.fileExists(atPath: resolve(p)), error: nil)
        case "$znode.fs.accessSync":
            guard let p = firstString(args) else { return Result(value: nil, error: "EINVAL") }
            return FileManager.default.fileExists(atPath: resolve(p))
                ? Result(value: nil, error: nil)
                : Result(value: nil, error: "ENOENT: \(p)")
        case "$znode.fs.statSync", "$znode.fsExtra.statSync":
            guard let p = firstString(args), let attrs = try? FileManager.default.attributesOfItem(atPath: resolve(p)) else {
                return Result(value: nil, error: "ENOENT")
            }
            return Result(value: Self.statPayload(attrs), error: nil)
        case "$znode.fs.readdirSync":
            guard let p = firstString(args) else { return Result(value: [], error: nil) }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: resolve(p))) ?? []
            return Result(value: names, error: nil)
        case "$znode.fs.mkdirSync", "$znode.fsExtra.ensureDirSync":
            guard let p = firstString(args) else { return Result(value: nil, error: "EINVAL") }
            try? FileManager.default.createDirectory(atPath: resolve(p), withIntermediateDirectories: true)
            return Result(value: nil, error: nil)
        case "$znode.crypto.encrypt", "$znode.crypto.decrypt":
            let list = (args as? [Any]) ?? []
            return Result(value: ZaloCrypto.run(encrypt: path.hasSuffix("encrypt"), args: list), error: nil)
        case "$znode.crypto.randomBytes":
            let count = (args as? [Any])?.first as? Int ?? 16
            var bytes = [UInt8](repeating: 0, count: count)
            _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
            return Result(value: ["__bytes": Data(bytes).base64EncodedString()], error: nil)
        case "$zapp.getAppVisibilityStatus":
            return Result(value: webView?.window != nil, error: nil)
        default:
            if ProcessInfo.processInfo.environment["OLAZ_TRACE_BRIDGE"] != nil {
                Log.write("call \(path) \(String(describing: args).prefix(100))")
            }
            return nil
        }
    }

    /// Filesystem and log members the renderer uses on every start. Everything else
    /// stays unhandled so a new requirement is visible in the log.
    func asyncResult(path: String, args: Any?) -> Result? {
        let list = (args as? [Any]) ?? []
        switch path {
        case "$znode.fsExtra.ensureDir", "$znode.fs.mkdir":
            guard let p = list.first as? String else { return Result(value: nil, error: nil) }
            try? FileManager.default.createDirectory(atPath: resolve(p), withIntermediateDirectories: true)
            return Result(value: nil, error: nil)
        case "$znode.fs.writeFile", "$zFileManager.writeBufferToPath":
            guard let p = list.first as? String, let encoded = list.dropFirst().first as? [String: Any] else {
                return Result(value: nil, error: "EINVAL")
            }
            let bytes = Data(base64Encoded: encoded["__bytes"] as? String ?? "") ?? Data()
            try? FileManager.default.createDirectory(
                atPath: (resolve(p) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            do { try bytes.write(to: URL(fileURLWithPath: resolve(p))) } catch { return Result(value: nil, error: "\(error)") }
            return Result(value: nil, error: nil)
        case "$znode.fs.readFile", "$zFileManager.readFileAsync", "$zFileManager.getFileArrayBuffer":
            guard let p = list.first as? String, let data = try? Data(contentsOf: URL(fileURLWithPath: resolve(p))) else {
                return Result(value: nil, error: "ENOENT")
            }
            return Result(value: ["__bytes": data.base64EncodedString(), "__arraybuffer": true], error: nil)
        case "$zFileManager.getViewerkey":
            // The renderer stores the session viewer key here; main pushes it over
            // `receive-viewerkey`. Persist it so a restart keeps working.
            return Result(value: Self.readStore(name: "viewerkey", root: support)["key"] as? String ?? "", error: nil)
        case "$zFileManager.getSentryConfig":
            return Result(value: NSNull(), error: nil)
        case "$zFileManager.writeZLog", "$zFileManager.writeZLogBetween":
            return Result(value: true, error: nil)
        case "$zFileManager.readZLog", "$zFileManager.scandirLog":
            return Result(value: [], error: nil)
        case "$znode.fs.stat", "$znode.fsPromise.stat":
            guard let p = list.first as? String, let attrs = try? FileManager.default.attributesOfItem(atPath: resolve(p)) else {
                return Result(value: nil, error: "ENOENT")
            }
            return Result(value: Self.statPayload(attrs), error: nil)
        default:
            return nil
        }
    }

    func invoke(channel: String, args: Any?) -> Any? {
        switch channel {
        case "_electron_get-path":
            let name = (args as? [Any])?.first as? String ?? ""
            return electronPath(name)
        case "_electron_get-path-sync":
            let name = (args as? [Any])?.first as? String ?? ""
            return electronPath(name)
        case "_electron_get-app-version":
            return "26.10.20"
        case "_noti_is-supported":
            return true
        case "log", "log-ga":
            // The official renderer forwards console output as {channel:'log'} NOTIFY.
            Log.write("renderer \(describe(args))")
            return nil
        case "sqlite-available":
            return false
        case "is-migrate-full-done":
            // main.js `migrateFullyDone` = config.json `migrate_full_done`. Never fake `true`: the
            // renderer then treats IndexedDB as migrated, drops it and talks to a SQLite host.
            return Self.readStore(name: "config", root: support)["migrate_full_done"] as? Bool ?? false
        case "migratedb:check_need_wait_bu":
            return false
        case "get-migrate-local-info":
            return Self.readStore(name: "config", root: support)["major_version"].map { ["majorVersion": $0] } ?? [:]
        case "update-migrate-local-info", "dev-only-reset-migrate-state", "migratedb:signal_done", "migratedb:signal_restart":
            return nil
        case SharedWorkerHost.started:
            // main.js: register the worker window, then hand every task over.
            return worker != nil
        case SharedWorkerHost.run:
            worker?.runTask((args as? [Any]) ?? [])
            return nil
        case SharedWorkerHost.abort:
            worker?.abort((args as? [Any]) ?? [])
            return nil
        case "get-resource-dir":
            return archive.url.deletingLastPathComponent().path
        case "electron-store-get-data":
            return Self.storeData(support: support)
        case "_electron_set-app-cookie":
            // The renderer hands over `zpw_sek`; the official main process writes it to
            // zaloapp.com / zalo.me / chat.zalo.me (see main-dist/main.js setAppCookie).
            Self.storeAppCookie((args as? [Any])?.first as? String ?? "")
            return nil
        case "_electron_set-cookie":
            if let list = args as? [Any], list.count >= 5,
               let name = list[1] as? String, let value = list[2] as? String,
               let url = list[3] as? String, let domain = list[4] as? String {
                Self.setCookie(name: name, value: value, url: url, domain: domain, lifetime: 365 * 24 * 3600)
            }
            return nil
        case "_electron_clear-cookie":
            // Logout / dead session: drop the jar and let the host return to login.
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
            DispatchQueue.main.async { [weak self] in self?.onSessionCleared?() }
            return nil
        case "login-success":
            // The renderer writes `zpw_sek` first, then asks main to switch pages.
            DispatchQueue.main.async { [weak self] in self?.onLoginSuccess?() }
            return nil
        default:
            if ProcessInfo.processInfo.environment["OLAZ_TRACE_IPC"] != nil {
                Log.write("ipc \(channel) \(String(describing: args).prefix(120))")
            }
            return nil
        }
    }

    /// Electron's `app.getPath(name)` names the renderer asks for.
    private func electronPath(_ name: String) -> String {
        let fm = FileManager.default
        switch name {
        case "home": return NSHomeDirectory()
        case "userData", "appData": return support.path
        case "temp": return NSTemporaryDirectory()
        case "downloads":
            return fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        case "pictures":
            return fm.urls(for: .picturesDirectory, in: .userDomainMask)[0].path
        case "documents":
            return fm.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        case "logs":
            return support.appendingPathComponent("logs").path
        default:
            return support.path
        }
    }

    /// electron-store: one JSON file per store under Electron's `userData`.
    // Recursive: writeStore merges through readStore while holding it.
    private static let storeLock = NSRecursiveLock()

    static func storeURL(name: String, root: URL) -> URL {
        root.appendingPathComponent("\(name).json")
    }

    static func readStore(name: String, root: URL) -> [String: Any] {
        storeLock.lock(); defer { storeLock.unlock() }
        guard let data = try? Data(contentsOf: storeURL(name: name, root: root)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func writeStore(name: String, value: [String: Any], root: URL) {
        storeLock.lock(); defer { storeLock.unlock() }
        let url = storeURL(name: name, root: root)
        // Merge, like electron-store: a partial write keeps unrelated keys.
        var merged = readStore(name: name, root: root)
        for (key, new) in value { merged[key] = new }
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Renderer console lines arrive as a nested array; keep them readable.
    private func describe(_ args: Any?) -> String {
        guard let list = args as? [Any], let first = list.first else { return String(describing: args) }
        if let text = first as? String { return text }
        if let parts = first as? [Any] {
            return parts.map { $0 as? String ?? String(describing: $0) }.joined(separator: " ")
        }
        return String(describing: first)
    }

    /// `zpw_sek` is the Zalo web session; without it the main page cannot load.
    static func storeAppCookie(_ secret: String) {
        guard !secret.isEmpty else { return }
        for domain in ["zaloapp.com", "zalo.me", "chat.zalo.me"] {
            setCookie(name: "zpw_sek", value: secret, url: "https://\(domain)", domain: domain, lifetime: 7 * 24 * 3600, sameSite: true)
        }
        Log.write("app cookie stored (\(secret.count) chars)")
    }

    static func setCookie(name: String, value: String, url: String, domain: String, lifetime: TimeInterval, sameSite: Bool = false) {
        var fields: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            // Electron's explicit `domain` makes a domain cookie (ws*-msg.chat.zalo.me needs it);
            // Foundation only does that with the leading dot.
            .domain: domain.hasPrefix(".") ? domain : "." + domain,
            .path: "/",
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(lifetime),
        ]
        if sameSite { fields[HTTPCookiePropertyKey("SameSite")] = "None" }
        guard let cookie = HTTPCookie(properties: fields) else { return }
        HTTPCookieStorage.shared.setCookie(cookie)
    }

    static func storeData(support: URL) -> [String: Any] {
        let url = support.appendingPathComponent("config.json")
        return (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func firstString(_ args: Any?) -> String? {
        if let list = args as? [Any], let first = list.first as? String { return first }
        return args as? String
    }

    /// The renderer uses POSIX paths; anything relative resolves under userData.
    private func resolve(_ path: String) -> String {
        path.hasPrefix("/") ? path : support.appendingPathComponent(path).path
    }

    private static func statPayload(_ attrs: [FileAttributeKey: Any]) -> [String: Any] {
        let type = attrs[.type] as? FileAttributeType
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return [
            "size": size,
            "mode": 0o644,
            "mtimeMs": mtime * 1000,
            "ctimeMs": mtime * 1000,
            "atimeMs": mtime * 1000,
            "birthtimeMs": mtime * 1000,
            "isFile": type == .typeRegular,
            "isDirectory": type == .typeDirectory,
            "isSymbolicLink": type == .typeSymbolicLink,
        ]
    }

    // MARK: push (Swift → renderer)

    /// `webContents.send(channel, …)` equivalent: runs the renderer's listeners.
    func send(_ channel: String, _ args: [Any]) {
        let payload = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("[]".utf8)
        let script = "window.__zaloBridge && window.__zaloBridge.ipcEmit(\(jsString(channel)), \(String(decoding: payload, as: UTF8.self)))"
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    private func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())   // strips the wrapping [ ]
    }
}

import Security
