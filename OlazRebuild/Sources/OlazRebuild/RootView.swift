import SwiftUI
import WebKit

/// Native shell over the hidden official renderer: the adapters push state into
/// `ShellState`, the views call back into the page through `RendererHost.run`.
struct RootView: View {
    @ObservedObject var state: ShellState
    let host: RendererHost

    var body: some View {
        ZStack {
            RendererPane(host: host).id(state.rendererReady)
            Group {
                if state.page == "main" {
                    MainView(state: state, host: host)
                } else {
                    LoginView(state: state, host: host)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

/// The official QR login, drawn from the login page snapshot (state-adapter.js).
private struct LoginView: View {
    @ObservedObject var state: ShellState
    let host: RendererHost

    var body: some View {
        VStack(spacing: 18) {
            Text("Đăng nhập Zalo").font(.title2.bold())
            ZStack {
                if let qr = state.login?.qr, let image = Self.image(dataURL: qr) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .opacity(state.login?.invalid == true ? 0.25 : 1)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 240, height: 240)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))

            Text(state.login?.text ?? "Đang tải mã QR…")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            HStack {
                // The official page's own buttons ("Lấy mã mới", …), clicked inside the renderer.
                ForEach(state.login?.buttons ?? [], id: \.self) { label in
                    Button(label) {
                        Task { await host.run("return window.__zaloLoginAction(label)", ["label": label]) }
                    }
                }
            }
            if let failure = state.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
        .padding(32)
    }

    static func image(dataURL: String) -> NSImage? {
        guard let comma = dataURL.firstIndex(of: ","), dataURL.hasPrefix("data:") else { return nil }
        let header = dataURL[..<comma]
        let payload = String(dataURL[dataURL.index(after: comma)...])
        let data = header.hasSuffix(";base64")
            ? Data(base64Encoded: payload)
            : payload.removingPercentEncoding.map { Data($0.utf8) }
        return data.flatMap(NSImage.init(data:))
    }
}

/// Hosts the renderer's WKWebView inside SwiftUI; the view is created by
/// `RendererHost.start` before the first frame.
private struct RendererPane: NSViewRepresentable {
    let host: RendererHost

    func makeNSView(context: Context) -> NSView {
        let container = PassthroughView()
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

/// SwiftUI draws into layers, so AppKit hit-testing would hand clicks (and with them
/// keyboard focus) to the invisible renderer underneath. It never takes input.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
