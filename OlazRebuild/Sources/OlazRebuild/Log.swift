import Foundation

enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OlazRebuild", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("engine.log")
    }()

    private static let queue = DispatchQueue(label: "olaz.log")
    nonisolated(unsafe) private static var handle: FileHandle?

    static func start() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    static func write(_ line: String) {
        let stamped = "[\(Self.clock())] \(line)\n"
        queue.async {
            handle?.write(Data(stamped.utf8))
            FileHandle.standardError.write(Data(stamped.utf8))
        }
    }

    private static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
