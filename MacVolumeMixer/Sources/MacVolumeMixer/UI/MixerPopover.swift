import SwiftUI

/// The popover content shown when the menu bar icon is clicked. Pure system
/// controls (Slider, Button, Divider), no custom rendering, native light/dark
/// appearance via the environment `colorScheme` — nothing hardcoded.
struct MixerPopover: View {
    @ObservedObject var engine: AudioEngine
    @State private var showsMoreApps = false
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if showsMoreApps {
                    Button {
                        showsMoreApps = false
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                }
                Text(showsMoreApps ? "More apps" : "Volume mixer")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(displayedApps.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !showsMoreApps {
                HStack(spacing: 20) {
                Button(action: MediaKeyController.previous) {
                    Image(systemName: "backward.fill")
                }
                Button(action: MediaKeyController.playPause) {
                    Image(systemName: "playpause.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                Button(action: MediaKeyController.next) {
                    Image(systemName: "forward.fill")
                }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 11)
            }

            Divider()

            if let lastError = engine.lastError {
                Text(lastError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }

            if displayedApps.isEmpty {
                Text(showsMoreApps ? "No other audio apps." : "No media is playing.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(displayedApps) { app in
                            AppVolumeRow(
                                app: app,
                                onVolumeChange: { engine.setVolume($0, forAppID: app.id) },
                                onMuteToggle: { engine.setMuted(!app.isMuted, forAppID: app.id) },
                                showsMediaControls: !showsMoreApps
                            )
                            .padding(.horizontal, 14)
                            if app.id != displayedApps.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(displayedApps.count) * 60, 330))
            }

            if !showsMoreApps && !otherApps.isEmpty {
                Divider()
                Button {
                    showsMoreApps = true
                } label: {
                    HStack {
                        Text("More…")
                        Spacer()
                        Text("\(otherApps.count)")
                            .foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }

            Divider()

            HStack {
                Text("Output: \(engine.outputDeviceName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
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
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .frame(width: 310)
    }

    private var mediaApps: [AudioAppProcess] {
        engine.apps.filter(\.belongsInMediaSection)
    }

    private var otherApps: [AudioAppProcess] {
        engine.apps.filter { !$0.belongsInMediaSection }
    }

    private var displayedApps: [AudioAppProcess] {
        showsMoreApps ? otherApps : mediaApps
    }

}
