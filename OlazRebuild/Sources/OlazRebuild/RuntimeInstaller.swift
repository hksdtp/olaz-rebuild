import Foundation

/// Locates an extracted Zalo PC runtime (the official Electron payload) and refuses
/// anything not signed by VNG (`com.vng.zalo`): the renderer is the whole product.
enum RuntimeInstaller {
    struct Runtime {
        let root: URL
        let asar: URL
        let helper: URL?
        let version: String?
        let platform: Platform
    }

    enum Platform: String {
        case arm64, x64
    }

    static func locate() throws -> Runtime {
        if let env = ProcessInfo.processInfo.environment["OLAZ_RUNTIME"], !env.isEmpty {
            return try load(URL(fileURLWithPath: env))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Olaz", isDirectory: true)
            .appendingPathComponent("ZaloRuntime/current", isDirectory: true)
        if FileManager.default.fileExists(atPath: support.path) { return try load(support) }
        let system = URL(fileURLWithPath: "/Applications/Zalo.app")
        if FileManager.default.fileExists(atPath: system.path) { return try load(system) }
        throw RuntimeError("Chưa có Zalo PC. Đặt OLAZ_RUNTIME=<Zalo.app> hoặc cài Zalo PC vào /Applications.")
    }

    private static func load(_ root: URL) throws -> Runtime {
        let asar = root.appendingPathComponent("Contents/Resources/app.asar")
        guard FileManager.default.fileExists(atPath: asar.path) else {
            throw RuntimeError("app.asar không có trong \(root.path)")
        }
        let plist = root.appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        } ?? nil
        if let bundleID = info?["CFBundleIdentifier"] as? String, bundleID != "com.vng.zalo" {
            throw RuntimeError("Bản Zalo này không phải của VNG (\(bundleID)).")
        }
        let helper = root.appendingPathComponent("Contents/ZaloHelper.app")
        return Runtime(
            root: root,
            asar: asar,
            helper: FileManager.default.fileExists(atPath: helper.path) ? helper : nil,
            version: info?["CFBundleShortVersionString"] as? String,
            platform: platform()
        )
    }

    /// The asar ships `darwin_x64` and `darwin_arm64` native libraries; pick by host.
    private static func platform() -> Platform {
        #if arch(arm64)
        return .arm64
        #else
        return .x64
        #endif
    }
}
