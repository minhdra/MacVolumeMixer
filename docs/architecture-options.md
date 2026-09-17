# Architecture Options for Per-App Volume Control

Per `docs/audio-architecture.md`: no public API sets gain on a process directly. Four candidate
architectures were compared before picking one. This app implements **Option B-minimal**.

## A. Native public API only (direct process gain)

Set a hypothetical `kAudioProcessPropertyVolumeScalar`.

- **Feasibility:** None. Property does not exist in the SDK (verified by grep, see audio-architecture.md).
- Rejected outright — nothing to implement.

## B. Process Tap + custom audio processing (chosen, minimal form)

`CATapDescription(muteBehavior: .muted)` → `AudioHardwareCreateProcessTap` → private
`AudioHardwareCreateAggregateDevice` wrapping the tap → our `AudioDeviceIOProc` applies a scalar gain →
`AUHAL` output unit writes to the real output device.

- **Feasibility:** Proven — all calls are public, present in the SDK, demonstrated capturable via
  `insidegui/AudioCap`; mute-and-replay is a documented property (`CATapMuteBehavior`) we compose ourselves.
- **CPU:** One extra render callback per tapped+active process, one `vDSP_vsmul` (vectorized scalar
  multiply) per buffer. On Apple Silicon this is single-digit-microsecond work per callback; no DSP graph,
  no resampling unless the tapped process and output device sample rates differ (rare — both are usually
  48kHz coordinated by the HAL).
- **RAM:** One aggregate device + one small ring/callback buffer per actively-muted process (typically a
  handful of KB, not seconds of audio — we never buffer more than \~2 IOProc cycles).
- **Latency:** One HAL IO cycle, typically 5-20ms depending on buffer size (`kAudioDevicePropertyBufferFrameSize`).
  Acceptable for music/video/chat; a rhythm/latency-critical game would notice it, but such an app is an
  edge case for a *volume mixer* product.
- **Installation complexity:** None beyond the app itself. No installer, no reboot, no separate driver
  process.
- **Permissions:** One system TCC prompt ("Audio Recording" / "Screen & System Audio Recording" family),
  granted once in System Settings, no admin password required.
- **Signing/notarization:** Standard Developer ID + notarization. No kernel extension entitlement, no
  System Extension approval dance (which requires a reboot-adjacent user flow and its own entitlement).
- **Reliability:** Tied to our process's lifetime — if we crash while a tap is muted, that one process goes
  silent until relaunch. Mitigated with clean shutdown handlers and a watchdog that un-mutes on
  `SIGTERM`/`applicationWillTerminate`; and by only muting after our replay `IOProc` is confirmed started
  (mute is the *last* step, unmute is the *first* step of teardown).
- **macOS compatibility:** the underlying tap pipeline needs 14.4+; this app targets **15.0+** because it
  is built on the Swift-native `AudioHardwareSystem` overlay layered on top of the same calls (see the
  "newer Swift-native surface" section in audio-architecture.md). Excludes Sonoma and earlier.

## C. Virtual Audio Device / Audio Server Plug-in (e.g. BlackHole-style, or our own)

Install a `.driver` bundle under `/Library/Audio/Plug-Ins/HAL/`, route all app audio to it, mix with
per-app gain in a driver-hosted mixer, output the mix to real hardware.

- **Feasibility:** Yes, this is what commercial mixers (Rogue Amoeba SoundSource/Loopback) effectively do
  with their own proprietary driver tech, predating the Tap API.
- **CPU/RAM:** Comparable to B once running, but the driver process (`coreaudiod` plug-in) is always
  loaded system-wide for **every** app using audio, not just the ones the user is actively mixing —
  higher baseline resident footprint and it persists across all apps/users on the machine, not just ours.
- **Installation complexity:** High. Requires a separate installer package running as root, writing to
  `/Library/Audio/Plug-Ins/HAL/`, and either a `coreaudiod` restart or full logout/login for the driver to
  load. Materially worse first-run UX than a system permission prompt.
- **Permissions:** Requires admin/root privileges for installation (`osascript ... with administrator
  privileges` or a `pkg` with postinstall scripts) — a much heavier ask than a TCC click-through.
- **Signing/notarization:** Needs a separate signing identity path for the driver bundle plus the app;
  Apple additionally expects HAL plug-ins distributed this way to be audited carefully since they load into
  every audio process on the system, not just ours.
- **Reliability:** A buggy driver can affect **all** system audio, not just our app's mixing — a crash or
  bad state here is a much bigger blast radius than architecture B, where a failure is scoped to the one
  process we tapped.
- **Compatibility:** Works further back (pre-14.4), which is its main advantage.
- **Verdict:** Rejected as first choice per the explicit product requirement to avoid virtual drivers unless
  Option B is provably impossible. It is not impossible — see above — so C is unnecessary complexity and
  risk for this product's target OS range.

## D. Other native alternatives considered

- **`AVAudioEngine`-only per-app sandboxing:** not applicable — `AVAudioEngine` controls *our own* audio
  graph, not another process's; no cross-process hook exists here.
- **AppleScript/Accessibility-driven "click the app's own volume control":** unreliable (most apps don't
  expose one), fragile (breaks on any UI change), and explicitly out of scope (`Không yêu cầu Accessibility
  nếu không cần`).
- **Private API (`AudioHardwareServiceHasProperty`-style undocumented process-gain selectors some
  jailbreak/tweak communities reference):** noted here only for completeness per the "document but do not
  ship" rule — **not used**, because private API is disallowed for this build.

## Decision

Ship **Option B, minimal form**: process tap (muted) + ephemeral private aggregate device + our own
single-scalar gain stage + AUHAL output. No virtual driver, no kernel/System Extension, no private API,
deployment target macOS 14.4+. This is the smallest architecture that satisfies "real audible per-app
volume control" per the priority order in the product spec (per-app volume working > stability > native
architecture > low CPU/RAM > ... > backward compatibility) — backward compatibility is explicitly the
lowest priority, so trading pre-14.4 support for a driver-free, low-risk, low-footprint architecture is the
correct tradeoff.
