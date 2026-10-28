import SwiftUI

/// Conversation list + chat, fed by state-adapter.js / chat-adapter.js.
struct MainView: View {
    @ObservedObject var state: ShellState
    let host: RendererHost
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            ConversationSidebar(state: state, selection: $selection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
                .toolbar {
                    ToolbarItem {
                        Button("Đăng xuất", systemImage: "rectangle.portrait.and.arrow.right") { host.signOut() }
                    }
                }
        } detail: {
            if let id = selection, let conversation = state.conversations.first(where: { $0.id == id }) {
                ChatView(conversation: conversation, state: state, host: host).id(id)
            } else {
                Text("Chọn một hội thoại để bắt đầu").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConversationSidebar: View {
    @ObservedObject var state: ShellState
    @Binding var selection: String?
    @State private var query = ""

    private var rows: [ShellState.Conversation] {
        state.conversations
            // "stranger_box" is the official pseudo-row for the stranger folder, not a chat.
            .filter { $0.id != "stranger_box" && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { ($0.pinned ? 1 : 0, $0.time) > ($1.pinned ? 1 : 0, $1.time) }
    }

    var body: some View {
        List(rows, selection: $selection) { conversation in
            ConversationRow(conversation: conversation).tag(conversation.id)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Tìm hội thoại")
        .overlay {
            if state.conversations.isEmpty { ProgressView("Đang tải hội thoại…") }
        }
        .navigationTitle(state.userName.isEmpty ? "Zalo" : state.userName)
    }
}

private struct ConversationRow: View {
    let conversation: ShellState.Conversation

    var body: some View {
        HStack(spacing: 10) {
            Avatar(url: conversation.avatar, name: conversation.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if conversation.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(conversation.name.isEmpty ? conversation.id : conversation.name)
                        .fontWeight(conversation.unread > 0 ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer()
                    Text(shortTime(conversation.time)).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(conversation.preview).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if conversation.unread > 0 {
                        Text(conversation.unread > 99 ? "99+" : "\(conversation.unread)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.red, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ChatView: View {
    let conversation: ShellState.Conversation
    @ObservedObject var state: ShellState
    let host: RendererHost
    @State private var draft = ""
    @State private var sendError: String?

    private var messages: [ShellState.Message] { state.chats[conversation.id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if state.hasMore[conversation.id] == true {
                            Button("Tải tin nhắn cũ hơn") {
                                Task { await host.run("return await window.__zaloChat.loadMore(id)", ["id": conversation.id]) }
                            }
                            .buttonStyle(.link)
                        }
                        ForEach(messages) { message in
                            MessageRow(message: message, showSender: conversation.isGroup).id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            Divider()
            composer
        }
        .navigationTitle(conversation.name)
        .task {
            await host.run("return await window.__zaloChat.open(id)", ["id": conversation.id])
            await host.run("return await window.__zaloChat.markRead(id)", ["id": conversation.id])
        }
        .onDisappear {
            let id = conversation.id
            Task { await host.run("return await window.__zaloChat.close(id)", ["id": id]) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sendError {
                Text(sendError).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .bottom) {
                TextField("Nhập tin nhắn", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "paperplane.fill") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        sendError = nil
        Task {
            // The composer's own send path inside the renderer (pending message, E2EE, retries).
            let result = await host.run("return await window.__zaloChat.sendText(id, text)", ["id": conversation.id, "text": text]) as? String
            if result != "sent" {
                sendError = "Chưa gửi được (\(result ?? "lỗi")). Thử lại nhé."
                if draft.isEmpty { draft = text }
            }
        }
    }
}

private struct MessageRow: View {
    let message: ShellState.Message
    let showSender: Bool

    var body: some View {
        switch message.kind {
        case "system", "notice":
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        default:
            HStack(alignment: .bottom, spacing: 6) {
                if message.isMine { Spacer(minLength: 60) }
                if !message.isMine && showSender {
                    Avatar(url: message.senderAvatar, name: message.senderName, size: 26)
                }
                VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
                    if showSender && !message.isMine && !message.senderName.isEmpty {
                        Text(message.senderName).font(.caption).foregroundStyle(.secondary)
                    }
                    bubble
                    Text(shortTime(message.date) + (message.isMine && message.status == "failed" ? " · lỗi" : ""))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !message.isMine { Spacer(minLength: 60) }
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quote = message.quote, !quote.isEmpty {
                Text(quote).font(.caption).lineLimit(2).opacity(0.75)
                    .padding(.leading, 6)
                    .overlay(alignment: .leading) { Rectangle().frame(width: 2).opacity(0.5) }
            }
            if let url = remoteURL(message.imageURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            // Non-text kinds without a caption carry a label like "[Hình ảnh]"; the image already says it.
            if message.kind == "recalled" {
                Text("Tin nhắn đã được thu hồi").italic()
            } else if !message.text.isEmpty, message.imageURL == nil || !message.text.hasPrefix("[") {
                Text(message.text).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(message.isMine ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(message.isMine ? Color.white : Color.primary)
    }
}

private struct Avatar: View {
    let url: String
    let name: String
    let size: CGFloat

    var body: some View {
        AsyncImage(url: remoteURL(url)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(name.prefix(1).uppercased())
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.25))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Zalo hands out protocol-relative CDN links; local pc-dist paths cannot be loaded natively.
private func remoteURL(_ raw: String?) -> URL? {
    guard let raw, !raw.isEmpty else { return nil }
    let absolute = raw.hasPrefix("//") ? "https:" + raw : raw
    guard absolute.hasPrefix("http") else { return nil }
    return URL(string: absolute)
}

private func shortTime(_ ms: Double) -> String {
    guard ms > 0 else { return "" }
    let date = Date(timeIntervalSince1970: ms / 1000)
    return Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(.dateTime.day().month(.twoDigits))
}
