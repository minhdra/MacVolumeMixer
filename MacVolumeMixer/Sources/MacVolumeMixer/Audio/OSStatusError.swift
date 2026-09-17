import CoreAudio
import Foundation

/// Wraps a raw `OSStatus` from the few Core Audio calls not covered by the
/// macOS 15 `AudioHardware*` Swift overlay (see AudioEngine.swift for why we
/// still need one raw call: `AudioDeviceCreateIOProcIDWithBlock`). Everywhere
/// else we use the overlay's own `throws`-based `AudioHardwareError`, so this
/// type exists to keep the *one* remaining raw boundary just as debuggable.
struct OSStatusError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String

    /// Core Audio statuses are four-character codes (e.g. '!obj'). Decoding
    /// them to text is the single most useful thing you can do to make a bare
    /// OSStatus debuggable — this is that helper.
    var fourCharCode: String {
        var value = UInt32(bitPattern: status).bigEndian
        let bytes = withUnsafeBytes(of: &value) { Array($0) }
        let scalars = bytes.map { byte -> Character in
            (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
        }
        return String(scalars)
    }

    var description: String {
        "\(context) failed: OSStatus \(status) ('\(fourCharCode)')"
    }
}

@discardableResult
func checkOSStatus(_ status: OSStatus, _ context: String) throws -> OSStatus {
    guard status == noErr else { throw OSStatusError(status: status, context: context) }
    return status
}
