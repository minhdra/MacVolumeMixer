import Foundation

/// Persists per-app volume/mute across launches, keyed by bundle identifier
/// (never by PID — PIDs are reused across launches, per product requirement
/// #10). Lightweight `UserDefaults` storage, no database, as specified.
final class VolumeStore {
    private enum Keys {
        static let volumes = "com.adjustvolume.MacVolumeMixer.volumes"
        static let mutes = "com.adjustvolume.MacVolumeMixer.mutes"
    }

    private let defaults: UserDefaults
    private var volumesByBundleID: [String: Float]
    private var mutesByBundleID: [String: Bool]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.volumesByBundleID = (defaults.dictionary(forKey: Keys.volumes) as? [String: Float]) ?? [:]
        self.mutesByBundleID = (defaults.dictionary(forKey: Keys.mutes) as? [String: Bool]) ?? [:]
    }

    /// Default volume for an app we have never seen before.
    static let defaultVolume: Float = 1.0

    func volume(forBundleID bundleID: String) -> Float {
        volumesByBundleID[bundleID] ?? Self.defaultVolume
    }

    func isMuted(forBundleID bundleID: String) -> Bool {
        mutesByBundleID[bundleID] ?? false
    }

    func setVolume(_ volume: Float, forBundleID bundleID: String) {
        volumesByBundleID[bundleID] = volume
        defaults.set(volumesByBundleID, forKey: Keys.volumes)
    }

    func setMuted(_ muted: Bool, forBundleID bundleID: String) {
        mutesByBundleID[bundleID] = muted
        defaults.set(mutesByBundleID, forKey: Keys.mutes)
    }
}
