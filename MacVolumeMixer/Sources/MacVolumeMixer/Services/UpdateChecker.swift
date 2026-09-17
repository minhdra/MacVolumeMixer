import Foundation

/// Result of comparing the running app's version against the latest tagged
/// GitHub release.
struct UpdateCheckResult {
    let isUpdateAvailable: Bool
    let latestVersion: String
    let currentVersion: String
    let releaseURL: URL?
}

enum UpdateCheckError: Error, CustomStringConvertible {
    case invalidResponse
    case rateLimited

    var description: String {
        switch self {
        case .invalidResponse: return "GitHub returned an unexpected response."
        case .rateLimited: return "GitHub API rate limit reached — try again later."
        }
    }
}

/// Checks GitHub Releases for a version newer than the one currently
/// running. This is the **only** place in the whole app that makes a network
/// request — one unauthenticated GET to the public GitHub Releases API, no
/// telemetry, no account, no data about the user or machine beyond the
/// standard `User-Agent` header GitHub's API requires. It never runs on its
/// own: it's triggered either by the user pressing "Check for Updates…" in
/// Settings, or, only if the user has explicitly opted in, once at launch
/// (see `SettingsView`'s "Automatically check on launch" toggle, which
/// defaults to **off**). That keeps the rest of the product's
/// fully-offline-by-default design intact.
enum UpdateChecker {
    /// "owner/repo" on github.com.
    static let repository = "minhdra/MacVolumeMixer"

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    static func checkForUpdate() async throws -> UpdateCheckResult {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("MacVolumeMixer/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw UpdateCheckError.invalidResponse }
        if httpResponse.statusCode == 403 { throw UpdateCheckError.rateLimited }
        guard httpResponse.statusCode == 200 else { throw UpdateCheckError.invalidResponse }

        struct ReleasePayload: Decodable {
            let tag_name: String
            let html_url: String
        }
        let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
        let latest = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name

        return UpdateCheckResult(
            isUpdateAvailable: isVersion(latest, newerThan: currentVersion),
            latestVersion: latest,
            currentVersion: currentVersion,
            releaseURL: URL(string: payload.html_url)
        )
    }

    /// Dotted-numeric version comparison (e.g. "1.2.10" > "1.2.9"). Falls
    /// back to a plain string comparison for anything non-numeric, so an
    /// unexpected tag format never crashes the check — worst case it just
    /// reports no update available.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        guard !aParts.isEmpty, !bParts.isEmpty else { return a != b && a > b }

        for index in 0..<max(aParts.count, bParts.count) {
            let left = index < aParts.count ? aParts[index] : 0
            let right = index < bParts.count ? bParts[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
