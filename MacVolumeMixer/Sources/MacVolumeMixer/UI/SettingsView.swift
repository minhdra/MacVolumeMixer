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
    @ObservedObject var loginItemManager: LoginItemManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacVolumeMixer")
                .font(.headline)
            Text("Per-app volume control uses macOS's Core Audio process tap API, which requires one-time \"Audio Recording\" permission so this app can capture and replay each app's audio at its own volume.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(permissionText, systemImage: permissionIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(permissionColor)

            Button("Open Privacy & Security Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "Open MacVolumeMixer at login",
                    isOn: Binding(
                        get: { loginItemManager.isEnabled },
                        set: { loginItemManager.setEnabled($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

                if loginItemManager.requiresApproval {
                    Text("Allow MacVolumeMixer in System Settings → General → Login Items.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else if let error = loginItemManager.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
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

    private var permissionText: String {
        switch engine.capturePermissionState {
        case .notVerified: "Audio access has not been verified"
        case .requesting: "Waiting for audio access"
        case .granted: "Audio access granted"
        case .needsPermission: "Audio access is required"
        }
    }

    private var permissionIcon: String {
        switch engine.capturePermissionState {
        case .granted: "checkmark.circle.fill"
        case .requesting: "clock.fill"
        case .needsPermission: "exclamationmark.circle.fill"
        case .notVerified: "questionmark.circle.fill"
        }
    }

    private var permissionColor: Color {
        switch engine.capturePermissionState {
        case .granted: .green
        case .requesting: .orange
        case .needsPermission: .red
        case .notVerified: .secondary
        }
    }
}
