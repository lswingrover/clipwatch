import AppKit

// MARK: - PanelController
//
// Manages the floating search panel.
//
// Dismiss strategy (belt-and-suspenders):
//   1. Global mouse monitor — catches clicks anywhere outside the panel,
//      including on the desktop where no app-switch occurs.
//   2. NSApplication.didResignActiveNotification — catches switching to
//      another app via Cmd-Tab, Dock click, etc.
//
// Focus strategy:
//   makeFirstResponder is dispatched async so the run loop has processed
//   makeKeyAndOrderFront before we attempt to set focus. Without the async,
//   the panel may not yet be key and makeFirstResponder silently fails.

final class PanelController {
    private var panel:        NSPanel?
    private var searchVC:     SearchViewController?
    private var clickMonitor: Any?   // global mouse-down monitor

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    // MARK: - Show / Hide

    func show() {
        if panel == nil { buildPanel() }
        position()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Async so the window is fully on-screen and key before we focus
        DispatchQueue.main.async { [weak self] in
            self?.searchVC?.prepareForDisplay()
        }

        // Global click monitor: any mouse-down outside the panel → dismiss
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        panel?.orderOut(nil)
        searchVC?.reset()
    }

    // MARK: - Build

    private func buildPanel() {
        let vc = SearchViewController()
        vc.onPaste = { [weak self] content in
            self?.hide()
            // Delay: previous app must regain focus before CGEvent ⌘V fires
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                AppDelegate.shared?.paste(content)
            }
        }
        vc.onDismiss = { [weak self] in self?.hide() }
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

        // Dismiss when another app activates (Cmd-Tab, Dock click, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDeactivated),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        panel = p
    }

    @objc private func appDeactivated() { hide() }

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
