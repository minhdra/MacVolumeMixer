import AppKit
import SwiftUI

/// Owns the menu bar item, its popover, and the audio engine's lifetime.
/// Deliberately AppKit (`NSStatusItem` + `NSPopover`) rather than
/// `MenuBarExtra`: it gives direct control over popover behavior (`.transient`
/// dismissal) and avoids running a SwiftUI `App`/`Scene` life cycle just to
/// host one status item, keeping idle footprint to "one status item + one
/// lazily-created popover" per the performance requirement.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindowController: NSWindowController?
    private let engine = AudioEngine()
    private let updateChecker = UpdateCheckViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders alongside Info.plist's LSUIElement: guarantees
        // no Dock icon / app switcher entry even if the embedded plist is
        // ever stripped by a packaging step.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Audio Mixer")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MixerPopover(
                engine: engine,
                onOpenSettings: { [weak self] in self?.showSettings() },
                onQuit: { NSApp.terminate(nil) },
                onRestart: { [weak self] in self?.relaunch() }
            )
        )
        self.popover = popover

        engine.start()
        updateChecker.checkOnLaunchIfEnabled() // no-op unless the user opted in via Settings
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Schedule a hard, unconditional exit on a background queue FIRST,
        // before attempting any cleanup. This guarantees the app actually
        // quits — no zombie menu bar item left behind — even in the worst
        // case where a Core Audio teardown call were to hang the main
        // thread: the background timer keeps running independently and
        // force-exits regardless.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            exit(0)
        }

        // Best-effort cleanup: unmutes every process we tapped and destroys
        // every tap/aggregate device we created, so nothing is left silently
        // muted at the HAL after we quit.
        engine.stop()
        exit(0)
    }

    /// Relaunches the app in a fresh process. Needed after the user grants
    /// audio-capture permission mid-session: macOS/coreaudiod latch the
    /// authorization decision at the time a process's first tap attempt is
    /// made, so a permission grant while already running doesn't reliably
    /// take effect until relaunch (see `AudioEngine.needsRelaunchToUsePermission`).
    /// Spawns a new instance via `/usr/bin/open` before exiting this one, so
    /// there's no gap where the menu bar icon disappears entirely.
    private func relaunch() {
        engine.stop() // unmute everything before we go, same as a normal quit
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [Bundle.main.bundlePath]
        try? task.run()
        exit(0)
    }

    @objc private func togglePopover(_ sender: AnyObject) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 340),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacVolumeMixer Settings"
            window.contentViewController = NSHostingController(
                rootView: SettingsView(engine: engine, updateChecker: updateChecker, onRestart: { [weak self] in self?.relaunch() })
            )
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
