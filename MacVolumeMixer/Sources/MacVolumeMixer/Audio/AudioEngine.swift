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
    enum CapturePermissionState {
        case notVerified
        case requesting
        case granted
        case needsPermission
    }

    @Published private(set) var apps: [AudioAppProcess] = []
    @Published var lastError: String?
    @Published private(set) var outputDeviceName: String = "Unknown Output"
    @Published private(set) var capturePermissionState: CapturePermissionState = .notVerified
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
        reconcileController(forKey: id, app: app)
        publish()
    }

    func setMuted(_ muted: Bool, forAppID id: String) {
        guard var app = appsByID[id] else { return }
        app.isMuted = muted
        appsByID[id] = app
        if let bundleID = app.bundleID { volumeStore.setMuted(muted, forBundleID: bundleID) }
        controllers[id]?.gain = app.effectiveGain
        reconcileController(forKey: id, app: app)
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
            guard let bundleID = resolved.bundleID,
                  resolved.isUserFacing,
                  bundleID != Bundle.main.bundleIdentifier
            else { continue }
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
            // A HAL process object already means the app has opened an audio
            // client. Do not require isRunningOutput here: Music and apps that
            // render through helpers can report that flag late or on another
            // process. System/background clients were filtered above.
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

            if group.isRunningOutput && app.needsVolumeProcessing {
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

        capturePermissionState = .requesting
        let controller = VolumeController(label: key) { [weak self] in
            self?.capturePermissionState = .granted
            self?.lastError = nil
        }
        do {
            try controller.start(processObjectIDs: objectIDs, outputDevice: outputDevice, initialGain: app.effectiveGain)
            controllers[key] = controller
            watchForSilentFailure(key: key, controller: controller, displayName: app.displayName)
        } catch {
            capturePermissionState = .needsPermission
            lastError = "Could not control volume for \(app.displayName): \(error)."
        }
    }

    private func reconcileController(forKey key: String, app: AudioAppProcess) {
        guard app.isPlayingAudio else { return }
        if app.needsVolumeProcessing {
            startControllerIfNeeded(forKey: key, app: app, objectIDs: app.underlyingProcessObjectIDs)
        } else {
            controllers[key]?.stop()
            controllers[key] = nil
        }
    }

    /// Guards against the render callback never firing at all (observed with
    /// multiple aggregate devices contending for the same physical output
    /// device). If
    /// nothing has arrived within a second, tear the controller down
    /// (unmuting its process) instead of leaving the app permanently
    /// silent with no visible explanation.
    private func watchForSilentFailure(key: String, controller: VolumeController, displayName: String) {
        Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, let controller, self.controllers[key] === controller else { return }
            guard !controller.hasReceivedAnyCallback else {
                if !controller.hasReceivedAudibleAudio {
                    self.capturePermissionState = .needsPermission
                }
                return
            }
            controller.stop()
            self.controllers[key] = nil
            self.capturePermissionState = .needsPermission
            self.lastError = "Couldn't start audio for \(displayName) — try again, or quit and reopen MacVolumeMixer."
        }
    }
}
