import Foundation

/// Reads the Electron `app.asar` container the official Zalo PC runtime ships:
/// 4-byte pickle header, 4-byte header size, header size bytes of JSON, then the payload.
/// File offsets in the JSON are relative to the byte after the header.
struct AsarArchive {
    struct Entry {
        let offset: Int
        let size: Int
        let unpacked: Bool
        let link: String?
    }

    let url: URL
    let payloadBase: Int
    private let index: [String: Entry]

    init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 16)
        guard head.count == 16, head[0] == 4 else { throw RuntimeError("app.asar không hợp lệ") }
        // Pickle: [4][header size][payload size][json bytes]. Payload starts after 8 + header size.
        let headerSize = Self.int32(head, 4)
        let jsonSize = Self.int32(head, 12)
        guard headerSize > 8, jsonSize > 1, 16 + jsonSize <= 8 + headerSize else {
            throw RuntimeError("app.asar không hợp lệ")
        }
        let json = handle.readData(ofLength: jsonSize)
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw RuntimeError("app.asar header không đọc được")
        }
        payloadBase = 8 + headerSize
        var flat: [String: Entry] = [:]
        Self.flatten(root, prefix: "", into: &flat)
        index = flat
    }

    private static func flatten(_ node: [String: Any], prefix: String, into out: inout [String: Entry]) {
        guard let files = node["files"] as? [String: Any] else { return }
        for (name, value) in files {
            guard let meta = value as? [String: Any] else { continue }
            let path = prefix + "/" + name
            if meta["files"] != nil {
                flatten(meta, prefix: path, into: &out)
                continue
            }
            out[path] = Entry(
                offset: (meta["offset"] as? String).flatMap(Int.init) ?? 0,
                size: (meta["size"] as? Int) ?? 0,
                unpacked: (meta["unpacked"] as? Bool) ?? false,
                link: meta["link"] as? String
            )
        }
    }

    func contains(_ path: String) -> Bool { index[Self.normalize(path)] != nil }

    func read(_ path: String) throws -> Data {
        guard let entry = index[Self.normalize(path)] else { throw RuntimeError("asar: không có \(path)") }
        if let link = entry.link { return try read(link) }
        if entry.unpacked {
            let unpacked = url.deletingLastPathComponent()
                .appendingPathComponent("app.asar.unpacked")
                .appendingPathComponent(String(Self.normalize(path).dropFirst()))
            return try Data(contentsOf: unpacked)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(payloadBase + entry.offset))
        return handle.readData(ofLength: entry.size)
    }

    var files: [String] { index.keys.sorted() }

    private static func normalize(_ path: String) -> String {
        var trimmed = path
        if !trimmed.hasPrefix("/") { trimmed = "/" + trimmed }
        while trimmed.contains("//") { trimmed = trimmed.replacingOccurrences(of: "//", with: "/") }
        return trimmed
    }

    private static func int32(_ data: Data, _ offset: Int) -> Int {
        let base = data.startIndex + offset
        return Int(data[base]) | Int(data[base + 1]) << 8 | Int(data[base + 2]) << 16 | Int(data[base + 3]) << 24
    }
}

struct RuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
