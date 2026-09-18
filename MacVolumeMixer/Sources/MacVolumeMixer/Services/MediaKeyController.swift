import AppKit
import IOKit.hidsystem

enum MediaKeyController {
    static func previous() { post(key: NX_KEYTYPE_PREVIOUS) }
    static func playPause() { post(key: NX_KEYTYPE_PLAY) }
    static func next() { post(key: NX_KEYTYPE_NEXT) }

    static func previous(bundleID: String?) { post(key: NX_KEYTYPE_PREVIOUS, bundleID: bundleID) }
    static func playPause(bundleID: String?) { post(key: NX_KEYTYPE_PLAY, bundleID: bundleID) }
    static func next(bundleID: String?) { post(key: NX_KEYTYPE_NEXT, bundleID: bundleID) }

    /// Sends the same system-defined events as the media keys on an Apple
    /// keyboard. macOS routes them to the active Now Playing session.
    private static func post(key: Int32, bundleID: String? = nil) {
        let pid = bundleID.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier
        }
        send(key: key, isDown: true, pid: pid)
        send(key: key, isDown: false, pid: pid)
    }

    private static func send(key: Int32, isDown: Bool, pid: pid_t?) {
        let keyState = isDown ? 0xA : 0xB
        let data = Int((key << 16) | (Int32(keyState) << 8))
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyState << 8)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data,
            data2: -1
        )
        if let pid {
            event?.cgEvent?.postToPid(pid)
        } else {
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
