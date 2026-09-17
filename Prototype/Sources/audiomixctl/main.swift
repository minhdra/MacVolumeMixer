// audiomixctl — Phase 2 proof-of-concept CLI for MacVolumeMixer.
//
// Goal: prove, with real Core Audio calls (no simulation), that:
//   1. We can enumerate processes that are producing audio, without polling.
//   2. We can mute one specific process's path to hardware and re-synthesize
//      its audio ourselves at a gain we choose, without touching system
//      volume or any other process's volume.
//
// Every selector / key / function used here was verified against the actual
// headers in /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk — see
// docs/audio-architecture.md for the citations. No private API is used.
//
// Usage:
//   audiomixctl list
//   audiomixctl set-volume <bundleID> <0.0-1.0> [durationSeconds]
//
// "set-volume" mutes the target process at the HAL and replays its audio at
// the requested gain through the default output device for the given
// duration (default 8s), then cleans up and restores the process to
// unmuted. While it runs, system volume and every other app's volume are
// untouched — that is the entire point of the demonstration.

import Foundation
import CoreAudio
import AudioToolbox

// MARK: - OSStatus helper

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String

    var description: String {
        let fourCC = fourCharString(from: status)
        return "\(context) failed: OSStatus \(status) ('\(fourCC)')"
    }
}

private func fourCharString(from status: OSStatus) -> String {
    var value = UInt32(bitPattern: status).bigEndian
    let bytes = withUnsafeBytes(of: &value) { Array($0) }
    let scalars = bytes.map { byte -> Character in
        (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
    }
    return String(scalars)
}

@discardableResult
private func check(_ status: OSStatus, _ context: String) throws -> OSStatus {
    guard status == noErr else { throw CoreAudioError(status: status, context: context) }
    return status
}

// MARK: - Generic AudioObject property helpers

private func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

private func getUInt32Property(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
    var address = propertyAddress(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value), "get UInt32 property")
    return value
}

private func getPIDProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> pid_t {
    var address = propertyAddress(selector)
    var value: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value), "get pid_t property")
    return value
}

private func getStringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = propertyAddress(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
    var cfString: CFString? = nil
    let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
    }
    guard status == noErr, let result = cfString else { return nil }
    return result as String
}

private func getAudioObjectIDArrayProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
    var address = propertyAddress(selector)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size), "get array property size")
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var values = [AudioObjectID](repeating: 0, count: count)
    try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &values), "get array property")
    return values
}

// MARK: - Process discovery (event-capable; polled once here for a one-shot CLI listing)

struct AudioAppProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
}

func listAudioProcesses() throws -> [AudioAppProcess] {
    let objectIDs = try getAudioObjectIDArrayProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    return objectIDs.compactMap { id -> AudioAppProcess? in
        guard let pid = try? getPIDProperty(id, kAudioProcessPropertyPID), pid > 0 else { return nil }
        let bundleID = getStringProperty(id, kAudioProcessPropertyBundleID)
        let isRunningOutput = (try? getUInt32Property(id, kAudioProcessPropertyIsRunningOutput)) == 1
        return AudioAppProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: isRunningOutput)
    }
}

func findProcessObjectID(forBundleID bundleID: String) throws -> AudioAppProcess? {
    try listAudioProcesses().first { $0.bundleID == bundleID }
}

// MARK: - Default output device

func defaultOutputDeviceID() throws -> AudioObjectID {
    try getUInt32Property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
}

func deviceUID(_ deviceID: AudioObjectID) -> String? {
    getStringProperty(deviceID, kAudioDevicePropertyDeviceUID)
}

// MARK: - Volume engine (mute-and-replay through a private aggregate device)

final class GainBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Float
    init(_ value: Float) { _value = value }
    var value: Float {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

final class ProcessVolumeSession {
    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    let gain: GainBox

    init(gain: Float) {
        self.gain = GainBox(gain)
    }

    /// Mutes `process` at the HAL and starts replaying its audio through the
    /// default output device, scaled by `gain.value`. This is the load-bearing
    /// proof for the whole product: system volume and every other process are
    /// left completely untouched.
    func start(process: AudioAppProcess, outputDeviceID: AudioObjectID) throws {
        guard let outputUID = deviceUID(outputDeviceID) else {
            throw CoreAudioError(status: kAudio_ParamError, context: "resolve output device UID")
        }

        // 1. Describe and create the tap. muteBehavior = .muted silences the
        //    process's own path to hardware — this is what turns "capture"
        //    into "control". See docs/audio-architecture.md.
        let description = CATapDescription(stereoMixdownOfProcesses: [process.objectID])
        description.muteBehavior = .muted
        description.isPrivate = true
        description.name = "audiomixctl-tap-\(process.pid)"
        let tapUUID = UUID()
        description.uuid = tapUUID

        var newTapID: AudioObjectID = 0
        try check(AudioHardwareCreateProcessTap(description, &newTapID), "AudioHardwareCreateProcessTap")
        tapID = newTapID

        // 2. Wrap the tap and the real output device in one private, ephemeral
        //    aggregate device. Nothing here is persisted or visible in Sound
        //    settings, and it is destroyed on cleanup / process exit.
        let aggregateUID = "com.audiomixctl.session.\(process.pid).\(tapUUID.uuidString)"
        let composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "audiomixctl (\(process.bundleID ?? String(process.pid)))",
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

        var newAggregateID: AudioObjectID = 0
        try check(
            AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregateID),
            "AudioHardwareCreateAggregateDevice"
        )
        aggregateDeviceID = newAggregateID

        // 3. Our own render pass: copy the tapped (muted) process's samples
        //    into the aggregate device's output side, scaled by `gain`. This
        //    single scalar multiply per buffer is the entire "volume slider".
        let gainBox = gain
        var newIOProcID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, nil) { _, inInputData, _, outOutputData, _ in
                let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                let outputBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
                let currentGain = gainBox.value

                for (inBuffer, outBuffer) in zip(inputBuffers, outputBuffers) {
                    guard let inData = inBuffer.mData, let outData = outBuffer.mData else { continue }
                    let frameCount = Int(min(inBuffer.mDataByteSize, outBuffer.mDataByteSize)) / MemoryLayout<Float32>.size
                    let inFloats = inData.assumingMemoryBound(to: Float32.self)
                    let outFloats = outData.assumingMemoryBound(to: Float32.self)
                    var gainValue = currentGain
                    vDSP_vsmul(inFloats, 1, &gainValue, outFloats, 1, vDSP_Length(frameCount))
                }
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = newIOProcID

        try check(AudioDeviceStart(aggregateDeviceID, ioProcID), "AudioDeviceStart")
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateDeviceID = 0
        tapID = 0
    }

    deinit { stop() }
}

// vDSP for the scalar multiply.
import Accelerate

// MARK: - CLI

func printUsageAndExit() -> Never {
    print("""
    audiomixctl — per-process audio control proof-of-concept

    Usage:
      audiomixctl list
      audiomixctl set-volume <bundleID> <0.0-1.0> [durationSeconds]
    """)
    exit(64)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { printUsageAndExit() }

switch arguments[1] {
case "list":
    do {
        let processes = try listAudioProcesses()
        print(String(format: "%-8@ %-24@ %-10@ %@", "PID", "BUNDLE ID", "OBJ ID", "AUDIO"))
        print("PID      BUNDLE ID                OBJID      AUDIO")
        for process in processes {
            let audioState = process.isRunningOutput ? "active" : "inactive"
            let bundle = process.bundleID ?? "(none)"
            print(String(format: "%-8d %-24@ %-10d %@", process.pid, bundle as NSString, process.objectID, audioState))
        }
    } catch {
        FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "set-volume":
    guard arguments.count >= 4, let requestedGain = Float(arguments[3]) else { printUsageAndExit() }
    let bundleID = arguments[2]
    let duration = arguments.count >= 5 ? (Double(arguments[4]) ?? 8) : 8
    let clampedGain = max(0, min(1, requestedGain))

    do {
        guard let process = try findProcessObjectID(forBundleID: bundleID) else {
            print("No audio process found for bundle ID '\(bundleID)'. Run 'audiomixctl list' first and make sure the app is currently playing audio.")
            exit(1)
        }
        let outputID = try defaultOutputDeviceID()
        let session = ProcessVolumeSession(gain: clampedGain)
        print("Muting \(bundleID) (pid \(process.pid)) at the HAL and replaying at gain \(clampedGain) for \(duration)s...")
        try session.start(process: process, outputDeviceID: outputID)
        print("Running. System volume and other apps are untouched. Ctrl+C to stop early.")

        signal(SIGINT) { _ in exit(0) }
        Thread.sleep(forTimeInterval: duration)

        session.stop()
        print("Stopped. \(bundleID) restored to normal (unmuted) playback.")
    } catch {
        FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

default:
    printUsageAndExit()
}
