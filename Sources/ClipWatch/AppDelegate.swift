import AppKit

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    // Accessible from PanelController's paste callback
    static weak var shared: AppDelegate?

    private let store    = ClipStore.shared
    let monitor          = ClipboardMonitor()
    private let hotkey   = HotkeyManager()
    private let panel    = PanelController()

    private var statusItem:          NSStatusItem!
    private var pendingUpdate:       UpdateInfo?
    private var menuRebuildTimer:    Timer?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        AppDelegate.shared = self

        setupStatusItem()
        monitor.start()

        hotkey.onActivate = { [weak self] in self?.panel.toggle() }
        hotkey.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildMenu),
            name: .clipStoreDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateAvailable(_:)),
            name: .updateAvailable,
            object: nil
        )
        UpdateChecker.checkInBackground()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                accessibilityDescription: "ClipWatch")
            btn.image?.isTemplate = true
        }
        buildMenu()
    }

    @objc func rebuildMenu() {
        // Debounce: coalesce rapid clipStoreDidChange notifications (e.g. programmatic
        // bulk pastes) into a single menu rebuild 200 ms after the last event.
        menuRebuildTimer?.invalidate()
        menuRebuildTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.buildMenu()
        }
    }

    private func buildMenu() {
        let menu   = NSMenu()

        // Update banner — appears only when a newer release is available
        if let update = pendingUpdate {
            let updateItem = NSMenuItem(
                title:  "⬆ Update available: v\(update.tagName)",
                action: #selector(openUpdatePage),
                keyEquivalent: ""
            )
            updateItem.target = self
            menu.addItem(updateItem)
            menu.addItem(.separator())
        }

        let clips  = store.recent(limit: Prefs.menuCount())

        for clip in clips {
            let preview = clip.content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .prefix(60)
            let item = NSMenuItem(
                title:  String(preview),
                action: #selector(menuClipClicked(_:)),
                keyEquivalent: ""
            )
            item.representedObject = clip.content
            item.target = self
            if clip.pinned {
                item.image = NSImage(systemSymbolName: "pin.fill",
                                     accessibilityDescription: nil)
            }
            menu.addItem(item)
        }

        if clips.isEmpty {
            let empty = NSMenuItem(title: "No clips yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        let clearItem = NSMenuItem(title: "Clear History…",
                                   action: #selector(clearAllHistory),
                                   keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Preferences…",
                               action: #selector(openPreferences),
                               keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        let ghItem = NSMenuItem(title: "View on GitHub",
                                action: #selector(openGitHub),
                                keyEquivalent: "")
        ghItem.target = self
        menu.addItem(ghItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ClipWatch",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        statusItem.menu = menu
    }

    @objc private func menuClipClicked(_ sender: NSMenuItem) {
        guard let content = sender.representedObject as? String else { return }
        // Menu item click: dismiss menu first, then paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.paste(content)
        }
    }

    @objc private func updateAvailable(_ note: Notification) {
        pendingUpdate = note.object as? UpdateInfo
        buildMenu()
    }

    @objc private func openGitHub() {
        // Guard prevents crash if URL(string:) ever returns nil (malformed constant).
        guard let url = URL(string: "https://github.com/lswingrover/clipwatch") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openUpdatePage() {
        if let url = pendingUpdate?.releaseURL {
            NSWorkspace.shared.open(url)
        } else {
            UpdateChecker.openReleasePage()
        }
    }

    @objc private func clearAllHistory() {
        let alert = NSAlert()
        alert.messageText     = "Clear all clipboard history?"
        alert.informativeText = "This permanently deletes all clips. Pinned items are also removed. This cannot be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.deleteAll()
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Paste

    /// Places `content` on the general pasteboard, then posts a synthetic ⌘V
    /// `CGEvent` to the HID event tap so it pastes into whatever app was
    /// frontmost before ClipWatch was invoked.
    ///
    /// Call sites must ensure a delay of ≥120 ms has elapsed since the panel
    /// or menu was dismissed. Without the delay, ClipWatch's window may still
    /// own focus when the event fires and ⌘V pastes into nothing.
    ///
    /// This requires Accessibility permission (`AXIsProcessTrusted()`).
    /// HotkeyManager prompts for it on launch; if the user never grants it,
    /// the content is still written to the pasteboard — the user just has to
    /// press ⌘V themselves.
    func paste(_ content: String) {
        NSPasteboard.general.clearContents()
        // setString returns false if the pasteboard is unavailable (e.g. sandboxed denial).
        // Abort rather than synthesizing ⌘V that would paste stale/empty content.
        guard NSPasteboard.general.setString(content, forType: .string) else {
            print("ClipWatch: pasteboard write failed — aborting paste")
            return
        }

        let src     = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9   // kVK_ANSI_V  (Carbon virtual key code for V)
        guard
            let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
            let up   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags   = .maskCommand
        // cghidEventTap injects into the hardware event stream, reaching the
        // frontmost app without going through the event tap filter chain.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
