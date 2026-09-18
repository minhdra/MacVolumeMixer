# MacVolumeMixer

A native macOS menu-bar app that gives every audio-producing app its own independent volume
slider and mute switch — without touching system volume or any other app's volume.

```
🔊  (menu bar icon)
┌────────────────────────────┐
│ Audio Mixer                │
│                             │
│ Chrome                     │
│ [────────●──] 80%   🔊     │
│                             │
│ Spotify                    │
│ [────●──────] 40%   🔊     │
│                             │
│ Discord                    │
│ [──●────────] 20%   🔇     │
│ ─────────────────────────  │
│ Output: MacBook Speakers   │
│ Settings…                  │
└────────────────────────────┘
```

> Muốn hiểu nhanh bối cảnh + cách triển khai bằng tiếng Việt trước khi đọc phần API chi tiết bên dưới?
> Xem [docs/TRIEN-KHAI.md](docs/TRIEN-KHAI.md).

## Requirements

- macOS **15.0 (Sequoia)** or later — see "Why 15.0" below.
- Xcode 16+ (to build/sign/notarize), or just the Swift toolchain (`swift build`) for development.
- No internet connection required at runtime. No accounts, no analytics, no cloud services.
  The one exception is the optional "Check for Updates" feature — see [Checking for updates](#checking-for-updates).

## Why this app needs macOS 15.0 (read this first)

macOS has **no public API to set the gain of one process directly** — there is no
`kAudioProcessPropertyVolumeScalar`. This was verified by inspecting the actual Core Audio headers
in the SDK, not assumed. Full research trail: **[docs/audio-architecture.md](docs/audio-architecture.md)**.

What macOS 14.2+/14.4+ *does* have is a **process tap** (`CATapDescription` +
`AudioHardwareCreateProcessTap`) that can capture a process's audio, and — critically — a mute-behavior
flag (`CATapMuteBehavior.muted`) that silences that process's own path to hardware while we capture it.
That combination — mute at the source, replay ourselves at a gain we choose — is what turns a
capture-only primitive into real, audible, per-app volume control. See
**[docs/architecture-options.md](docs/architecture-options.md)** for why this was chosen over a virtual
audio driver (Option C), which was explicitly avoided per the project's design constraints.

This app is built on top of a newer, Swift-native wrapper for that same mechanism
(`AudioHardwareSystem`/`AudioHardwareProcess`/`AudioHardwareTap`/`AudioHardwareAggregateDevice`,
found by inspecting the compiled `CoreAudio.swiftmodule` interface in the SDK), which ships
`@available(macOS 15.0, *)`. That is the actual reason the deployment target is 15.0 rather than 14.4 —
full reasoning in audio-architecture.md.

**No virtual audio driver, no kernel extension, no System Extension, and no private/undocumented API are
used anywhere in this project.**

## Architecture

```
App / AppDelegate.swift        NSApplication bootstrap, owns the status item + popover
MenuBar (AppKit)                NSStatusItem + NSPopover hosting a SwiftUI view (no MenuBarExtra
                                 scene/app life cycle overhead — see AppDelegate.swift doc comment)
Audio/
  AudioProcessMonitor.swift     Discovery: kAudioHardwarePropertyProcessObjectList +
                                 kAudioProcessPropertyIsRunningOutput listeners. Zero polling.
  VolumeController.swift        Per-app engine: tap (muted) → private aggregate device → our
                                 IOProc (scalar gain) → real output device. One raw Core Audio
                                 call (AudioDeviceCreateIOProcIDWithBlock); everything else uses
                                 the throws-based Swift overlay.
  AudioEngine.swift             Facade: owns the monitor + one VolumeController per actively
                                 playing app, publishes `[AudioAppProcess]` for the UI.
  OSStatusError.swift           OSStatus → readable four-char-code error, for the one raw call.
Models/
  AudioAppProcess.swift         One row = one logical application (helpers aggregated in).
Services/
  ApplicationResolver.swift     PID → owning .app bundle (outermost .app in the executable's
                                 path) → name/icon/bundle ID. This is what collapses "Chrome
                                 Helper (Renderer)" into just "Chrome".
  VolumeStore.swift              UserDefaults persistence keyed by bundle ID (never PID).
UI/
  MixerPopover.swift, AppVolumeRow.swift, SettingsView.swift    SwiftUI, system controls only.
```

No Clean-Architecture layering, no Redux, no DI framework, no event bus — one facade
(`AudioEngine`) between Core Audio and SwiftUI, per the project's own "don't over-engineer" constraint.

## Permissions

The **only** permission this app requests is macOS **System Audio Recording**. The bundle includes
Apple's required `NSAudioCaptureUsageDescription`; it does **not** request microphone access.

The audio path is deliberately fail-open. Apps at 100% volume use no tap. When a lower volume is
requested, capture starts unmuted and changes to `mutedWhenTapped` only after real PCM arrives. A denied
permission, zero-filled tap, failed callback, or stopped IOProc therefore leaves the app's original
audio path audible instead of silencing the Mac.

## Build & run

Two supported ways to build the exact same source tree:

1. **Command line** (fastest inner loop, what this project was developed and verified with):
   ```
   cd MacVolumeMixer
   swift build            # debug build
   swift run               # build + launch
   swift test              # unit tests (VolumeStore, AudioAppProcess) — Swift Testing, not XCTest
   ```
2. **Xcode**: `File → Open…` and pick `MacVolumeMixer/Package.swift` directly — Xcode treats a Swift
   package as a first-class project (Xcode 13+), giving you breakpoints, Instruments, and the standard
   Signing & Capabilities UI for Developer ID signing and notarization.

`Package.swift` embeds `Resources/Info.plist` into the built binary via a linker `-sectcreate`, so
`LSUIElement` (menu-bar-only, no Dock icon) and the bundle identifier take effect even from a bare
`swift build` binary, without hand-writing an `.xcodeproj`.

**Note on `.xcodeproj`:** this environment did not have a full Xcode install available (only Command
Line Tools), so a `.xcodeproj` file was not hand-generated — doing so without Xcode to validate it would
risk shipping a project file that silently fails to open or build, which would violate this project's own
"code must compile" requirement. Opening `Package.swift` in Xcode (above) is Apple's supported equivalent
and is what this project targets; if you specifically need a `.xcodeproj` for a downstream tool, open the
package in Xcode once and use *File → Save As Workspace*, or `File → New → Project` with an App target and
drag these `Sources/` files in.

## Building a release (.dmg / .zip)

`scripts/build-release.sh [VERSION]` produces both a `.zip` and a `.dmg` under `dist/`, plus a
`.sha256` checksum for each:

```
./scripts/build-release.sh 0.1.0
```

It does a real `swift build -c release`, assembles a proper `Contents/MacOS` + `Contents/Info.plist`
`.app` bundle (stamping `CFBundleShortVersionString`/`CFBundleVersion` with the version you pass), signs
it, then packages it. By default it **ad-hoc signs** (`CODESIGN_IDENTITY` unset → `-`), which needs no
Apple Developer account and runs fine on the machine that built it, but Gatekeeper shows "unidentified
developer" for anyone else downloading it (right-click → Open once gets past that). To produce a real
Developer ID build ready for wide distribution:

```
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARIZE=1 ./scripts/build-release.sh 0.1.0
```

`NOTARIZE=1` requires a notarytool keychain profile set up once via
`xcrun notarytool store-credentials MacVolumeMixer --apple-id <id> --team-id <team> --password <app-specific-password>`;
without a real Developer ID it's skipped automatically (Apple can't notarize ad-hoc-signed builds).

## Checking for updates

Settings has a **"Check for Updates…"** button and an **"Automatically check on launch"** toggle
(off by default). Both do exactly one thing: a single unauthenticated `GET` to
`https://api.github.com/repos/minhdra/MacVolumeMixer/releases/latest`, comparing its `tag_name` against
the running app's version (`UpdateChecker.swift`). No telemetry, no account, no data sent beyond the
`User-Agent` header GitHub's API requires. This is the **only** network call anywhere in the app, and it
only ever fires because the user pressed the button or explicitly opted into the launch check — the rest
of the product remains fully offline by design.

## Signing & notarization

Ships **non-sandboxed** (Developer ID, not Mac App Store) — process taps and
`AudioHardwareCreateAggregateDevice` are machine-wide HAL operations with no App Sandbox entitlement in
this SDK. For distribution: `Product → Archive` in Xcode, then Developer ID sign + notarize via
`xcrun notarytool submit` and staple, then distribute as a `.zip` or `.dmg`. No special entitlements are
needed beyond the app's own Developer ID identity — no kernel extension entitlement, no System Extension
approval flow.

## Troubleshooting

- **"All sound disappeared when I opened the app"**: this was a real bug in v0.1.0, fixed in v0.1.1 —
  the app was muting apps at the HAL before confirming it had permission to actually replay their audio
  (see "Permissions" above for why that combination is silent, not an error). Update to the latest
  release. If it's still happening, check whether the popover shows a "Grant Permission…" banner and
  click it; if macOS already denied the permission once, it won't prompt again — grant it manually via
  Settings → "Open Privacy & Security Settings…".
- **"I granted permission but it's still muted/silent"**: granting it while the app was already running
  isn't enough — see the callout in "Permissions" above. As of v0.1.2 the app detects this itself and
  shows a **"Restart Now"** button (popover and Settings) instead of trying and failing silently again;
  click it, or manually quit and reopen the app. This is the one case where you do need to restart
  MacVolumeMixer for something to take effect.
- **Quitting seems to leave it running**: also fixed in v0.1.1 — `applicationWillTerminate` now schedules
  an unconditional exit on a background timer as a fallback in case any cleanup call were to hang, so Quit
  can't get stuck. There's also a direct "Quit" button in the popover itself now (not just inside
  Settings) — this app has no Dock icon and no application menu bar (it's a menu-bar-only agent), so
  Cmd+Q doesn't apply to it.

## Known limitations

- **Deployment target is macOS 15.0+**, not further back — see "Why this app needs macOS 15.0" above.
- **~5-20ms of added latency** for a muted-and-replayed app, from the extra HAL IO cycle. Imperceptible
  for music/video/voice chat; would be noticeable in a latency-critical rhythm game.
- If **MacVolumeMixer itself crashes** while an app is tapped, that one app's audio stays silent (muted at
  the source) until MacVolumeMixer restarts or the tapped app itself restarts. Clean shutdown
  (`applicationWillTerminate` → `AudioEngine.stop()`) unmutes everything on normal quit.
- If a tapped app **spawns a brand-new helper process mid-playback** (not at launch), that new helper
  isn't automatically added to the already-running tap until the app's audio stops and restarts (tap
  membership is fixed at tap-creation time). Documented rather than solved with additional machinery, per
  the project's "don't over-engineer" constraint.
- **Volume changes apply only while the app is actively producing audio** — dragging the slider for an
  app that's currently silent/paused updates its stored volume (applied next time it plays) but there is
  no live tap to hear the change against, by design (no tap is kept open for silent apps, to avoid idle
  resource use).

## Performance characteristics

- **Idle** (menu bar running, no apps producing audio): one `NSStatusItem`, zero active taps, zero active
  aggregate devices, zero timers. All discovery is via Core Audio property listeners — CPU usage is
  effectively 0% between events.
- **Per actively-mixed app**: one process tap, one private/ephemeral aggregate device, one `IOProc`
  running a single vectorized scalar multiply (`vDSP_vsmul`) per audio buffer. No resampling, no DSP
  graph, no buffering beyond the HAL's own IO cycle.
- **Volume slider drags** apply immediately via a plain in-memory `Float` store into the render thread's
  gain cell — no throttling needed because there is no expensive call in the hot path (see the doc
  comment in `AppVolumeRow.swift`).

## Repository layout

```
MacVolumeMixer/            The app (SwiftPM package; open Package.swift in Xcode, or `swift build`)
Prototype/                 Phase 2 CLI proof-of-concept (audiomixctl) — see Prototype/README.md
scripts/
  build-release.sh          Builds + signs + packages a .zip and .dmg for a GitHub Release
docs/
  audio-architecture.md     Phase 1 research: what's possible with public API, and why
  architecture-options.md   Comparison of the 4 candidate architectures and why B was chosen
  TRIEN-KHAI.md              Vietnamese context/implementation walkthrough
README.md
LICENSE
```

## License

See [LICENSE](LICENSE).
