import Foundation
import AppKit

// MARK: - UpdateChecker
//
// On launch, asynchronously fetches the latest GitHub release for ClipWatch
// and compares it to the running version. If a newer version is available,
// posts .updateAvailable so AppDelegate can surface it in the menu.
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

    private static let repoAPI = URL(string: "https://api.github.com/repos/lswingrover/clipwatch/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/lswingrover/clipwatch/releases")!

    /// Call once from AppDelegate.applicationDidFinishLaunching.
    static func checkInBackground() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            fetch()
        }
    }

    private static func fetch() {
        var request = URLRequest(url: repoAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let rawTag = json["tag_name"] as? String
            else { return }

            let tag     = rawTag.hasPrefix("v") ? String(rawTag.dropFirst()) : rawTag
            let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage

            guard isNewer(tag, thanCurrent: currentVersion()) else { return }

            let info = UpdateInfo(tagName: tag, releaseURL: htmlURL)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .updateAvailable, object: info)
            }
        }.resume()
    }

    static func openReleasePage() {
        NSWorkspace.shared.open(releasesPage)
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
