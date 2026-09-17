import CoreAudio
import Foundation

/// Facade that ties `AudioProcessMonitor` (discovery), `ApplicationResolver`
/// (grouping helpers under one logical app), `VolumeStore` (persistence) and
/// one `VolumeController` per actively-playing app together, and publishes
/// the result for the UI. Deliberately independent of SwiftUI/AppKit beyond
/// `ObservableObject` — the UI layer only ever reads `apps` and calls
/// `setVolume`/`setMuted`.
@MainActor
final class AudioEngine: ObservableObject {
    @Published private(set) var apps: [AudioAppProcess] = []
    @Published var lastError: String?
    @Published private(set) var outputDeviceName: String = "Unknown Output"

    private let system = AudioHardwareSystem.shared
    private let monitor = AudioProcessMonitor()
    private let volumeStore: VolumeStore
    private var controllers: [String: VolumeController] = [:]
    private var appsByID: [String: AudioAppProcess] = [:]

    init(volumeStore: VolumeStore = VolumeStore()) {
        self.volumeStore = volumeStore
    }

    func start() {
        monitor.delegate = self
        do {
            try monitor.start()
        } catch {
            lastError = "Could not start audio monitoring: \(error)"
        }
        refreshOutputDeviceName()
    }

    func stop() {
        monitor.stop()
        for controller in controllers.values { controller.stop() }
        controllers.removeAll()
    }

    func setVolume(_ volume: Float, forAppID id: String) {
        guard var app = appsByID[id] else { return }
        app.volume = volume
        appsByID[id] = app
        if let bundleID = app.bundleID { volumeStore.setVolume(volume, forBundleID: bundleID) }
        controllers[id]?.gain = app.effectiveGain
        publish()
    }

    func setMuted(_ muted: Bool, forAppID id: String) {
        guard var app = appsByID[id] else { return }
        app.isMuted = muted
        appsByID[id] = app
        if let bundleID = app.bundleID { volumeStore.setMuted(muted, forBundleID: bundleID) }
        controllers[id]?.gain = app.effectiveGain
        publish()
    }

    private func refreshOutputDeviceName() {
        outputDeviceName = (try? system.defaultOutputDevice?.name) ?? "Unknown Output"
    }

    private func publish() {
        apps = appsByID.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

extension AudioEngine: AudioProcessMonitorDelegate {
    func audioProcessMonitor(_ monitor: AudioProcessMonitor, didUpdate processes: [DiscoveredAudioProcess]) {
        refreshOutputDeviceName()

        // Group raw HAL process objects into logical applications.
        struct Group {
            var resolved: ApplicationResolver.Resolved
            var pid: pid_t
            var objectIDs: [AudioObjectID] = []
            var isRunningOutput = false
        }
        var groups: [String: Group] = [:]
        for process in processes {
            let resolved = ApplicationResolver.resolve(pid: process.pid, hintedBundleID: process.bundleID)
            guard let bundleID = resolved.bundleID else { continue } // skip bare daemons with no .app bundle
            groups[bundleID, default: Group(resolved: resolved, pid: process.pid)].objectIDs.append(process.objectID)
            if process.isRunningOutput { groups[bundleID]?.isRunningOutput = true }
        }

        // Drop any tracked app whose logical process group vanished entirely (app quit).
        for key in appsByID.keys where groups[key] == nil {
            controllers[key]?.stop()
            controllers[key] = nil
            appsByID[key] = nil
        }

        for (key, group) in groups {
            let alreadyKnown = appsByID[key] != nil
            // Only add a brand-new row once the app has actually produced audio at
            // least once — this is what keeps the mixer to "apps related to audio"
            // instead of every process, per the product requirement. Once known,
            // the row stays (e.g. between paused tracks) until the app quits.
            guard alreadyKnown || group.isRunningOutput else { continue }

            var app = appsByID[key] ?? AudioAppProcess(
                bundleID: group.resolved.bundleID,
                displayName: group.resolved.displayName,
                icon: group.resolved.icon,
                primaryPID: group.pid,
                underlyingProcessObjectIDs: [],
                isPlayingAudio: false,
                volume: volumeStore.volume(forBundleID: key),
                isMuted: volumeStore.isMuted(forBundleID: key)
            )
            app.underlyingProcessObjectIDs = group.objectIDs
            app.isPlayingAudio = group.isRunningOutput
            appsByID[key] = app

            if group.isRunningOutput {
                startControllerIfNeeded(forKey: key, app: app, objectIDs: group.objectIDs)
            } else if let controller = controllers[key] {
                controller.stop()
                controllers[key] = nil
            }
        }

        publish()
    }

    private func startControllerIfNeeded(forKey key: String, app: AudioAppProcess, objectIDs: [AudioObjectID]) {
        guard controllers[key] == nil else { return }
        guard let outputDevice = try? system.defaultOutputDevice else {
            lastError = "No default output device available."
            return
        }

        let controller = VolumeController(label: key)
        do {
            try controller.start(processObjectIDs: objectIDs, outputDevice: outputDevice, initialGain: app.effectiveGain)
            controllers[key] = controller
        } catch {
            lastError = "Could not control volume for \(app.displayName): \(error). macOS may be waiting for Audio Recording permission in System Settings > Privacy & Security."
        }
    }
}
