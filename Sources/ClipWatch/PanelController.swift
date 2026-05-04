import AppKit
import LocalAuthentication

// MARK: - PanelController
//
// Manages the floating search panel.
//
// Authentication:
//   When "Require Touch ID" is enabled in Preferences, show() calls
//   authenticateForPanel() before presenting the panel. On success,
//   isAuthenticated = true and the panel opens with all content visible.
//   On failure/cancel, the panel is not shown.
//
//   When secure mode is OFF, isAuthenticated starts false. Sensitive clips
//   render as a lock card. Pressing ↩ on one calls onAuthNeeded, which
//   triggers authenticateForClip(). On success, isAuthenticated flips true,
//   the table reloads, and the paste fires.
//
//   isAuthenticated resets to false on every hide() so each invocation is clean.
//
// Focus strategy:
//   NSApp.activate is called so the panel reliably receives keyboard events.
//   previousApp is captured before activating. On paste/dismiss, previousApp
//   is re-activated before the synthetic ⌘V fires.
//
// Dismiss (belt-and-suspenders):
//   1. Global mouse monitor — clicks anywhere outside the panel.
//   2. NSApplication.didResignActiveNotification — Cmd-Tab, Dock, etc.

final class PanelController {
    private var panel:        NSPanel?
    private var searchVC:     SearchViewController?
    private var clickMonitor: Any?
    private var previousApp:  NSRunningApplication?

    /// True once the user has authenticated this panel session.
    private(set) var isAuthenticated = false

    /// Timestamp of the last successful Touch ID / password auth.
    /// Persists across hide/show cycles so the unlock window is honoured.
    private var lastAuthTime: Date?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    // MARK: - Show / Hide

    func show() {
        if panel == nil { buildPanel() }
        previousApp = NSWorkspace.shared.frontmostApplication

        if Prefs.isSecureModeEnabled() {
            if isWithinUnlockWindow() {
                isAuthenticated = true
                presentPanel()
            } else {
                authenticateForPanel()
            }
        } else {
            isAuthenticated = false
            presentPanel()
        }
    }

    func hide() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        panel?.orderOut(nil)
        searchVC?.reset()
        isAuthenticated = false   // reset per-session display flag; lastAuthTime intentionally preserved
    }

    // MARK: - Unlock window

    /// Returns true if the user authenticated recently enough to skip re-auth.
    private func isWithinUnlockWindow() -> Bool {
        guard let t = lastAuthTime else { return false }
        let secs = Prefs.unlockDurationSeconds()
        if secs == -1 { return true }                            // until app restarts
        if secs == 0  { return false }                           // every use
        return Date().timeIntervalSince(t) < Double(secs)
    }

    /// Records the current time as the last successful authentication.
    private func recordAuth() {
        lastAuthTime = Date()
    }

    // MARK: - Authentication

    private func authenticateForPanel() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // LocalAuthentication unavailable — allow through gracefully.
            isAuthenticated = true
            presentPanel()
            return
        }
        ctx.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Unlock ClipWatch clipboard history"
        ) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.isAuthenticated = true
                    self.recordAuth()
                    self.presentPanel()
                }
                // Failure/cancel: panel stays hidden, no error shown.
            }
        }
    }

    /// Called when the user presses ↩ on a sensitive clip while not authenticated.
    func authenticateForClip(completion: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            completion(true)
            return
        }
        ctx.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "View sensitive clipboard item"
        ) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }

    // MARK: - Present

    private func presentPanel() {
        position()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let auth = isAuthenticated
        DispatchQueue.main.async { [weak self] in
            self?.searchVC?.prepareForDisplay(isAuthenticated: auth)
        }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    // MARK: - Build

    private func buildPanel() {
        let vc = SearchViewController()

        vc.onPaste = { [weak self] content in
            guard let self else { return }
            let target = self.previousApp
            self.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                target?.activate(options: .activateIgnoringOtherApps)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    AppDelegate.shared?.paste(content)
                }
            }
        }

        vc.onDismiss = { [weak self] in
            guard let self else { return }
            let target = self.previousApp
            self.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                target?.activate(options: .activateIgnoringOtherApps)
            }
        }

        // Clip-level auth: called when the user tries to paste a sensitive clip
        // without having authenticated the session.
        vc.onAuthNeeded = { [weak self] completion in
            self?.authenticateForClip { success in
                if success {
                    self?.isAuthenticated = true
                    self?.recordAuth()
                    completion()
                }
            }
        }

        searchVC = vc

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.contentViewController = vc
        p.isOpaque              = false
        p.backgroundColor       = .clear
        p.hasShadow             = true
        p.level                 = .floating
        p.hidesOnDeactivate     = false
        p.isMovableByWindowBackground = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: p
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDeactivated),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        panel = p
    }

    @objc private func windowDidBecomeKey() { searchVC?.focusSearchField() }
    @objc private func appDeactivated()     { hide() }

    // MARK: - Positioning

    private func position() {
        guard let panel else { return }
        let screen = targetScreen()
        let sf     = screen.visibleFrame
        let x = sf.midX - panel.frame.width / 2
        let y = sf.midY + sf.height * 0.10
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func targetScreen() -> NSScreen {
        if Prefs.screenMode() == "cursor" {
            let pt = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(pt, $0.frame, false) }
                ?? NSScreen.main ?? NSScreen.screens[0]
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}
