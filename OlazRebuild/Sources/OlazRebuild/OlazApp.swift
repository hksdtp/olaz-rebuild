import SwiftUI

@main
struct OlazApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView(state: delegate.state, host: delegate.host)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = ShellState()
    lazy var host = RendererHost(state: state)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.start()
        // A bare SwiftPM executable is not a regular app until told so: no key window, no Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        do {
            let runtime = try RuntimeInstaller.locate()
            Log.write("runtime \(runtime.version ?? "?") at \(runtime.asar.path)")
            try host.start(runtime: runtime)
        } catch {
            Log.write("host start failed: \(error)")
            state.failure = "\(error)"
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
