import Testing
import Foundation
@testable import MacVolumeMixer

// Swift Testing (not XCTest) is used here deliberately: it ships with the
// Swift toolchain itself (no Xcode.app required), so `swift test` works from
// a bare Command Line Tools install — the same environment this whole
// project was built and verified in. XCTest remains available too if you
// open this package in Xcode.

private func makeStore() -> VolumeStore {
    let suiteName = "MacVolumeMixerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return VolumeStore(defaults: defaults)
}

@Test func defaultVolumeIsFullForUnseenApp() {
    let store = makeStore()
    #expect(store.volume(forBundleID: "com.example.unseen") == VolumeStore.defaultVolume)
    #expect(store.isMuted(forBundleID: "com.example.unseen") == false)
}

@Test func volumeAndMutePersistPerBundleID() {
    let store = makeStore()
    store.setVolume(0.35, forBundleID: "com.spotify.client")
    store.setVolume(0.8, forBundleID: "com.google.Chrome")
    store.setMuted(true, forBundleID: "com.hnc.Discord")

    #expect(store.volume(forBundleID: "com.spotify.client") == 0.35)
    #expect(store.volume(forBundleID: "com.google.Chrome") == 0.8)
    #expect(store.isMuted(forBundleID: "com.hnc.Discord") == true)
    // Untouched apps stay independent.
    #expect(store.isMuted(forBundleID: "com.spotify.client") == false)
}

@Test func muteDoesNotChangeStoredVolume() {
    let store = makeStore()
    store.setVolume(0.65, forBundleID: "com.spotify.client")
    store.setMuted(true, forBundleID: "com.spotify.client")
    store.setMuted(false, forBundleID: "com.spotify.client")

    #expect(store.volume(forBundleID: "com.spotify.client") == 0.65)
}

@Test func effectiveGainIsZeroWhenMutedButVolumeIsUnchanged() {
    var app = AudioAppProcess(
        bundleID: "com.spotify.client",
        displayName: "Spotify",
        icon: nil,
        primaryPID: 1234,
        underlyingProcessObjectIDs: [],
        isPlayingAudio: true,
        volume: 0.65,
        isMuted: false
    )
    #expect(app.effectiveGain == 0.65)

    app.isMuted = true
    #expect(app.effectiveGain == 0)
    #expect(app.volume == 0.65) // muting never touches the stored volume
}
