# Window Ring

A menu-bar utility that replaces ⌘Tab/Dock/Mission Control with a **radial,
window-level** switcher: hold a shortcut, a ring of your open windows appears
centered on the mouse cursor, point at one, release to activate it. No click
required.

Every entry in the ring is an individual **window**, not an application — three
Safari windows show up as three separate ring entries.

## Requirements

- macOS 26 (Tahoe) — this is the only OS the project targets/was tested on.
- Xcode 26+.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to (re)generate `WindowRing.xcodeproj` from `project.yml`. The generated `.xcodeproj` is not checked in — run `xcodegen generate` once before opening the project, and again any time `project.yml` or the file layout changes.

## Build & run

```sh
brew install xcodegen   # if you don't already have it
cd radial
xcodegen generate
open WindowRing.xcodeproj
```

Build and run the `WindowRing` scheme (⌘R). The app has no Dock icon
(`LSUIElement`); look for its icon in the menu bar.

Or from the command line — pass `-derivedDataPath DerivedData` so the build
lands inside the project folder (`DerivedData/`, already gitignored) instead
of Xcode's global DerivedData cache:

```sh
xcodebuild -project WindowRing.xcodeproj -scheme WindowRing -configuration Debug -derivedDataPath DerivedData build
open DerivedData/Build/Products/Debug/WindowRing.app
```

## First run: granting Accessibility

On launch, Window Ring immediately requests **Accessibility** access. This is
the *only* permission it needs, and it's required for three specific things:

1. Reading window titles and minimized state via the Accessibility (AX) API.
2. Detecting the global shortcut's press-and-release via a `CGEventTap`.
3. Raising/activating the window you point at.

If you dismiss the prompt or need to grant it later: **System Settings →
Privacy & Security → Accessibility**, enable **WindowRing**. The app polls
`AXIsProcessTrusted()` every 2 seconds, so it starts working within a couple
of seconds of granting — no relaunch needed. Until granted, the app runs (menu
bar icon, Preferences) but the shortcut does nothing, and the settings window
shows an "Accessibility access required" banner with a button that deep-links
straight to that Settings pane.

Window Ring cannot run inside the App Sandbox — AX APIs and system-wide event
taps are unavailable to sandboxed processes — so it can't be Mac App
Store–distributed. That's an accepted tradeoff for a personal utility like
this, and the project is unsandboxed by design (no entitlements file at all).

## Using it

- **Hold Right Option (⌥)** anywhere — the ring appears at your cursor,
  showing your windows ordered most-recently-used first.
- **Move the mouse** in the direction of a window to highlight it (the
  highlighted item gets bigger, an accent ring, a shadow, and its full title).
- **Release** to activate the highlighted window — it unminimizes/unhides if
  needed, comes to the front, and macOS switches Spaces automatically if it's
  on another one.
- **Escape** cancels — nothing is activated, the ring disappears immediately.
- Releasing without moving the mouse activates the default selection (the
  most-recently-used window, ring position 0) rather than nothing — a "hold
  and instantly let go" tap behaves like a lightweight "last window" switch.
- If there are no eligible windows, nothing appears — the ring never flashes
  empty.

Holding the shortcut never interferes with ⌘Tab, Mission Control, or anything
else: the event tap is `.listenOnly` and never consumes or rewrites events.

## Changing the shortcut

Click the menu-bar icon → **Preferences…** → **Change…** next to the
shortcut, then press and release the modifier key(s) you want (e.g. hold
⌃⌥ together, then let go). The recorder only needs to see your own
Preferences window get the keystrokes — no extra permission beyond the
Accessibility grant above.

Preferences also let you:
- Include/exclude minimized windows.
- Include/exclude hidden applications.
- Set how many windows the ring shows at most (3–12).

Ordering policy is fixed to most-recently-used in this version (see
Architecture below for how to add more).

## Architecture

One Xcode app target, no third-party dependencies, SwiftUI app lifecycle +
AppKit/Core Graphics/Accessibility where SwiftUI alone isn't enough for
reliable global shortcut/overlay/window-activation behavior.

| File | Responsibility |
|---|---|
| `WindowRingApp.swift` / `AppDelegate.swift` | App entry point, `MenuBarExtra` status item, wires everything together, owns the Preferences window. |
| `WindowModel.swift` | `WindowInfo` (one window) and `WindowIdentity` (stable, hashable identity wrapping an `AXUIElement`). |
| `WindowDiscovery.swift` | Enumerates individual windows via the Accessibility API. |
| `WindowMRUTracker.swift` | Builds most-recently-focused-window history via `AXObserver`. |
| `WindowOrdering.swift` | `WindowOrderingPolicy` protocol; `MRUOrdering` is the only policy implemented. |
| `RadialLayout.swift` | Pure geometry: item placement around a circle, nearest-item hit-testing from a mouse point, global↔view coordinate conversion. No AppKit dependency. |
| `RadialOverlayWindow.swift` | Borderless, non-activating `NSPanel` that hosts the ring and handles Escape. |
| `RadialRingView.swift` | SwiftUI ring UI: translucent material, icon + title per window, selection styling. |
| `RingSessionState.swift` | Live per-session state (fixed window list/geometry, mutable selected index) driving the SwiftUI view. |
| `RingController.swift` | Orchestrates one press→point→release cycle end to end. |
| `GlobalShortcut.swift` | `CGEventTap`-based hold/release detector for a configurable set of modifier keys. |
| `WindowActivation.swift` | Un-minimize/un-hide/activate/raise sequence for the selected window. |
| `PermissionsManager.swift` | Accessibility-trust check, prompt, polling, and deep link to System Settings. |
| `Preferences.swift` / `PreferencesView.swift` | UserDefaults-backed settings + the settings window, including the shortcut recorder. |
| `VirtualKey.swift` | Hardcoded standard virtual keycodes for modifier keys + Escape (no Carbon import needed). |

## macOS APIs used, and why

- **Accessibility (AX) API** (`AXUIElementCreateApplication`,
  `AXUIElementCopyAttributeValue`, `AXUIElementPerformAction`, `AXObserver`)
  for window enumeration, titles, minimized state, raising, and MRU tracking.
  Chosen over `CGWindowListCopyWindowInfo` specifically to *avoid* needing
  Screen Recording permission — since Catalina, that CG API redacts window
  titles for other processes unless the caller has screen-recording access,
  while the AX API gives titles with just Accessibility trust.
- **`CGEventTap`** (session-level, `.listenOnly`) for detecting the global
  shortcut's press and release without ever consuming/rewriting events, so
  system shortcuts are never affected.
- **`NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)`** to track the
  cursor while the ring is shown — global *mouse* monitors, unlike global
  *keyboard* monitors, don't require Accessibility trust.
- **`NSRunningApplication`** for app icons, hidden/unhide, and app-level
  activation.
- **`NSPanel` with `.nonactivatingPanel`** for the overlay, so it can become
  key (to receive Escape locally) without activating Window Ring or stealing
  focus from whatever app was frontmost.
- **`NSScreen`** to find which display the cursor is on and clamp the ring
  inside that display's visible frame, handling multi-monitor setups and
  per-display scale factors (handled automatically by AppKit).

No private APIs are used anywhere. The one deliberately-scoped heuristic is
noted in `GlobalShortcut.swift`: distinguishing left vs. right modifier keys
combines a flagsChanged event's keycode with its (side-agnostic) CGEventFlags
mask — correct for the single-key-per-family combos the shortcut recorder
produces, with a documented edge case if both the left and right key of the
same family were somehow held at once (not reachable through the UI).

## Known macOS limitations

- **Space-switching on activation** depends on the user's own System Settings
  → Desktop & Dock → Mission Control setting "When switching to an
  application, switch to a Space with open windows." Window Ring just raises
  the window; if that setting is off, macOS may not switch Spaces
  automatically. This is standard system behavior, not a bug in Window Ring.
- **Some apps omit AX subrole/title data** (occasionally older
  Java/cross-platform toolkits), which can make a window's title fall back to
  just the app name.
- **Mac App Store distribution isn't possible** — App Sandbox is incompatible
  with the AX/event-tap APIs this app depends on.
- **A window with an empty AX title** shows its app's name instead so the
  ring is never confusing; app icon + partial title should usually be enough
  to tell windows apart at a glance regardless.
