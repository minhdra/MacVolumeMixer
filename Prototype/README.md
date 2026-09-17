# audiomixctl — Phase 2 proof-of-concept

Small CLI that proves, with real Core Audio calls run on real hardware (not simulated), that this
project's chosen architecture — mute a process at the HAL, replay its audio ourselves at a chosen gain —
actually works, before any UI/product code was written.

## Build & run

```
swift build
./.build/debug/audiomixctl list
./.build/debug/audiomixctl set-volume <bundleID> <0.0-1.0> [durationSeconds]
```

## What was actually verified on this machine (macOS 15.6.1)

```
$ ./.build/debug/audiomixctl list
PID      BUNDLE ID                OBJID      AUDIO
...
2169     com.google.Chrome.helper 107        active
606      com.google.Chrome        109        inactive
...
```
Real, live output — `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningOutput`
correctly identify which process is actually making sound right now, with zero polling.

```
$ ./.build/debug/audiomixctl set-volume com.google.Chrome.helper 0.3 4
Muting com.google.Chrome.helper (pid 2169) at the HAL and replaying at gain 0.3 for 4.0s...
Running. System volume and other apps are untouched. Ctrl+C to stop early.
Stopped. com.google.Chrome.helper restored to normal (unmuted) playback.
```
Every Core Audio call (`AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`,
`AudioDeviceCreateIOProcIDWithBlock`, `AudioDeviceStart`/`Stop`, teardown) returned `noErr`. Chrome's tab
audio was muted at the source and replayed through the same physical output device at the requested
gain, for the requested duration, then cleanly restored — while system volume and every other app were
untouched throughout. This is the exact mechanism `MacVolumeMixer` uses in production
(`VolumeController.swift`), just without the UI/persistence/lifecycle layers around it.

## What this does NOT prove

- It doesn't prove a *direct* per-process gain API exists — it doesn't, see
  `../docs/audio-architecture.md`. This proves the mute-and-replay composition works.
- It's single-shot and single-app; the production app in `../MacVolumeMixer` adds continuous
  monitoring, multiple simultaneous apps, mute/unmute without losing the stored volume, and
  persistence across relaunches.
