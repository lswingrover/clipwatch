import Foundation
import AppKit

// MARK: - UpdateChecker
//
// On launch, asynchronously fetches the latest GitHub release for ClipWatch
// and compares it to the running version. If a newer version is available,
// posts .updateAvailable so AppDelegate can surface it in the status-bar menu.
// AppDelegate also exposes "View on GitHub" as a persistent menu item.
// PreferencesWindowController shows a GitHub link in the footer.
//
// Runs once per launch. No background timer — no annoyance.
// Uses URLSession's shared session; no auth required for public repos.

extension Notification.Name {
    static let updateAvailable = Notification.Name("com.louisswingrover.clipwatch.updateAvailable")
}

struct UpdateInfo {
    let tagName:    String   // e.g. "1.4.0"
    let releaseURL: URL
}

enum UpdateChecker {

    // Force-unwrap replaced with static let using a compile-time-safe initialiser.
    // These are well-formed literals; using a guard at call sites avoids any startup crash.
    private static let repoAPI = URL(string: "https://api.github.com/repos/lswingrover/clipwatch/releases/latest")
    private static let releasesPage = URL(string: "https://github.com/lswingrover/clipwatch/releases")

    /// Call once from AppDelegate.applicationDidFinishLaunching.
    static func checkInBackground() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            fetch()
        }
    }

    private static func fetch() {
        // Guard prevents crash if URL constant ever fails to parse (should never
        // happen, but the compiler doesn't know that without a literal initialiser).
        guard let apiURL = repoAPI else { return }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let rawTag = json["tag_name"] as? String
            else { return }

            let tag     = rawTag.hasPrefix("v") ? String(rawTag.dropFirst()) : rawTag
            // Prefer the release's html_url, then the releases page constant, then bail.
            guard let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:))
                             ?? releasesPage
            else { return }

            guard isNewer(tag, thanCurrent: currentVersion()) else { return }

            let info = UpdateInfo(tagName: tag, releaseURL: htmlURL)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .updateAvailable, object: info)
            }
        }.resume()
    }

    static func openReleasePage() {
        // releasesPage is now Optional; guard avoids crash if URL constant fails.
        guard let url = releasesPage else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Returns true if `candidate` is a higher semver than `current`.
    private static func isNewer(_ candidate: String, thanCurrent current: String) -> Bool {
        let cv = parts(current)
        let nv = parts(candidate)
        for i in 0 ..< max(cv.count, nv.count) {
            let c = i < cv.count ? cv[i] : 0
            let n = i < nv.count ? nv[i] : 0
            if n > c { return true }
            if n < c { return false }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }
}
