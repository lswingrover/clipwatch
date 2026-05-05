import AppKit
import UniformTypeIdentifiers
import ServiceManagement

// MARK: - ExclusionItem
//
// Unified model for the "Never capture from" list.
// App entries store a bundle ID; URL entries store a domain/path pattern.

enum ExclusionItem {
    case app(bundleID: String)
    case url(pattern: String)
}

// MARK: - PreferencesWindowController

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private init() {
        let vc = PreferencesViewController()
        let win = NSWindow(contentViewController: vc)
        win.title = "ClipWatch Preferences"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 560, height: 520))
        win.minSize = NSSize(width: 460, height: 420)
        win.center()
        super.init(window: win)
        win.delegate = self
    }
    required init?(coder: NSCoder) { return nil }  // not used; prevents fatalError in production

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
    }
}

// MARK: - PreferencesViewController
//
// Full Auto Layout:
//   • All fixed controls in a vertical NSStackView pinned to the top.
//   • Exclusion scroll view fills remaining height between controls and bottom buttons.
//   • Drag .app bundles onto the table to add app exclusions.
//   • + button → popup menu → "Add App…" (NSOpenPanel) or "Add URL or Domain…" (sheet).

final class PreferencesViewController: NSViewController {

    private var shortcutField:       ShortcutRecorderField!
    private var menuCountStepper:    NSStepper!
    private var menuCountLabel:      NSTextField!
    private var pollIntervalStepper: NSStepper!
    private var pollIntervalLabel:   NSTextField!
    private var retentionSlider:     NSSlider!
    private var retentionLabel:      NSTextField!
    private var screenSegment:       NSSegmentedControl!
    private var loginToggle:         NSButton!
    private var secureModeToggle:    NSButton!
    private var unlockDurationPopup: NSPopUpButton!
    private var excludedTable:       NSTableView!
    private var items:               [ExclusionItem] = []

    private let unlockDurationValues = [0, 300, 900, 1800, 3600, -1]
    private let unlockDurationLabels = ["Every use", "5 minutes", "15 minutes", "30 minutes", "1 hour", "Until app restarts"]

    private let margin: CGFloat     = 20
    private let labelWidth: CGFloat = 180

    override func loadView() {
        view = NSView()
        buildUI()
        loadValues()
    }

    // MARK: - UI construction

    private func buildUI() {
        // ── Top controls stack ─────────────────────────────────────────────────
        let controlsStack = NSStackView()
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.orientation = .vertical
        controlsStack.alignment   = .leading
        controlsStack.spacing     = 8
        view.addSubview(controlsStack)

        // Hotkey
        controlsStack.addArrangedSubview(sectionHeader("Hotkey"))
        shortcutField = ShortcutRecorderField(frame: .zero)
        shortcutField.translatesAutoresizingMaskIntoConstraints = false
        shortcutField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        shortcutField.heightAnchor.constraint(equalToConstant: 26).isActive = true
        controlsStack.addArrangedSubview(makeRow("Open panel", shortcutField))
        controlsStack.setCustomSpacing(14, after: controlsStack.arrangedSubviews.last!)

        // Menu
        controlsStack.addArrangedSubview(sectionHeader("Menu"))
        menuCountLabel   = NSTextField(labelWithString: "10")
        menuCountStepper = NSStepper()
        menuCountStepper.minValue  = 5
        menuCountStepper.maxValue  = 25
        menuCountStepper.increment = 1
        menuCountStepper.target    = self
        menuCountStepper.action    = #selector(stepperChanged)
        let stepperStack = NSStackView(views: [menuCountLabel, menuCountStepper])
        stepperStack.orientation = .horizontal
        stepperStack.spacing     = 4
        controlsStack.addArrangedSubview(makeRow("Recent items in menu", stepperStack))
        controlsStack.setCustomSpacing(14, after: controlsStack.arrangedSubviews.last!)

        // Monitoring
        controlsStack.addArrangedSubview(sectionHeader("Monitoring"))
        pollIntervalLabel   = NSTextField(labelWithString: "1.0 s")
        pollIntervalStepper = NSStepper()
        pollIntervalStepper.minValue  = 0.5
        pollIntervalStepper.maxValue  = 5.0
        pollIntervalStepper.increment = 0.5
        pollIntervalStepper.target    = self
        pollIntervalStepper.action    = #selector(pollIntervalChanged)
        let pollStack = NSStackView(views: [pollIntervalLabel, pollIntervalStepper])
        pollStack.orientation = .horizontal
        pollStack.spacing     = 4
        controlsStack.addArrangedSubview(makeRow("Clipboard check interval", pollStack))
        controlsStack.setCustomSpacing(14, after: controlsStack.arrangedSubviews.last!)

        // History
        controlsStack.addArrangedSubview(sectionHeader("History"))
        retentionLabel = NSTextField(labelWithString: "365 days")
        retentionLabel.translatesAutoresizingMaskIntoConstraints = false
        retentionLabel.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        retentionSlider = NSSlider()
        retentionSlider.minValue = 30
        retentionSlider.maxValue = 730
        retentionSlider.target   = self
        retentionSlider.action   = #selector(sliderChanged)
        retentionSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlsStack.addArrangedSubview(makeRow(retentionLabel, retentionSlider))

        // Panel screen
        screenSegment = NSSegmentedControl(
            labels: ["Active App", "Cursor"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(screenModeChanged)
        )
        controlsStack.addArrangedSubview(makeRow("Panel appears on", screenSegment))
        controlsStack.setCustomSpacing(14, after: controlsStack.arrangedSubviews.last!)

        // Launch at login
        loginToggle = NSButton(checkboxWithTitle: "Launch ClipWatch at login",
                               target: self, action: #selector(loginToggled))
        controlsStack.addArrangedSubview(loginToggle)
        controlsStack.setCustomSpacing(14, after: controlsStack.arrangedSubviews.last!)

        // Security
        controlsStack.addArrangedSubview(sectionHeader("Security"))
        secureModeToggle = NSButton(
            checkboxWithTitle: "Require Touch ID to open panel",
            target: self,
            action: #selector(secureModeToggled)
        )
        controlsStack.addArrangedSubview(secureModeToggle)

        unlockDurationPopup = NSPopUpButton()
        for label in unlockDurationLabels { unlockDurationPopup.addItem(withTitle: label) }
        unlockDurationPopup.target = self
        unlockDurationPopup.action = #selector(unlockDurationChanged)
        controlsStack.addArrangedSubview(makeRow("Stay unlocked for", unlockDurationPopup))
        controlsStack.setCustomSpacing(14, after: controlsStack.arrangedSubviews.last!)

        // Data
        controlsStack.addArrangedSubview(sectionHeader("Data"))
        let clearBtn = NSButton(title: "Clear All History…",
                                target: self, action: #selector(clearAllHistory))
        clearBtn.bezelStyle = .rounded
        controlsStack.addArrangedSubview(clearBtn)
        controlsStack.setCustomSpacing(18, after: controlsStack.arrangedSubviews.last!)

        // Exclusions header
        controlsStack.addArrangedSubview(sectionHeader("Never capture from"))

        // ── Exclusions table (expands with window) ─────────────────────────────
        excludedTable = NSTableView()
        excludedTable.headerView      = nil
        excludedTable.rowHeight       = 22
        excludedTable.focusRingType   = .none
        excludedTable.intercellSpacing = NSSize(width: 0, height: 2)
        let exCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        exCol.isEditable = false
        excludedTable.addTableColumn(exCol)
        excludedTable.delegate   = self
        excludedTable.dataSource = self

        // Accept .app drops from Finder / Dock
        excludedTable.registerForDraggedTypes([.fileURL])

        let exScroll = NSScrollView()
        exScroll.translatesAutoresizingMaskIntoConstraints = false
        exScroll.documentView        = excludedTable
        exScroll.hasVerticalScroller = true
        exScroll.borderType          = .bezelBorder
        view.addSubview(exScroll)

        // ── +/− buttons ────────────────────────────────────────────────────────
        let addBtn = NSButton(title: "+", target: self, action: #selector(addExcluded(_:)))
        addBtn.bezelStyle = .regularSquare
        let remBtn = NSButton(title: "−", target: self, action: #selector(removeExcluded))
        remBtn.bezelStyle = .regularSquare
        let btnRow = NSStackView(views: [addBtn, remBtn])
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        btnRow.orientation = .horizontal
        btnRow.spacing = 4
        view.addSubview(btnRow)

        // ── GitHub link ────────────────────────────────────────────────────────
        let ghLink = NSButton(title: "", target: self, action: #selector(openGitHub))
        ghLink.isBordered = false
        ghLink.translatesAutoresizingMaskIntoConstraints = false
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.linkColor,
            .font: NSFont.systemFont(ofSize: 11),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        ghLink.attributedTitle = NSAttributedString(
            string: "github.com/lswingrover/clipwatch",
            attributes: linkAttrs
        )
        view.addSubview(ghLink)

        // ── Constraints ────────────────────────────────────────────────────────
        NSLayoutConstraint.activate([
            // Controls stack: flush top-left, full width
            controlsStack.topAnchor.constraint(equalTo: view.topAnchor, constant: margin),
            controlsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            controlsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            // Scroll view: below controls, expands to fill remaining height
            exScroll.topAnchor.constraint(equalTo: controlsStack.bottomAnchor, constant: 8),
            exScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            exScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            exScroll.bottomAnchor.constraint(equalTo: btnRow.topAnchor, constant: -6),

            // +/− buttons: bottom-trailing, above GitHub link
            btnRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            btnRow.bottomAnchor.constraint(equalTo: ghLink.topAnchor, constant: -6),

            // GitHub link: bottom-leading corner
            ghLink.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            ghLink.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - Layout helpers

    private func sectionHeader(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .boldSystemFont(ofSize: 13)
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func makeRow(_ labelText: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: labelText)
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        return makeRow(label, control)
    }

    private func makeRow(_ left: NSView, _ right: NSView) -> NSView {
        left.translatesAutoresizingMaskIntoConstraints  = false
        right.translatesAutoresizingMaskIntoConstraints = false
        right.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [left, right])
        stack.orientation  = .horizontal
        stack.alignment    = .centerY
        stack.spacing      = 12
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: - Data model

    private func buildItems() {
        let apps = UserDefaults.standard.stringArray(forKey: Prefs.excludedApps) ?? Prefs.defaultExcludedApps
        let urls = UserDefaults.standard.stringArray(forKey: Prefs.excludedURLs) ?? []
        items = apps.map { .app(bundleID: $0) } + urls.map { .url(pattern: $0) }
    }

    private func saveItems() {
        let apps = items.compactMap { item -> String? in
            guard case .app(let bid) = item else { return nil }
            return bid
        }
        let urls = items.compactMap { item -> String? in
            guard case .url(let pat) = item else { return nil }
            return pat
        }
        UserDefaults.standard.set(apps, forKey: Prefs.excludedApps)
        UserDefaults.standard.set(urls, forKey: Prefs.excludedURLs)
    }

    // MARK: - Load values

    private func loadValues() {
        shortcutField.loadFromDefaults()

        let count = Prefs.menuCount()
        menuCountStepper.intValue  = Int32(count)
        menuCountLabel.stringValue = "\(count)"

        let interval = Prefs.pollIntervalSeconds()
        pollIntervalStepper.doubleValue = interval
        pollIntervalLabel.stringValue   = pollIntervalText(interval)

        let days = UserDefaults.standard.integer(forKey: Prefs.retentionDays)
        retentionSlider.intValue   = Int32(days > 0 ? days : 365)
        retentionLabel.stringValue = "\(retentionSlider.intValue) days"

        screenSegment.selectedSegment = Prefs.screenMode() == "cursor" ? 1 : 0

        buildItems()
        excludedTable.reloadData()

        if #available(macOS 13.0, *) {
            loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }

        secureModeToggle.state = Prefs.isSecureModeEnabled() ? .on : .off

        let storedSecs = Prefs.unlockDurationSeconds()
        let idx = unlockDurationValues.firstIndex(of: storedSecs) ?? 0
        unlockDurationPopup.selectItem(at: idx)
    }

    // MARK: - Actions

    @objc private func stepperChanged() {
        let v = Int(menuCountStepper.intValue)
        menuCountLabel.stringValue = "\(v)"
        UserDefaults.standard.set(v, forKey: Prefs.menuItemCount)
        NotificationCenter.default.post(name: .clipStoreDidChange, object: nil)
    }

    @objc private func pollIntervalChanged() {
        let v = pollIntervalStepper.doubleValue
        pollIntervalLabel.stringValue = pollIntervalText(v)
        UserDefaults.standard.set(v, forKey: Prefs.pollInterval)
        // Apply immediately — no restart required
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.monitor.restart()
        }
    }

    private func pollIntervalText(_ seconds: Double) -> String {
        seconds == 1.0 ? "1 s" : String(format: "%.1f s", seconds)
    }

    @objc private func sliderChanged() {
        let v = Int(retentionSlider.intValue)
        retentionLabel.stringValue = "\(v) days"
        UserDefaults.standard.set(v, forKey: Prefs.retentionDays)
    }

    @objc private func screenModeChanged() {
        let mode = screenSegment.selectedSegment == 0 ? "activeApp" : "cursor"
        UserDefaults.standard.set(mode, forKey: Prefs.screenFocusMode)
    }

    @objc private func secureModeToggled() {
        UserDefaults.standard.set(secureModeToggle.state == .on, forKey: Prefs.secureMode)
    }

    @objc private func unlockDurationChanged() {
        let idx = unlockDurationPopup.indexOfSelectedItem
        guard idx >= 0, idx < unlockDurationValues.count else { return }
        UserDefaults.standard.set(unlockDurationValues[idx], forKey: Prefs.unlockDuration)
    }

    @objc private func openGitHub() {
        // Guard prevents crash if URL(string:) returns nil (malformed constant).
        guard let url = URL(string: "https://github.com/lswingrover/clipwatch") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func clearAllHistory() {
        let alert = NSAlert()
        alert.messageText     = "Clear all clipboard history?"
        alert.informativeText = "This permanently deletes all clips. Pinned items are also removed. This cannot be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                ClipStore.shared.deleteAll()
            }
        }
    }

    @objc private func loginToggled() {
        if #available(macOS 13.0, *) {
            do {
                if loginToggle.state == .on {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Launch at login error: \(error)")
            }
        }
    }

    /// Shows a popup menu with "Add App…" and "Add URL or Domain…".
    @objc private func addExcluded(_ sender: NSButton) {
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "Add App…",
                                 action: #selector(addApp),
                                 keyEquivalent: "")
        appItem.target = self
        let urlItem = NSMenuItem(title: "Add URL or Domain…",
                                 action: #selector(addURLPattern),
                                 keyEquivalent: "")
        urlItem.target = self
        menu.addItem(appItem)
        menu.addItem(urlItem)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 2),
                   in: sender)
    }

    /// Opens an NSOpenPanel filtered to .app bundles.
    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes     = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles          = true
        panel.canChooseDirectories    = false
        panel.directoryURL            = URL(fileURLWithPath: "/Applications")
        panel.prompt                  = "Exclude"
        panel.message                 = "Choose apps to exclude from clipboard capture:"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            panel.urls.forEach { self?.addAppURL($0) }
        }
    }

    /// Sheet for entering a domain/URL pattern.
    @objc private func addURLPattern() {
        let alert = NSAlert()
        alert.messageText     = "Add URL exclusion"
        alert.informativeText = """
            Enter a domain or URL pattern:

            example.com          — all pages and subdomains
            sub.example.com      — only that subdomain
            example.com/path     — only that path and below
            """
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "example.com"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let pattern = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else { return }
            self?.addURLPatternString(pattern)
        }
    }

    @objc private func removeExcluded() {
        let row = excludedTable.selectedRow
        guard row >= 0, row < items.count else { return }
        items.remove(at: row)
        saveItems()
        excludedTable.reloadData()
    }

    // MARK: - Mutation helpers

    private func addAppURL(_ url: URL) {
        guard url.pathExtension == "app",
              let bundle = Bundle(url: url),
              let bid    = bundle.bundleIdentifier else { return }
        addAppBundleID(bid)
    }

    func addAppBundleID(_ bid: String) {
        let exists = items.contains { if case .app(let b) = $0 { return b == bid }; return false }
        guard !exists else { return }
        items.append(.app(bundleID: bid))
        saveItems()
        excludedTable.reloadData()
    }

    private func addURLPatternString(_ pattern: String) {
        let exists = items.contains { if case .url(let p) = $0 { return p == pattern }; return false }
        guard !exists else { return }
        items.append(.url(pattern: pattern))
        saveItems()
        excludedTable.reloadData()
    }
}

// MARK: - Table data source + delegate

extension PreferencesViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        makeCellView(for: items[row])
    }

    // MARK: Drag-to-add (.app bundles from Finder / Dock)

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(-1, dropOperation: .on) // highlight whole table
        let pb = info.draggingPasteboard
        guard pb.canReadObject(forClasses: [NSURL.self], options: nil) else { return [] }
        return .copy
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let pb = info.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        else { return false }
        var added = false
        for url in urls where url.pathExtension == "app" {
            if let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
                addAppBundleID(bid)
                added = true
            }
        }
        return added
    }

    // MARK: Cell view

    private func makeCellView(for item: ExclusionItem) -> NSView {
        let container = NSView()
        let icon  = NSImageView()
        let label = NSTextField(labelWithString: "")

        icon.translatesAutoresizingMaskIntoConstraints  = false
        label.translatesAutoresizingMaskIntoConstraints = false

        icon.imageScaling            = .scaleProportionallyDown
        icon.wantsLayer              = true
        icon.layer?.cornerRadius     = 3
        icon.layer?.masksToBounds    = true

        label.font          = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail

        switch item {
        case .app(let bundleID):
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                icon.image = NSWorkspace.shared.icon(forFile: appURL.path)
                let info   = Bundle(url: appURL)?.infoDictionary
                let name   = info?["CFBundleDisplayName"] as? String
                          ?? info?["CFBundleName"] as? String
                          ?? bundleID
                label.stringValue = name
            } else {
                icon.image        = NSImage(systemSymbolName: "app.badge.questionmark",
                                            accessibilityDescription: nil)
                label.stringValue = bundleID
                label.textColor   = .secondaryLabelColor
            }

        case .url(let pattern):
            icon.image            = NSImage(systemSymbolName: "globe",
                                            accessibilityDescription: nil)
            icon.contentTintColor = .systemBlue
            label.stringValue     = pattern
        }

        container.addSubview(icon)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
}

// MARK: - ShortcutRecorderField
//
// Custom NSControl (NOT NSTextField) so mouseDown and keyDown are delivered
// directly without the field-editor machinery.
//
// Usage:
//   1. Click — enters recording mode (accent border, prompt text)
//   2. Press any combo with ≥ 1 modifier — saves and exits
//   3. Esc with no modifier — cancels without changing hotkey

final class ShortcutRecorderField: NSControl {

    private let keyNames: [Int: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",
        11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
        31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",
        18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",25:"9",26:"7",28:"8",29:"0",
        47:".",44:"/",27:"-",24:"=",33:"[",30:"]",
        48:"Tab",49:"Space",36:"↩",51:"⌫",53:"Esc",
        123:"←",124:"→",125:"↓",126:"↑",
    ]

    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius    = 5
        layer?.borderWidth     = 1
        applyBorderColor()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
    required init?(coder: NSCoder) { return nil }  // not used; prevents fatalError in production

    func loadFromDefaults() { needsDisplay = true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let text: String
        let color: NSColor
        if isRecording {
            text  = "Press shortcut…"
            color = .secondaryLabelColor
        } else {
            let kc   = Prefs.hotkeyVirtualKey()
            let mods = NSEvent.ModifierFlags(rawValue: UInt(Prefs.hotkeyModifierFlags()))
            text  = describe(keyCode: kc, modifiers: mods)
            color = .labelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: 13),
            .foregroundColor: color,
        ]
        let s  = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: (bounds.width  - sz.width)  / 2,
                           y: (bounds.height - sz.height) / 2))
    }

    // MARK: Focus

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        isRecording = true
        applyBorderColor()
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        isRecording = false
        applyBorderColor()
        needsDisplay = true
        return true
    }

    private func applyBorderColor() {
        layer?.borderColor = (isRecording
            ? NSColor.controlAccentColor
            : NSColor.separatorColor).cgColor
    }

    // MARK: Key capture

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Esc with no modifier = cancel
        if event.keyCode == 53, mods.isEmpty {
            window?.makeFirstResponder(nil)
            return
        }

        // Require at least one modifier
        guard !mods.isEmpty else { return }

        let kc = Int(event.keyCode)
        UserDefaults.standard.set(kc,                 forKey: Prefs.hotkeyKeyCode)
        UserDefaults.standard.set(Int(mods.rawValue), forKey: Prefs.hotkeyModifiers)
        needsDisplay = true
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
        window?.makeFirstResponder(nil)
    }

    // MARK: Formatting

    private func describe(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += keyNames[keyCode] ?? "?"
        return s
    }
}
