import CoreAudio
import CoreGraphics
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
    /// Whether macOS has granted "Screen & System Audio Recording" — the TCC
    /// category that gates process taps since macOS Sonoma. This is checked
    /// with the public `CGPreflightScreenCaptureAccess()` API (see
    /// `requestAudioCapturePermission()`), not inferred from a Core Audio
    /// error: without this permission, `AudioHardwareCreateProcessTap` still
    /// succeeds and still mutes the source process, but the tap silently
    /// delivers *zeroed* audio instead of throwing — so probing for an error
    /// after the fact would never catch it, and the user would just hear
    /// permanent silence with no explanation. Checking this gate up front,
    /// before ever muting anything, is what prevents that.
    @Published private(set) var permissionGranted: Bool = CGPreflightScreenCaptureAccess()
    /// True once we've observed permission go from not-granted to granted
    /// *within this running process*. macOS/coreaudiod appear to latch the
    /// authorization decision for a process's audio taps at the time it
    /// first attempts one — granting the permission from System Settings
    /// while MacVolumeMixer is already running does not reliably take effect
    /// until the app is quit and relaunched (the same "restart required"
    /// behavior documented for Screen Recording, which shares this TCC
    /// category). If we don't gate on this, the app would re-attempt muting
    /// with what `CGPreflightScreenCaptureAccess()` now reports as "granted"
    /// but still get silent audio back — the exact bug this flag prevents.
    @Published private(set) var needsRelaunchToUsePermission = false

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
        updatePermissionState(CGPreflightScreenCaptureAccess())
        do {
            try monitor.start()
        } catch {
            lastError = "Could not start audio monitoring: \(error)"
        }
        refreshOutputDeviceName()
    }

    /// Triggers the system permission prompt if it hasn't been decided yet.
    /// If the user already denied it once, macOS won't prompt again — this
    /// just re-reads the current state so the UI can tell the user to grant
    /// it manually in System Settings instead (see `SettingsView`).
    func requestAudioCapturePermission() {
        updatePermissionState(CGRequestScreenCaptureAccess())
    }

    private func updatePermissionState(_ granted: Bool) {
        if granted && !permissionGranted {
            // Permission just turned on partway through this process's
            // lifetime — see `needsRelaunchToUsePermission`'s doc comment.
            needsRelaunchToUsePermission = true
        }
        permissionGranted = granted
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

        // Gate on permission BEFORE muting anything. Muting the source
        // process happens the instant the tap is created, regardless of
        // whether we're authorized to receive its real audio back — without
        // this check we'd silence the app first and only find out we can't
        // actually replay it after the fact.
        updatePermissionState(CGPreflightScreenCaptureAccess())
        guard permissionGranted else {
            lastError = "MacVolumeMixer needs \"Screen & System Audio Recording\" permission before it can control \(app.displayName)'s volume. Open Settings to grant it."
            return
        }
        // Even though macOS now reports the permission as granted, if it
        // turned on partway through this run it likely won't actually work
        // until relaunch (see `needsRelaunchToUsePermission`) — attempting
        // the tap anyway would just reproduce the "muted but silent" bug.
        guard !needsRelaunchToUsePermission else {
            lastError = "Permission was just granted — restart MacVolumeMixer to use it for \(app.displayName)."
            return
        }

        guard let outputDevice = try? system.defaultOutputDevice else {
            lastError = "No default output device available."
            return
        }

        let controller = VolumeController(label: key)
        do {
            try controller.start(processObjectIDs: objectIDs, outputDevice: outputDevice, initialGain: app.effectiveGain)
            controllers[key] = controller
            watchForSilentFailure(key: key, controller: controller, displayName: app.displayName)
        } catch {
            lastError = "Could not control volume for \(app.displayName): \(error)."
        }
    }

    /// Guards against the render callback never firing at all (observed with
    /// multiple aggregate devices contending for the same physical output
    /// device) — a distinct failure mode from the permission gate above,
    /// since here the callback registration itself silently never runs. If
    /// nothing has arrived within a second, tear the controller down
    /// (unmuting its process) instead of leaving the app permanently
    /// silent with no visible explanation.
    private func watchForSilentFailure(key: String, controller: VolumeController, displayName: String) {
        Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, let controller, self.controllers[key] === controller else { return }
            guard !controller.hasReceivedAnyCallback else { return }
            controller.stop()
            self.controllers[key] = nil
            self.lastError = "Couldn't start audio for \(displayName) — try again, or quit and reopen MacVolumeMixer."
        }
    }
}
