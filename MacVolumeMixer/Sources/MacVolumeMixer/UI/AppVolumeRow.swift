import SwiftUI

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
                if !app.isPlayingAudio {
                    Text("paused")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                Slider(value: volumePercent, in: 0...100)
                    .disabled(app.isMuted)
                Text("\(Int(app.volume * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 32, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Button(action: onMuteToggle) {
                    Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(app.isMuted ? .red : .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
