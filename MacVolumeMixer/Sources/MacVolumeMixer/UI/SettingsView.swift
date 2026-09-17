import SwiftUI
import AppKit

/// Drives the "Check for Updates…" button and the opt-in auto-check toggle.
/// Kept separate from `UpdateChecker` (pure network/version logic, no
/// SwiftUI) so the logic stays independently testable.
@MainActor
final class UpdateCheckViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String)
        case failed(String)
    }

    private enum DefaultsKeys {
        static let autoCheckOnLaunch = "com.adjustvolume.MacVolumeMixer.autoCheckForUpdatesOnLaunch"
    }

    @Published private(set) var state: State = .idle
    @Published var autoCheckOnLaunch: Bool {
        didSet { UserDefaults.standard.set(autoCheckOnLaunch, forKey: DefaultsKeys.autoCheckOnLaunch) }
    }

    private var releaseURL: URL?

    init() {
        autoCheckOnLaunch = UserDefaults.standard.bool(forKey: DefaultsKeys.autoCheckOnLaunch)
    }

    /// Called from `AppDelegate` at launch, but only does anything if the
    /// user has opted in — see `UpdateChecker`'s doc comment on why this
    /// stays opt-in rather than automatic.
    func checkOnLaunchIfEnabled() {
        guard autoCheckOnLaunch else { return }
        check()
    }

    func check() {
        state = .checking
        Task {
            do {
                let result = try await UpdateChecker.checkForUpdate()
                releaseURL = result.releaseURL
                state = result.isUpdateAvailable ? .updateAvailable(version: result.latestVersion) : .upToDate
            } catch {
                state = .failed("\(error)")
            }
        }
    }

    func openReleasePage() {
        guard let releaseURL else { return }
        NSWorkspace.shared.open(releaseURL)
    }
}

/// Minimal settings window. Kept intentionally small — this app has almost
/// nothing to configure, since volume/mute live in the popover itself and
/// persistence is automatic.
struct SettingsView: View {
    // Both owned by AppDelegate (not @StateObject here) so they're the same
    // instances the popover reads, and so update-on-launch / permission
    // state started before this window ever exists is reflected here too.
    @ObservedObject var engine: AudioEngine
    @ObservedObject var updateChecker: UpdateCheckViewModel
    var onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacVolumeMixer")
                .font(.headline)
            Text("Per-app volume control uses macOS's Core Audio process tap API, which requires one-time \"Audio Recording\" permission so this app can capture and replay each app's audio at its own volume.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if engine.needsRelaunchToUsePermission {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Permission granted, but macOS needs MacVolumeMixer restarted to actually use it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Button("Restart Now", action: onRestart)
                }
            } else if !engine.permissionGranted {
                Text("Permission not granted yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else {
                Text("Permission granted.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button("Open Privacy & Security Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Version \(UpdateChecker.currentVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for Updates…") { updateChecker.check() }
                        .disabled(updateChecker.state == .checking)
                }

                switch updateChecker.state {
                case .idle:
                    EmptyView()
                case .checking:
                    Text("Checking GitHub for the latest release…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                case .upToDate:
                    Text("You're up to date.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                case .updateAvailable(let version):
                    HStack {
                        Text("Version \(version) is available.")
                            .font(.system(size: 11))
                        Button("Download") { updateChecker.openReleasePage() }
                    }
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                Toggle("Automatically check on launch", isOn: $updateChecker.autoCheckOnLaunch)
                    .font(.system(size: 12))
                    .toggleStyle(.checkbox)
            }

            Divider()

            Button("Quit MacVolumeMixer") {
                NSApp.terminate(nil)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
