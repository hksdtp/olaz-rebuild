# Olaz rebuild — WKWebView host for the official Zalo PC renderer

Rebuilt from `Olaz-1.0.dmg` (Olaz 1.0, signed `app.olaz.mac`, Team 85632Z2M2Q).
The original is a Swift/AppKit shell (21.2 MB, 80 Swift files, ~309 types) that runs
the **official Zalo PC 26.10.20 Electron renderer** inside `WKWebView` and re-implements
the Electron preload bridge in Swift. This tree rebuilds that shell with the same
three-part split, ~2.1k lines of Swift, plus a native SwiftUI chat UI on top of the
hidden renderer (the original's model).

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
  ShellState.swift       snapshots pushed by the adapters (user, conversations, chat, login)
  RootView.swift         hidden renderer + native QR login
  ChatViews.swift        native conversation list, chat, composer (calls window.__zaloChat)
  SharedWorkerHost.swift second WKWebView running shared-worker.html; relays tasks
  ZaloCrypto.swift       $znode.crypto encrypt/decrypt (CryptoKit AES-GCM)
  Resources/dist/        Olaz host scripts + bridge-table.json, verbatim from the DMG
  Resources/             instrument.js (debug probes), members.json (recovered inventory)
```

## Run

```sh
./build-app.sh                      # → "Olaz Rebuild.app" (release, ad-hoc signed)
open "Olaz Rebuild.app"
# or, for development:
cd OlazRebuild && swift run OlazRebuild
```

Needs a Zalo PC runtime that Olaz already installed at
`~/Library/Application Support/Olaz/ZaloRuntime/current` (or point `OLAZ_RUNTIME` at a
Zalo.app with `Contents/Resources/app.asar`). The app keeps its own Electron `userData`
in `~/Library/Application Support/OlazRebuild/ZaloData` and never touches the real Zalo
PC's `ZaloData`. Debug: `OLAZ_PROBE=1`, `OLAZ_TRACE_ASAR=1`, `OLAZ_TRACE_BRIDGE=1`,
`OLAZ_TRACE_NET=1`, `OLAZ_TRACE_IPC=1`. Log: `~/Library/Application Support/OlazRebuild/engine.log`.

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
- Logged-in main page fully boots: IndexedDB opens (`zdb_<uid>` v76 …), chat
  WebSocket handshakes and receives sync frames, conversations/friends/groups load.
- Native UI: conversation list with avatars, previews, unread badges; opening a chat
  shows its history (text and photos); sending a text from the native composer works
  (tested in "My Documents" only). The packaged .app boots to the native QR login.

## Fixes that unblocked the main page

- Chat WebSocket: `Origin: file://` (403 without it) and the session cookies attached to
  the handshake; socket events delivered as `socketEvent(id, type, payload)`; one
  `NetworkProxy` per web view (socket ids collide between the page and the worker).
- Own `userData` directory and `is-migrate-full-done` read from its `config.json`:
  faking `true` made the renderer drop IndexedDB and wait for a SQLite DAL host forever.
- electron-store lock made recursive (`writeStore` → `readStore` deadlocked the UI thread).
- Cookies set as domain cookies (`.zalo.me`), matching Electron's explicit `domain`.
- Renderer container never takes clicks or keyboard focus from the native UI.

## Not rebuilt (out of scope, deliberately)

- Most of the original's native surface: stickers, polls, reactions, media viewer,
  calls, contact management, group creation, labels, stranger folder, notifications
  UI. Their shipped adapters are injected (they load without errors) but have no
  native views here; only text, photo history and text sending do.
- Native call helper (`ZaloCall`), screen capture (`ZaloCap`) spawn paths.
- Runtime download/install flow (`ZaloRuntimeInstaller`, VNG DMG fetch + signature check).
- SQLite host migration: the official renderer is told to stay on IndexedDB, as the
  original does ("db: migration to SQLite disabled (no SQLite backend in host)").
- `$znode` filesystem surface beyond the hot members (stat/readdir/mkdir/access/exists).
  Unknown members return `undefined` and log `unhandled …`.
