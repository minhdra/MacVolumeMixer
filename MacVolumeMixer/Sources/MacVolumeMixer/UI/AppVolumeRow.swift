import SwiftUI
import AppKit

/// One mixer row: icon, name, 0-100 slider, mute toggle.
///
/// The slider updates on every drag tick with no throttling — unlike a real
/// Core Audio property set, our per-tick cost is a single atomic `Float`
/// store into the render thread's gain cell (see `AtomicFloat` in
/// VolumeController.swift), so coalescing would only add latency for no
/// savings. If a future revision moves gain control to an operation that is
/// actually expensive per call, throttle here first.
struct AppVolumeRow: View {
    let app: AudioAppProcess
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void
    var showsMediaControls = false

    private var volumePercent: Binding<Double> {
        Binding(
            get: { Double(app.volume * 100) },
            set: { onVolumeChange(Float($0 / 100)) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app.dashed")
                        .frame(width: 20, height: 20)
                        .foregroundStyle(.secondary)
                }
                Text(app.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if showsMediaControls {
                    HStack(spacing: 11) {
                        Button { MediaKeyController.previous(bundleID: app.bundleID) } label: {
                            Image(systemName: "backward.fill")
                        }
                        Button { MediaKeyController.playPause(bundleID: app.bundleID) } label: {
                            Image(systemName: "playpause.fill")
                        }
                        Button { MediaKeyController.next(bundleID: app.bundleID) } label: {
                            Image(systemName: "forward.fill")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                } else if !app.isPlayingAudio {
                    Text("paused")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                MacOSVolumeSlider(value: volumePercent)
                .disabled(app.isMuted)
                .opacity(app.isMuted ? 0.48 : 1)
                .help("Volume: \(Int(app.volume * 100))%")
                Button(action: onMuteToggle) {
                    Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(app.isMuted ? Color.red : Color.secondary)
                .contentShape(Rectangle())
                .help(app.isMuted ? "Unmute \(app.displayName)" : "Mute \(app.displayName)")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Compact Control Center-style volume slider: a soft capsule, filled level,
/// speaker glyph inside the track, and a white circular thumb.
private struct MacOSVolumeSlider: View {
    @Binding var value: Double
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let thumbRadius: CGFloat = 10
            let travel = max(width - thumbRadius * 2, 1)
            let fraction = min(max(value / 100, 0), 1)
            let thumbX = thumbRadius + travel * fraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.16))

                Capsule()
                    .fill(Color.primary.opacity(0.82))
                    .frame(width: max(thumbX, 20))

                Image(systemName: value == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 24)
                    .padding(.leading, 3)

            }
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                    .offset(x: thumbX - thumbRadius)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        let position = min(max(gesture.location.x - thumbRadius, 0), travel)
                        value = Double(position / travel) * 100
                    }
            )
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 5, 100)
            case .decrement: value = max(value - 5, 0)
            @unknown default: break
            }
        }
    }
}
