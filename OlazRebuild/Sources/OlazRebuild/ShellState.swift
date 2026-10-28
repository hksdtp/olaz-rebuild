import Foundation
import SwiftUI

/// Everything the native shell renders. The renderer stays hidden; adapters push
/// snapshots into this object over the `zstate` message handler.
@MainActor
final class ShellState: ObservableObject {
    @Published var page: String = "login"
    /// Bumped once the renderer exists so the shell can attach its web view.
    @Published var rendererReady = false
    @Published var failure: String?
    @Published var userName: String = ""
    @Published var login: LoginSnapshot?
    @Published var conversations: [Conversation] = []
    @Published var notification: [String: Any] = [:]

    struct LoginSnapshot {
        var qr: String?
        var text: String
        var invalid: Bool
        var avatar: String?
    }

    struct Conversation: Identifiable, Equatable {
        let id: String
        var name: String
        var avatar: String
        var isGroup: Bool
        var members: Int
        var unread: Int
        var pinned: Bool
        var preview: String
        var time: Double
    }

    func apply(_ payload: [String: Any]) {
        guard let page = payload["page"] as? String else { return }
        self.page = page
        if let error = payload["error"] as? String { failure = error }

        switch page {
        case "login":
            login = LoginSnapshot(
                qr: payload["qr"] as? String,
                text: payload["text"] as? String ?? "",
                invalid: payload["invalid"] as? Bool ?? false,
                avatar: payload["avatar"] as? String
            )
        case "main":
            if let user = payload["user"] as? [String: Any] {
                userName = user["displayName"] as? String ?? user["zaloName"] as? String ?? ""
            }
            if let rows = payload["conversations"] as? [[String: Any]] {
                conversations = rows.compactMap { row in
                    guard let id = row["id"] as? String else { return nil }
                    let preview = row["preview"] as? [String: Any]
                    return Conversation(
                        id: id,
                        name: row["name"] as? String ?? id,
                        avatar: row["avatar"] as? String ?? "",
                        isGroup: row["isGroup"] as? Bool ?? false,
                        members: row["members"] as? Int ?? 0,
                        unread: row["unread"] as? Int ?? 0,
                        pinned: row["pinned"] as? Bool ?? false,
                        preview: preview?["text"] as? String ?? "",
                        time: (preview?["ts"] as? Double) ?? 0
                    )
                }
            }
            if let note = payload["notification"] as? [String: Any] { notification = note }
        default:
            break
        }
    }
}
