import AppKit

// MARK: - ClipboardMonitor
//
// Polls NSPasteboard.general.changeCount every 0.5 s.
// There is no push API for clipboard changes on macOS — polling is the standard approach.
//
// URL exclusion:
//   When the frontmost app is a known browser and Accessibility is granted, the
//   monitor reads the browser's current page URL via AXUIElement (kAXDocumentAttribute
//   on the frontmost window) and checks it against the user's excludedURLs patterns.
//
//   Pattern semantics:
//     example.com          — matches all pages on example.com and any subdomain
//     sub.example.com      — only sub.example.com (not example.com itself)
//     example.com/path     — only that path prefix on example.com / its subdomains

final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int

    // AXIsProcessTrusted() is a system call — cache it so we don't invoke it
    // 1–2× per second. Permission changes are rare; 30 s TTL is more than fast enough.
    private var axTrustCached   = false
    private var axTrustCachedAt = Date.distantPast
    private let axTrustTTL: TimeInterval = 30

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        scheduleTimer()
    }

    /// Re-schedule the timer at the current Prefs.pollIntervalSeconds().
    /// Call from Preferences when the user changes the poll interval.
    func restart() {
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = Prefs.pollIntervalSeconds()
        // .default (not .common): avoids firing during menu-tracking and scroll events,
        // which would add latency to UI interactions for no benefit.
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Assign before adding to run loop; avoids force-unwrap if RunLoop.add ever
        // throws or the timer reference is needed in a re-entrancy scenario.
        timer = t
        RunLoop.main.add(t, forMode: .default)
    }

    private func isAXTrusted() -> Bool {
        let now = Date()
        if now.timeIntervalSince(axTrustCachedAt) > axTrustTTL {
            axTrustCached   = AXIsProcessTrusted()
            axTrustCachedAt = now
        }
        return axTrustCached
    }

    // MARK: - Known browsers

    private let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "com.opera.Opera",
        "com.vivaldi.Vivaldi",
    ]

    // MARK: - Poll

    private func poll() {
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard let content = NSPasteboard.general.string(forType: .string),
              !content.isEmpty else { return }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let source   = frontApp?.bundleIdentifier

        // URL exclusion: only when source is a known browser and AX is granted
        if let app = frontApp,
           let bid = source,
           browserBundleIDs.contains(bid),
           isAXTrusted() {
            let patterns = UserDefaults.standard.stringArray(forKey: Prefs.excludedURLs) ?? []
            if !patterns.isEmpty,
               let browserURL = currentBrowserURL(pid: app.processIdentifier),
               isURLExcluded(browserURL, patterns: patterns) {
                return
            }
        }

        ClipStore.shared.insert(content: content, source: source)
        NotificationCenter.default.post(name: .clipStoreDidChange, object: nil)
    }

    // MARK: - AX browser URL

    /// Reads the current page URL from the frontmost window of a browser process.
    /// Most browsers populate kAXDocumentAttribute on the window with the page URL.
    private func currentBrowserURL(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp,
                                            kAXWindowsAttribute as CFString,
                                            &windowsVal) == .success,
              let windows = windowsVal as? [AXUIElement],
              let front   = windows.first else { return nil }

        var docVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(front,
                                            kAXDocumentAttribute as CFString,
                                            &docVal) == .success,
              let urlString = docVal as? String else { return nil }
        return urlString
    }

    // MARK: - URL pattern matching

    /// Returns true if `url` matches any exclusion pattern.
    ///
    /// Matching rules for a given pattern:
    ///   - Strip scheme (https://, http://) from both sides before comparison.
    ///   - Host match: URL host equals pattern host, OR URL host ends with ".patternHost"
    ///     (covers all subdomains including www).
    ///   - Path match: pattern path "/" matches any path; otherwise URL path must
    ///     start with the pattern path.
    private func isURLExcluded(_ url: String, patterns: [String]) -> Bool {
        let cleanURL = stripScheme(url)
        for pattern in patterns {
            let cleanPat = stripScheme(pattern)

            let urlParts = cleanURL.split(separator: "/", maxSplits: 1).map(String.init)
            let patParts = cleanPat.split(separator: "/", maxSplits: 1).map(String.init)

            let urlHost = urlParts.first ?? cleanURL
            let patHost = patParts.first ?? cleanPat
            let urlPath = urlParts.count > 1 ? "/" + urlParts[1] : "/"
            let patPath = patParts.count > 1 ? "/" + patParts[1] : "/"

            // Host: exact match OR urlHost is a subdomain of patHost
            let hostMatch = urlHost == patHost || urlHost.hasSuffix("." + patHost)
            // Path: "/" in pattern matches everything; otherwise prefix check
            let pathMatch = patPath == "/" || urlPath.hasPrefix(patPath)

            if hostMatch && pathMatch { return true }
        }
        return false
    }

    private func stripScheme(_ s: String) -> String {
        s.replacingOccurrences(of: "https://", with: "")
         .replacingOccurrences(of: "http://", with: "")
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let clipStoreDidChange = Notification.Name("clipStoreDidChange")
    static let hotkeyChanged      = Notification.Name("hotkeyChanged")
}
