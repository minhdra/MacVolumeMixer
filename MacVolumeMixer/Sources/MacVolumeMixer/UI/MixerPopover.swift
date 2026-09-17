import SwiftUI

/// The popover content shown when the menu bar icon is clicked. Pure system
/// controls (Slider, Button, Divider), no custom rendering, native light/dark
/// appearance via the environment `colorScheme` — nothing hardcoded.
struct MixerPopover: View {
    @ObservedObject var engine: AudioEngine
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Audio Mixer")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if !engine.permissionGranted {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Needs \"Screen & System Audio Recording\" permission to control app volume.")
                        .font(.system(size: 11))
                    Button("Grant Permission…") { engine.requestAudioCapturePermission() }
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            } else if let lastError = engine.lastError {
                Text(lastError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }

            if engine.apps.isEmpty {
                Text("No apps are playing audio yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(engine.apps) { app in
                            AppVolumeRow(
                                app: app,
                                onVolumeChange: { engine.setVolume($0, forAppID: app.id) },
                                onMuteToggle: { engine.setMuted(!app.isMuted, forAppID: app.id) }
                            )
                            .padding(.horizontal, 14)
                            if app.id != engine.apps.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            Divider()

            HStack {
                Text("Output: \(engine.outputDeviceName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            // MacVolumeMixer is a menu-bar-only agent (no Dock icon, no
            // application menu bar), so Cmd+Q and "right-click Dock icon >
            // Quit" don't exist for it — Quit needs to be reachable directly
            // from this popover, not buried one extra click inside Settings.
            HStack {
                Button("Settings…", action: onOpenSettings)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                Spacer()
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .frame(width: 280)
    }
}
