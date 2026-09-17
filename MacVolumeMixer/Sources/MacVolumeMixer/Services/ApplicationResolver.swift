import AppKit
import Darwin
import UniformTypeIdentifiers

/// Resolves a raw HAL process (PID + HAL-reported bundle ID) to the *logical
/// application* it belongs to, and aggregates helper processes under it.
///
/// Product requirement #11: Chrome can back multiple HAL process objects
/// ("Google Chrome", "Google Chrome Helper", "Google Chrome Helper
/// (Renderer)", each with its own, more specific bundle ID reported by
/// `kAudioProcessPropertyBundleID`) but the mixer must show exactly one
/// "Chrome" row and apply volume to all of them together.
///
/// The grouping key is the *outermost* `.app` bundle in the process's
/// executable path — for `.../Google Chrome.app/Contents/Frameworks/Google
/// Chrome Framework.framework/.../Google Chrome Helper.app/Contents/MacOS/
/// Google Chrome Helper`, that's `Google Chrome.app`, regardless of how many
/// nested helper `.app` bundles sit inside it. This works uniformly for a
/// plain single-bundle app (VLC, Spotify) and a multi-process browser
/// (Chrome, Discord's Electron shell) without special-casing either.
enum ApplicationResolver {
    struct Resolved {
        let bundleID: String?
        let displayName: String
        let icon: NSImage?
    }

    static func resolve(pid: pid_t, hintedBundleID: String?) -> Resolved {
        if let ownerAppPath = outermostAppBundlePath(forPID: pid), let bundle = Bundle(path: ownerAppPath) {
            let name = (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? FileManager.default.displayName(atPath: ownerAppPath).replacingOccurrences(of: ".app", with: "")
            let icon = NSWorkspace.shared.icon(forFile: ownerAppPath)
            return Resolved(bundleID: bundle.bundleIdentifier ?? hintedBundleID, displayName: name, icon: icon)
        }

        // Fall back to whatever the HAL told us (bare daemons with no .app
        // bundle, e.g. system audio components) rather than dropping the row.
        if let hintedBundleID {
            return Resolved(bundleID: hintedBundleID, displayName: hintedBundleID, icon: nil)
        }
        return Resolved(bundleID: nil, displayName: "PID \(pid)", icon: NSWorkspace.shared.icon(for: .unixExecutable))
    }

    private static func outermostAppBundlePath(forPID pid: pid_t) -> String? {
        // proc_pidpath's documented maximum (libproc.h: PROC_PIDPATHINFO_MAXSIZE
        // is 4 * MAXPATHLEN, but the macro itself isn't importable into Swift).
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let nullTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.count
        let executablePath = String(decoding: buffer[..<nullTerminatorIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)

        let components = executablePath.split(separator: "/")
        var runningPath = ""
        for component in components {
            runningPath += "/\(component)"
            if component.hasSuffix(".app") {
                return runningPath
            }
        }
        return nil
    }
}
