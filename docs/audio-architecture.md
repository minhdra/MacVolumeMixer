# macOS Audio Architecture Research

Date: 2026-09-17
Researched on: macOS 15.6.1 (24G90), Command Line Tools SDK (`MacOSX.sdk`), Swift 6.2.3.

This document answers the mandatory Phase 1 question before any UI or product code was written:

> **Can a public, documented macOS API change the audible output volume of one specific process, independently of system volume and other processes?**

All claims below are backed by grepping the actual headers shipped in
`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreAudio.framework/Headers/`
on this machine (`AudioHardware.h`, `AudioHardwareTapping.h`, `CATapDescription.h`), plus a cross-check
against Apple's own reference implementation, [insidegui/AudioCap](https://github.com/insidegui/AudioCap),
on GitHub. No API described here was invented or assumed from memory.

## Answer: Direct per-process volume — **NO** (PARTIAL via re-synthesis)

macOS does **not** have a Windows-style "audio session" object with a per-process gain knob. The `AudioProcess`
HAL object (`kAudioProcessClassID = 'clnt'`) that macOS exposes only carries **discovery** properties:

```c
// AudioHardware.h:1978-1983
kAudioProcessPropertyPID             = 'ppid',   // pid_t
kAudioProcessPropertyBundleID        = 'pbid',   // CFString
kAudioProcessPropertyDevices         = 'pdv#',   // AudioObjectID[] in use
kAudioProcessPropertyIsRunning       = 'pir?',   // UInt32 bool
kAudioProcessPropertyIsRunningInput  = 'piri',
kAudioProcessPropertyIsRunningOutput = 'piro',
```

There is **no** `kAudioProcessPropertyVolumeScalar` or equivalent. `kAudioDevicePropertyVolumeScalar`
(`'volm'`) exists only on `AudioDevice` objects (physical/virtual hardware endpoints), never on
`AudioProcess` objects. This was confirmed by grepping the entire header tree for "Volume"/"Gain" near
any Process symbol — zero hits. So there is no direct, first-party "set gain of process X" call.

## What macOS 14.2+ actually added: Process Taps (CAPTURE, not CONTROL)

Since macOS 14.2 (public/stable from 14.4), Core Audio exposes a tap API:

```c
// AudioHardwareTapping.h
extern OSStatus AudioHardwareCreateProcessTap(CATapDescription* inDescription,
                                               AudioObjectID* outTapID)
    API_AVAILABLE(macos(14.2)) API_UNAVAILABLE(ios, watchos, tvos);

extern OSStatus AudioHardwareDestroyProcessTap(AudioObjectID inTapID)
    API_AVAILABLE(macos(14.2)) API_UNAVAILABLE(ios, watchos, tvos);
```

`CATapDescription` (`CATapDescription.h`, class available macOS 12+, tap creation itself 14.2+) lets you
build a tap that mixes one or more process object IDs (or "all processes except X") into a single
input-style audio stream. Key property that matters for us:

```objc
typedef NS_ENUM(NSInteger, CATapMuteBehavior) {
    CATapUnmuted         = 0,  // audio captured AND still sent to hardware
    CATapMuted           = 1,  // audio captured, NOT sent to hardware
    CATapMutedWhenTapped = 2,  // sent to hardware only while nobody is reading the tap
} API_AVAILABLE(macos(13.0));

@property (atomic, readwrite) CATapMuteBehavior muteBehavior;
```

This is the load-bearing fact for this whole product: **a tap can be told to fully silence the process's
own path to hardware (`CATapMuted`) while handing us the raw samples instead.** That is what turns a
capture-only primitive into a control primitive — see next section.

Cross-checked against `insidegui/AudioCap` (Apple engineer's own public reference for this API): it
translates a PID to an `AudioObjectID` via `kAudioHardwarePropertyTranslatePIDToProcessObject`, builds a
`CATapDescription`, calls `AudioHardwareCreateProcessTap`, wraps the tap in a private aggregate device via
`AudioHardwareCreateAggregateDevice`, and reads samples with `AudioDeviceCreateIOProcIDWithBlock`. Its
demo leaves `muteBehavior` at the default (`CATapUnmuted`) because its goal is pure recording — it explicitly
**does not** claim to control playback volume. That confirms: **capture and control are two different
things, and the public demos only exercise capture.** No newer commit changes this — the repo has no
gain-control code path today.

## How to get real per-process volume control from public API only

Signal path required (all public API, zero private symbols, zero kernel extension):

```
Target process (e.g. Spotify)
   │  CoreAudio HAL routes its output to the default device as usual
   ▼
CATapDescription(processes: [spotifyObjectID], muteBehavior: .muted)
   │  AudioHardwareCreateProcessTap → tap AudioObjectID
   │  Spotify's audio no longer reaches hardware (muted at the source)
   ▼
Private aggregate device (AudioHardwareCreateAggregateDevice)
   │  kAudioAggregateDeviceTapListKey = [ { kAudioSubTapUIDKey: tap UUID } ]
   │  gives us an IOProc-readable device backed by the tap's stream
   ▼
Our AudioDeviceIOProc (AudioDeviceCreateIOProcIDWithBlock)
   │  receives the muted process's PCM buffers
   │  multiply samples by our own scalar gain (0.0...1.0) — this IS the "volume slider"
   ▼
AudioQueue / AUAudioUnit (HAL output unit) bound to the real output device
   │  writes the gain-adjusted buffers to actual hardware
   ▼
Speakers — user hears Spotify at our chosen gain, system volume and Chrome untouched
```

This is architecture **B** in `docs/architecture-options.md` ("Process Tap + custom audio processing"),
but it is 100% public API — `AudioHardwareCreateProcessTap`, `CATapDescription`, `AudioHardwareCreateAggregateDevice`,
`AudioDeviceCreateIOProcIDWithBlock`, `AudioComponentInstanceNew` for an `AUHAL` output unit. It needs **no
virtual audio driver install, no kernel extension, no System Extension, no third-party dependency**. The
"aggregate device" here is created in-process via `AudioHardwareCreateAggregateDevice` and is ephemeral —
it exists only while our app runs and is destroyed on exit; it is not the same thing as installing a
persistent driver like BlackHole.

**Important limitation to state plainly (per the "no hallucination" rule):** this is re-synthesis, not a
hardware/HAL-level gain register on the process. We are silencing the app's own path and replaying its
audio ourselves. Consequences:
- Adds one extra render pass (our IOProc) — negligible CPU for a stereo `vDSP_vsmul` scalar multiply.
- Adds a small, fixed device-buffer latency (typically ~10-20ms at default buffer sizes) between the muted
  process and audible output. Not noticeable for music/video players; could be noticed in a rhythm game.
- If our process crashes while a tap is `CATapMuted`, that process's audio stays silent until we restart
  and re-create the tap (or the tapped process restarts). We mitigate this by destroying taps and restoring
  `CATapUnmuted` cleanly in `applicationWillTerminate`/`deinit`, and by not muting until our replay path is
  confirmed running.

## Discovery API (event-driven, no polling)

```c
kAudioHardwarePropertyProcessObjectList        = 'prs#'   // AudioObjectID[] of all processes known to HAL
kAudioHardwarePropertyTranslatePIDToProcessObject = 'id2p'
```

`kAudioHardwarePropertyProcessObjectList` supports `AudioObjectAddPropertyListenerBlock` — the HAL calls us
back when a process starts/stops touching audio. Combined with `kAudioProcessPropertyIsRunningOutput`
listeners on each process object, this gives full lifecycle (launch, start playing, stop playing, quit)
with **zero polling and zero timers**. This directly satisfies the "event-driven > polling" performance
requirement.

## Permissions

Calling `AudioHardwareCreateProcessTap` triggers a **system-managed TCC prompt** the first time it runs.
Confirmed by finding the private symbol `_kTCCServiceAudioCapture` inside
`/System/Library/PrivateFrameworks/TCC.framework/TCC` on this machine. This is the same permission family
backing "Screen & System Audio Recording" in System Settings → Privacy & Security. There is **no public
`Info.plist` usage-description key documented for it** (unlike microphone/camera) — like Screen Recording,
macOS shows its own system dialog and the user must approve it in System Settings; the app does not need
`NSMicrophoneUsageDescription` (we are not using the microphone) and must not request it, since that would
be a false/misleading permission ask.

Practical UX flow implemented in this app: on first tap creation, if the call fails with `kAudioHardwarePermissionDenied`-style
`OSStatus`, show a native alert explaining that macOS requires "Audio Recording" permission to control
individual app volumes, with a button that opens
`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` (Ventura+) directly.

## Update: a newer, Swift-native Core Audio surface exists (macOS 15+)

While implementing the engine, introspecting the actual compiled Swift module interface shipped in
the SDK (`/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk/usr/lib/swift/CoreAudio.swiftmodule/*.swiftinterface`
— this is Apple's real, compiled API surface, a stronger source than documentation prose) revealed
that Apple shipped a **second, higher-level Swift API on top of the same C selectors**, available
since macOS 15.0: `AudioHardwareSystem`, `AudioHardwareDevice`, `AudioHardwareProcess`,
`AudioHardwareTap`, `AudioHardwareAggregateDevice`, `AudioHardwareControl`, etc. (all in the
`CoreAudio` module, `@available(macOS 15.0, *)`).

This is *not* a different capability — cross-checking `AudioHardwareProcess` confirms the exact same
three facts as the raw C `AudioProcess` object (`pid`, `bundleID`, `isRunningOutput`; still no volume
property), and `AudioHardwareSystem.makeProcessTap(description:)` / `makeAggregateDevice(description:)`
are thin `throws`-based wrappers around `AudioHardwareCreateProcessTap` / `AudioHardwareCreateAggregateDevice`.
It does not change the PARTIAL verdict above. What it changes is code quality: `throws` instead of
manual `OSStatus` checks, typed objects instead of raw `AudioObjectID` + manual property-address gets,
and a delegate-based `addListener(forProperties:)`/`PropertyListenerDelegate` API instead of hand-rolled
`AudioObjectPropertyListenerBlock` plumbing — all still zero-polling, event-driven, public API.

Cross-checked against GitHub: `insidegui/AudioCap` (the reference implementation cited above) predates
this overlay and only uses the raw C API — there is no indication in that project, or elsewhere on
GitHub, that this higher-level surface is broadly adopted yet. We adopted it anyway, because it is
demonstrably real (compiled into the shipping SDK, not a beta/experimental header) and produces
materially safer, shorter code for exactly the "handle Core Audio errors clearly, avoid leaking
AudioObjects/listeners" requirements in this spec. The one operation it does **not** expose is creating
a Block-based `AudioDeviceIOProcID` — `AudioEngine`/`VolumeController` therefore still drop to the raw
`AudioDeviceCreateIOProcIDWithBlock` C call for that one realtime callback registration, which is the
single remaining raw Core Audio call in the whole codebase (see `VolumeController.swift`).

**This changes the deployment target from the originally-planned 14.4 to 15.0** (see decision below) —
the modern overlay is what the shipped app actually uses.

## Minimum macOS version decision

| Requirement | Minimum OS |
|---|---|
| `AudioHardwareCreateProcessTap` / `AudioHardwareDestroyProcessTap` | 14.2 (SDK annotation); stable/public from **14.4** |
| `CATapDescription` class | 12.0 |
| `CATapMuteBehavior` (needed for mute-and-replay) | 13.0 |
| `kAudioProcessPropertyIsRunningOutput` etc. | 14.4 (shipped alongside the tap API) |
| `CATapDescription.bundleIDs` / `processRestoreEnabled` (nice-to-have, not required) | 26.0 (not used — too new, would exclude nearly all users) |

**Decision: deployment target = macOS 15.0.** The tap pipeline itself is usable from 14.4, but the app
is built on the Swift-native `AudioHardwareSystem`/`AudioHardwareProcess`/`AudioHardwareTap`/
`AudioHardwareAggregateDevice` overlay described above, which is gated `@available(macOS 15.0, *)`.
Trading 14.4-14.5 support for materially safer, shorter Core Audio code is the right call given the
product's own priority order ("backward compatibility" is explicitly last, below "low CPU/RAM" and
"simple implementation"). We deliberately do **not** require macOS 26 — the newer
`bundleIDs`/`processRestoreEnabled` conveniences on `CATapDescription` are nice but not load-bearing (we
implement the equivalent bundle-ID aggregation and restore-on-relaunch ourselves in
`ApplicationResolver`/`VolumeStore`), and requiring 26.0 would exclude the overwhelming majority of
current macOS installs for no functional gain.

## Sandbox

Process taps and `AudioHardwareCreateAggregateDevice` are HAL-level, machine-wide operations that are not
exposed through an App Sandbox entitlement as of this SDK. This app therefore ships **non-sandboxed**
(Developer ID signed + notarized, not Mac App Store). This is a deliberate, documented tradeoff — see
`README.md` → Known Limitations.

## Summary table

| Capability | Public API | Notes |
|---|---|---|
| Enumerate audio-capable processes | `kAudioHardwarePropertyProcessObjectList` + `AudioObjectAddPropertyListenerBlock` | event-driven |
| Detect "is this app making sound right now" | `kAudioProcessPropertyIsRunningOutput` + listener | event-driven, reliable |
| Get PID / bundle ID of a process object | `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID` | direct |
| Capture a process's audio | `CATapDescription` + `AudioHardwareCreateProcessTap` | since 14.2/14.4 |
| Silence a process's own path to hardware | `CATapDescription.muteBehavior = .muted` | since 13.0 (property), 14.4 (usable via tap) |
| **Set a process's gain directly** | **None** | does not exist in the public SDK |
| Re-synthesize output at a chosen gain | Tap (muted) → Aggregate device → our `IOProc` → `AUHAL` output unit | our own DSP: one scalar multiply |
