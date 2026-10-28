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
    /// Messages per conversation id, oldest first (chat-adapter.js `chat` payloads).
    @Published var chats: [String: [Message]] = [:]
    @Published var hasMore: [String: Bool] = [:]

    struct LoginSnapshot {
        var qr: String?
        var text: String
        var invalid: Bool
        var avatar: String?
        var buttons: [String]
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

    struct Message: Identifiable, Equatable {
        let id: String
        var senderName: String
        var senderAvatar: String
        var isMine: Bool
        var text: String
        var date: Double
        var status: String
        var kind: String
        var imageURL: String?
        var quote: String?

        /// ChatMessageJSON, see the contract at the top of chat-adapter.js.
        init?(_ row: [String: Any]) {
            guard let id = row["id"].map({ "\($0)" }), !id.isEmpty else { return nil }
            let kind = row["kind"] as? [String: Any] ?? [:]
            self.id = id
            senderName = row["senderName"] as? String ?? ""
            senderAvatar = row["senderAvatar"] as? String ?? ""
            isMine = row["isMine"] as? Bool ?? false
            text = row["text"] as? String ?? ""
            date = (row["date"] as? Double) ?? 0
            status = row["status"] as? String ?? ""
            self.kind = kind["type"] as? String ?? "text"
            switch self.kind {
            case "photo", "sticker", "gif": imageURL = kind["url"] as? String
            case "video", "link", "location": imageURL = kind["thumbnail"] as? String
            default: imageURL = nil
            }
            if let quote = row["quote"] as? [String: Any] {
                self.quote = [quote["senderName"] as? String, quote["text"] as? String].compactMap { $0 }.joined(separator: ": ")
            }
        }
    }

    func apply(_ payload: [String: Any]) {
        guard let page = payload["page"] as? String else { return }
        self.page = page
        if let error = payload["error"] as? String { failure = error }

        switch page {
        case "login":
            // genFirstQR/genSecondQR events carry the raw QR object; the DOM snapshot is what we draw.
            guard payload["event"] == nil else { break }
            login = LoginSnapshot(
                qr: payload["qr"] as? String,
                text: payload["text"] as? String ?? "",
                invalid: payload["invalid"] as? Bool ?? false,
                avatar: payload["avatar"] as? String,
                buttons: payload["buttons"] as? [String] ?? []
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
            if let chat = payload["chat"] as? [String: Any] { applyChat(chat) }
        default:
            break
        }
    }

    /// reset = full list; otherwise merge changed messages by id and drop `removed`.
    private func applyChat(_ chat: [String: Any]) {
        guard let convId = chat["convId"].map({ "\($0)" }) else { return }
        var list = (chat["reset"] as? Bool ?? false) ? [] : chats[convId] ?? []
        let removed = Set((chat["removed"] as? [Any] ?? []).map { "\($0)" })
        list.removeAll { removed.contains($0.id) }
        for message in (chat["messages"] as? [[String: Any]] ?? []).compactMap(Message.init) {
            if let index = list.firstIndex(where: { $0.id == message.id }) {
                list[index] = message
            } else {
                list.append(message)
            }
        }
        list.sort { $0.date < $1.date }
        chats[convId] = list
        if let more = chat["hasMore"] as? Bool { hasMore[convId] = more }
    }
}
