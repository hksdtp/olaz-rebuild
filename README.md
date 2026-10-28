# Olaz rebuild — WKWebView host for the official Zalo PC renderer

Rebuilt from `Olaz-1.0.dmg` (Olaz 1.0, signed `app.olaz.mac`, Team 85632Z2M2Q).
The original is a Swift/AppKit shell (21.2 MB, 80 Swift files, ~309 types) that runs
the **official Zalo PC 26.10.20 Electron renderer** inside `WKWebView` and re-implements
the Electron preload bridge in Swift. This tree rebuilds that shell with the same
three-part split, ~1.7k lines of Swift.

## Evidence the design is derived from

| Observation | Source |
|---|---|
| `Olaz.app` = Swift app, no Electron framework, links AppKit/WebKit/AVKit | `inspect_desktop_application`, `otool -l`, 39 221 Swift symbols |
| Renderer payload is the official VNG bundle (`com.vng.zalo`, 26.10.20) staged at `~/Library/Application Support/Olaz/ZaloRuntime/current` | `Contents/Info.plist` of the staged runtime, `ElectronAsarIntegrity` |
| Renderer is served from a custom scheme `zalo-app://local/` out of `app.asar` | `__cstring` literals `zalo-app://local/index.html`, `login.html`, `Olaz.AsarSchemeHandler` |
| 450 preload members mapped to Electron IPC channels | `bridge-table.json` (shipped, generated from `main-dist/preload-render.js`) |
| Main-process side is Swift: `ZaloBridge.specScript()`, `ipcEmit`, `loadIPCTable` | Swift symbol table + `window.__zaloBridgeSpec = ` literal |
| Static members (`$zenv.isPreloaded`, `$znode.fs.constants`, …) come from `BridgeImplementation.swift` | 73 `$z…` registration strings in `__cstring` |
| Globals exposed to the page: 39 `$z*` names | `main-dist/preload-render.js` → `contextBridge.exposeInMainWorld` |
| Network is proxied through native URLSession (`znet`), WebSocket events pushed back | `network-shim.js` + `window.__zaloNet.socketEvent` literal |
| Sync bridge calls travel over a blocking XHR to `zalo-app://local/__olaz/bridge-sync` | `bridge.js` `callSync` + `/__olaz/bridge-sync` literal |
| Native shell state comes from adapters posting `{page:'login'|'main', …}` on `zstate` | `state-adapter.js` + `zstate` handler |

## Layout

```
Sources/OlazRebuild/
  OlazApp.swift          @main + AppDelegate: locate runtime, start host
  RuntimeInstaller.swift find Zalo.app (OLAZ_RUNTIME, Application Support, /Applications), verify com.vng.zalo
  AsarArchive.swift      Electron asar (pickle header + JSON index, unpacked/link entries)
  AsarSchemeHandler.swift zalo-app:// → asar files; also answers /__olaz/bridge-sync
  RendererHost.swift     WKWebView, user scripts, message handlers, entry-page choice
  ZaloBridge.swift       main-process emulation: spec, IPC invoke, $znode/$zelectron members
  NetworkProxy.swift     http(s) via URLSession (cookie jar), ws via URLSessionWebSocketTask
  ShellState.swift       snapshots pushed by the adapters
  RootView.swift         SwiftUI shell: QR login, renderer pane, sign-out
  SharedWorkerHost.swift second WKWebView running shared-worker.html; relays tasks
  ZaloCrypto.swift       $znode.crypto encrypt/decrypt (CryptoKit AES-GCM)
  Resources/dist/        Olaz host scripts + bridge-table.json, verbatim from the DMG
  Resources/             instrument.js (debug probes), members.json (recovered inventory)
```

## Run

```sh
OLAZ_RUNTIME="$HOME/Library/Application Support/Olaz/ZaloRuntime/current" \
  swift run OlazRebuild
```

Needs a Zalo PC runtime that Olaz already installed (or point `OLAZ_RUNTIME` at a
Zalo.app with `Contents/Resources/app.asar`). Debug: `OLAZ_PROBE=1`,
`OLAZ_TRACE_ASAR=1`, `OLAZ_TRACE_BRIDGE=1`, `OLAZ_TRACE_NET=1`, `OLAZ_TRACE_IPC=1`.
Log: `~/Library/Application Support/OlazRebuild/engine.log`.

## Verified (runtime, this machine)

- Renderer boots from `zalo-app://local/login.html`; webpack runtime attaches
  (`__zaloRequire`, 397 modules), splash hides, the official 512×512 QR renders.
- Real login traffic flows through the proxy:
  `getServerInfo` 200 (40 767 B) → `reqqr` 200 (30 127 B) →
  `qr-id.zaloapp.com/polling/qr/waiting` (long-poll, 408 on idle timeout).
- All 15 feature adapters inject without error; they self-skip off `index.html`.
- `setAppCookie` writes `zpw_sek` to zaloapp.com / zalo.me / chat.zalo.me;
  `notifyLoginSuccess` triggers the login → `index.html` swap.
- Dead/rejected session (server code 102) clears cookies and returns to login.
- `$zapp` / `$znode` members answer; sync bridge XHR round-trips in ~1 ms.
- Real QR login works: phone scan → server issues `zpw_sek`, authenticated
  APIs answer 200 (`getLoginInfo`, `usage-mycloud`, `getCloudViewerKey`).
- Shared worker page boots and registers its 26 task types.

## Status: NOT finished

After login the main page stays on "Đang đăng nhập..." with an empty Redux
`user` slice. Root cause traced, not fixed: `SecureLocalStorage` is never
initialised (`init(userId, UIN)` runs from the `Authenticating` lifecycle event,
which needs the session handed over by the main process — `new-session` /
DAL channels `db-client-connected`, `get-name-of-target-script-for-dal-channel-from-host`,
`fail-load-sqlite3` are not emulated yet). Native SwiftUI on top of the adapters
(option B) is blocked on this.

## Not rebuilt (out of scope, deliberately)

- Native chat UI (80 SwiftUI/AppKit files in the original). Here the renderer is
  shown directly instead — same product surface, no re-implementation.
- Native call helper (`ZaloCall`), screen capture (`ZaloCap`) spawn paths.
- Runtime download/install flow (`ZaloRuntimeInstaller`, VNG DMG fetch + signature check).
- SQLite host migration: the official renderer is told to stay on IndexedDB, as the
  original does ("db: migration to SQLite disabled (no SQLite backend in host)").
- `$znode` filesystem surface beyond the hot members (stat/readdir/mkdir/access/exists).
  Unknown members return `undefined` and log `unhandled …`.
