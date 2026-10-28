import SwiftUI
import WebKit

/// The official renderer is the app UI: it *is* Zalo PC's interface. The native
/// shell only hosts it and reports the page it is on.
struct RootView: View {
    @ObservedObject var state: ShellState
    let host: RendererHost

    var body: some View {
        VStack(spacing: 0) {
            RendererPane(host: host).id(state.rendererReady)
            statusBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let failure = state.failure {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(failure).font(.caption).lineLimit(2)
            } else {
                Text(state.page).font(.caption).foregroundStyle(.secondary)
                if !state.userName.isEmpty {
                    Text(state.userName).font(.caption)
                }
                if !state.conversations.isEmpty {
                    Text("\(state.conversations.count) hội thoại").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Đăng xuất") { host.signOut() }
                .font(.caption)
                .buttonStyle(.link)
                .disabled(state.page == "login")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

/// Hosts the renderer's WKWebView inside SwiftUI; the view is created by
/// `RendererHost.start` before the first frame.
private struct RendererPane: NSViewRepresentable {
    let host: RendererHost

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        attach(into: container)
        return container
    }

    /// The web view is created later by `RendererHost.start`, so attachment happens
    /// on every update until it sticks.
    func updateNSView(_ view: NSView, context: Context) {
        attach(into: view)
    }

    private func attach(into container: NSView) {
        guard let web = host.view, web.superview !== container else { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
