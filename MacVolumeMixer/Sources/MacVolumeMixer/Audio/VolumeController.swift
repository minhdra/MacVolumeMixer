import CoreAudio
import AudioToolbox
import Accelerate
import Foundation

/// Owns the full "mute at the HAL, replay at our own gain" pipeline for one
/// logical application (which may span several underlying HAL process
/// objects — see `AudioAppProcess.underlyingProcessObjectIDs`).
///
/// Signal path (see docs/audio-architecture.md for why this is the smallest
/// architecture that gives *real* per-app volume with only public API):
///
///     tapped processes --(CATapDescription, muteBehavior = .muted)-->
///     process tap --(wrapped in a private, ephemeral aggregate device
///     together with the real output device)--> our AudioDeviceIOProc
///     (scales samples by `gain`) --> real output device
///
/// One `VolumeController` per active, tapped logical application. Cleanup is
/// idempotent and safe to call multiple times (deinit calls it too), which is
/// what keeps this leak-free: no dangling AudioObjectIDs, no un-Block_copy'd
/// IOProc, no tap left muted after we stop owning it.
final class VolumeController {
    private let system = AudioHardwareSystem.shared
    private let label: String

    private var tap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private let gainStorage = AtomicFloat(1.0)

    /// 0...1 scalar applied to every sample on every render callback. Safe to
    /// set from the main actor while audio is running — the render callback
    /// reads it through a lock-free atomic, never blocking the realtime
    /// thread (Core Audio's realtime constraints forbid taking a lock there).
    var gain: Float {
        get { gainStorage.load() }
        set { gainStorage.store(max(0, min(1, newValue))) }
    }

    private(set) var isRunning = false

    init(label: String) {
        self.label = label
    }

    func start(processObjectIDs: [AudioObjectID], outputDevice: AudioHardwareDevice, initialGain: Float) throws {
        guard !isRunning else { return }
        gain = initialGain

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.muteBehavior = .muted
        description.isPrivate = true
        description.name = "MacVolumeMixer-tap-\(label)"
        let tapUUID = UUID()
        description.uuid = tapUUID

        guard let tap = try system.makeProcessTap(description: description) else {
            throw OSStatusError(status: kAudio_ParamError, context: "makeProcessTap(\(label))")
        }

        do {
            let outputUID = try outputDevice.uid
            let aggregateUID = "com.adjustvolume.MacVolumeMixer.\(label).\(tapUUID.uuidString)"
            let composition: [String: Any] = [
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceNameKey: "MacVolumeMixer (\(label))",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: 1,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: tapUUID.uuidString]
                ],
                kAudioAggregateDeviceTapAutoStartKey: 1
            ]

            guard let aggregateDevice = try system.makeAggregateDevice(description: composition) else {
                throw OSStatusError(status: kAudio_ParamError, context: "makeAggregateDevice(\(label))")
            }

            // The one raw Core Audio call left: creating a Block-based IOProc
            // isn't exposed by the macOS 15 Swift overlay, so we drop to the C
            // API here, scoped to just this call. Nothing else in this class
            // touches raw AudioObjectGetPropertyData/OSStatus plumbing.
            let gainStorage = self.gainStorage
            var newIOProcID: AudioDeviceIOProcID?
            try checkOSStatus(
                AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDevice.id, nil) { _, inInputData, _, outOutputData, _ in
                    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                    let outputBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
                    var currentGain = gainStorage.load()

                    for (inBuffer, outBuffer) in zip(inputBuffers, outputBuffers) {
                        guard let inData = inBuffer.mData, let outData = outBuffer.mData else { continue }
                        let frameCount = Int(min(inBuffer.mDataByteSize, outBuffer.mDataByteSize)) / MemoryLayout<Float32>.size
                        guard frameCount > 0 else { continue }
                        let inFloats = inData.assumingMemoryBound(to: Float32.self)
                        let outFloats = outData.assumingMemoryBound(to: Float32.self)
                        vDSP_vsmul(inFloats, 1, &currentGain, outFloats, 1, vDSP_Length(frameCount))
                    }
                },
                "AudioDeviceCreateIOProcIDWithBlock(\(label))"
            )

            try aggregateDevice.start(IOProcID: newIOProcID)

            self.tap = tap
            self.aggregateDevice = aggregateDevice
            self.ioProcID = newIOProcID
            self.isRunning = true
        } catch {
            // Roll back the tap if anything after it failed, so we never
            // leave a process muted with nothing replaying its audio.
            try? system.destroyProcessTap(tap)
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let aggregateDevice, let ioProcID {
            try? aggregateDevice.stop(IOProcID: ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
        }
        if let aggregateDevice {
            try? system.destroyAggregateDevice(aggregateDevice)
        }
        if let tap {
            try? system.destroyProcessTap(tap)
        }
        aggregateDevice = nil
        tap = nil
        ioProcID = nil
    }

    deinit { stop() }
}

/// Lock-free scalar shared between the main actor (UI slider) and the
/// realtime audio render thread. Core Audio's render callback must never
/// block or allocate, so a lock (even `os_unfair_lock`) is the wrong tool
/// here. A 4-byte-aligned `Float` load/store is a single atomic hardware
/// instruction on both arm64 and x86_64, so this gives the render thread a
/// torn-read-free value without ever blocking it; the only observable effect
/// of the missing memory barrier is that a gain change may take one extra
/// ~10ms IO cycle to become audible, which is imperceptible for a volume
/// slider.
final class AtomicFloat: @unchecked Sendable {
    private let box: ManagedBuffer<Float, Void>

    init(_ initialValue: Float) {
        box = ManagedBuffer<Float, Void>.create(minimumCapacity: 0) { _ in initialValue }
    }

    func load() -> Float {
        box.withUnsafeMutablePointerToHeader { $0.pointee }
    }

    func store(_ value: Float) {
        box.withUnsafeMutablePointerToHeader { $0.pointee = value }
    }
}
