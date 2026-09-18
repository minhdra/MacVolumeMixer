import CoreAudio
import Foundation

/// Snapshot of one HAL audio process object, as reported by the monitor.
struct DiscoveredAudioProcess: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
}

@MainActor
protocol AudioProcessMonitorDelegate: AnyObject {
    /// Called whenever the set of HAL audio processes, or any of their
    /// isRunningOutput flags, changes. Always delivered on the main actor.
    func audioProcessMonitor(_ monitor: AudioProcessMonitor, didUpdate processes: [DiscoveredAudioProcess])
}

/// Discovers audio-capable processes and their play/stop state entirely
/// through Core Audio property listeners — no polling loop, no timer, per the
/// product's hard performance requirement ("event-driven > polling").
///
/// Two listener scopes are used:
///   - `kAudioHardwarePropertyProcessObjectList` on the system object: fires
///     when a process starts or stops touching the HAL at all (launch/quit,
///     or first/last time it opens an audio stream).
///   - `kAudioProcessPropertyIsRunningOutput` on each individual process
///     object: fires when that process starts/stops actually outputting
///     audio (e.g. a paused Spotify vs. a playing one).
@MainActor
final class AudioProcessMonitor: NSObject, PropertyListenerDelegate {
    weak var delegate: AudioProcessMonitorDelegate?

    private let system = AudioHardwareSystem.shared
    private var watchedProcesses: [AudioObjectID: (object: AudioHardwareProcess, listener: RunningStateListener)] = [:]
    private var started = false
    private var recoveryTimer: Timer?

    private static let processListAddress = PropertyAddress(kAudioHardwarePropertyProcessObjectList)
    private static let isRunningOutputAddress = PropertyAddress(kAudioProcessPropertyIsRunningOutput)

    func start() throws {
        guard !started else { return }
        started = true
        system.delegates.append(self)
        try system.addListener(forProperties: [Self.processListAddress])
        refreshWatchedProcessSet()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWatchedProcessSet() }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        try? system.removeListener(forProperties: [Self.processListAddress])
        system.delegates.removeAll { ($0 as AnyObject) === self }
        for (object, listener) in watchedProcesses.values {
            object.delegates.removeAll { ($0 as AnyObject) === listener }
            try? object.removeListener(forProperties: [Self.isRunningOutputAddress])
        }
        watchedProcesses.removeAll()
    }

    /// PropertyListenerDelegate is not actor-isolated (it can be invoked from
    /// whatever queue Core Audio dispatches on), so this hops to the main
    /// actor before touching any state. It fires only for the system-object
    /// registration (the process list changing); per-process listeners are
    /// handled by their own `RunningStateListener` instances below.
    nonisolated func propertiesChanged(properties: [AudioObjectPropertyAddress]) {
        Task { @MainActor [weak self] in
            self?.refreshWatchedProcessSet()
        }
    }

    private func refreshWatchedProcessSet() {
        let currentProcesses = (try? system.processes) ?? []
        let currentIDs = Set(currentProcesses.map(\.id))
        let previousIDs = Set(watchedProcesses.keys)

        for removedID in previousIDs.subtracting(currentIDs) {
            if let (object, listener) = watchedProcesses.removeValue(forKey: removedID) {
                object.delegates.removeAll { ($0 as AnyObject) === listener }
                try? object.removeListener(forProperties: [Self.isRunningOutputAddress])
            }
        }

        for process in currentProcesses where watchedProcesses[process.id] == nil {
            let listener = RunningStateListener { [weak self] in
                Task { @MainActor in self?.publishSnapshot() }
            }
            process.delegates.append(listener)
            try? process.addListener(forProperties: [Self.isRunningOutputAddress])
            watchedProcesses[process.id] = (process, listener)
        }

        publishSnapshot()
    }

    private func publishSnapshot() {
        let snapshot: [DiscoveredAudioProcess] = watchedProcesses.values.compactMap { object, _ in
            guard let pid = try? object.pid, pid > 0 else { return nil }
            let bundleID = try? object.bundleID
            let isRunningOutput = (try? object.isRunningOutput) ?? false
            return DiscoveredAudioProcess(objectID: object.id, pid: pid, bundleID: bundleID, isRunningOutput: isRunningOutput)
        }
        delegate?.audioProcessMonitor(self, didUpdate: snapshot)
    }
}

/// One tiny listener instance per watched process object. Each instance is
/// its own delegate registration, so `watchedProcesses` already tells us
/// which process object it belongs to — this class only needs to forward the
/// callback.
private final class RunningStateListener: NSObject, PropertyListenerDelegate {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func propertiesChanged(properties: [AudioObjectPropertyAddress]) {
        onChange()
    }
}
