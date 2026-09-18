import Foundation
import AppKit
import CoreAudio

/// One row in the mixer: a *logical application*, not a raw HAL process.
///
/// macOS exposes audio HAL "process" objects per Mach task — a single logical
/// app (Chrome, Discord) can own several of them (main process, GPU helper,
/// renderer helpers). `ApplicationResolver` collapses those into one
/// `AudioAppProcess` per bundle identifier so the UI never shows "Chrome
/// Helper (Renderer)" as its own mixer row (per product requirement #11).
struct AudioAppProcess: Identifiable, Equatable {
    /// Stable identity for the UI and for `VolumeStore` persistence.
    /// Bundle ID when we have one; falls back to "pid:<n>" for the rare
    /// audio-producing process with no bundle (e.g. a bare Mach-O daemon).
    var id: String { bundleID ?? "pid:\(primaryPID)" }

    /// Bundle identifier, when the process belongs to a bundled app.
    let bundleID: String?

    /// Human-readable name shown in the mixer row.
    let displayName: String

    /// App icon, resolved via NSWorkspace/NSRunningApplication.
    let icon: NSImage?

    /// The primary (first-seen) PID for this logical application — used only
    /// for display/debugging. Never persisted as identity (PIDs are reused
    /// across launches, per product requirement #10).
    let primaryPID: pid_t

    /// Every underlying HAL process object ID currently backing this logical
    /// application (main + helpers). Volume/mute apply to all of them.
    var underlyingProcessObjectIDs: [AudioObjectID]

    /// True if the HAL reports active output on any underlying process.
    var isPlayingAudio: Bool

    /// Current volume, 0...1. This is the *unmuted* volume — muting does not
    /// change this value (product requirement #9).
    var volume: Float

    /// Mute state. Effective audible gain is `isMuted ? 0 : volume`.
    var isMuted: Bool

    var effectiveGain: Float { isMuted ? 0 : volume }

    /// At full volume there is no reason to intercept the app's audio.
    var needsVolumeProcessing: Bool { isMuted || volume < 0.999 }

    /// Keep real media players in the primary view even while paused. Other
    /// apps only enter it while Core Audio reports active output; notification
    /// and utility clients fall back to the More view afterward.
    var belongsInMediaSection: Bool {
        if isPlayingAudio { return true }
        guard let bundleID else { return false }
        let mediaBundleIDs = [
            "com.apple.Music",
            "com.apple.Podcasts",
            "com.apple.TV",
            "com.spotify.client",
            "org.videolan.vlc",
            "com.colliderli.iina"
        ]
        return mediaBundleIDs.contains(bundleID)
    }
}
