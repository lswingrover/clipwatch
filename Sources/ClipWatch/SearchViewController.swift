import AppKit

// MARK: - SearchViewController
//
// The floating panel's content: search field on top, clip list below.
//
// Key routing:
//   NSEvent.addLocalMonitorForEvents intercepts ↑↓/↩/⎋/⌘P/⌘S/⌘⌫/hotkey
//   before the field editor sees them. Installed when the panel appears
//   (prepareForDisplay) and torn down on reset() to avoid leaking.
//
// Sensitive clips:
//   ClipCellView renders locked state when clip.sensitive && !isAuthenticated.
//   Pressing ↩ on a locked clip triggers onAuthNeeded. On success, isAuthenticated
//   flips true, the table reloads to show content, and the paste fires.
//   ⌘S toggles the sensitive flag on the selected clip manually.
//
// Layout:
//   [🔍 Search clipboard history…                            ]
//   ─────────────────────────────────────────────────────────
//   [app icon] [content preview...........................] [2h]
//              [Source App Name                          ] [📌]
//   ─────────────────────────────────────────────────────────
//   ↑↓ navigate   ↩ paste   ⌘P pin   ⌘S sensitive   ⌘⌫ delete   esc dismiss

final class SearchViewController: NSViewController {

    var onPaste:     ((String) -> Void)?
    var onDismiss:   (() -> Void)?
    /// Called when the user tries to act on a sensitive clip while unauthenticated.
    /// The closure receives a completion block to call after auth succeeds.
    var onAuthNeeded: ((@escaping () -> Void) -> Void)?

    private var clips:       [ClipStore.Clip] = []
    private var searchField: NSTextField!
    private var tableView:   NSTableView!
    private var scrollView:  NSScrollView!
    private var emptyLabel:  NSTextField!
    private var keyMonitor:  Any?

    /// Reflects the session auth state set by PanelController.
    var isAuthenticated = false

    // MARK: - View lifecycle

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 540, height: 440))
        root.blendingMode = .behindWindow
        root.material     = .popover
        root.state        = .active
        root.wantsLayer   = true
        root.layer?.cornerRadius  = 12
        root.layer?.masksToBounds = true
        view = root

        setupSearchArea()
        setupSeparator()
        setupTableView()
        setupEmptyLabel()
        setupHintBar()
    }

    private func setupSearchArea() {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image            = NSImage(systemSymbolName: "magnifyingglass",
                                        accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor
        icon.imageScaling     = .scaleProportionallyDown
        view.addSubview(icon)

        searchField = NSTextField(frame: .zero)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search clipboard history…"
        searchField.isBordered        = false
        searchField.drawsBackground   = false
        searchField.focusRingType     = .none
        searchField.font              = .systemFont(ofSize: 15, weight: .regular)
        searchField.textColor         = .labelColor
        searchField.delegate          = self
        view.addSubview(searchField)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func setupSeparator() {
        let sep = NSBox()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.boxType = .separator
        view.addSubview(sep)
        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: view.topAnchor, constant: 54),
            sep.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func setupTableView() {
        tableView = NSTableView()
        tableView.headerView              = nil
        tableView.rowHeight               = 52
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection    = false
        tableView.focusRingType           = .none
        tableView.backgroundColor         = .clear
        tableView.intercellSpacing        = NSSize(width: 0, height: 0)
        tableView.usesAutomaticRowHeights = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        col.isEditable = false
        tableView.addTableColumn(col)

        tableView.delegate     = self
        tableView.dataSource   = self
        tableView.target       = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView        = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground     = false
        scrollView.borderType          = .noBorder
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 55),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -28),
        ])
    }

    private func setupEmptyLabel() {
        emptyLabel = NSTextField(labelWithString: "No clips found")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font      = .systemFont(ofSize: 13)
        emptyLabel.isHidden  = true
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 14),
        ])
    }

    private func setupHintBar() {
        let hint = NSTextField(labelWithString:
            "↑↓ navigate   ↩ paste   ⌘A select all   ⌘P pin   ⌘S sensitive   ⌘⌫ delete   esc dismiss")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.textColor = .secondaryLabelColor
        hint.font      = .monospacedSystemFont(ofSize: 10, weight: .regular)
        hint.alignment = .center
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            hint.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -7),
        ])
    }

    // MARK: - Display

    func prepareForDisplay(isAuthenticated: Bool = false) {
        self.isAuthenticated   = isAuthenticated
        searchField.stringValue = ""
        reload(query: "")
        focusSearchField()
        installKeyMonitor()
    }

    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    func reset() {
        removeKeyMonitor()
        searchField.stringValue = ""
        clips = []
        tableView.reloadData()
        isAuthenticated = false
    }

    // MARK: - Key monitor

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// Returns nil to consume; returns the event to let it fall through.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Hotkey re-press while panel is visible → toggle dismiss
        let hkKey  = Prefs.hotkeyVirtualKey()
        let hkMods = Prefs.hotkeyModifierFlags()
        if Int(event.keyCode) == hkKey, Int(mods.rawValue) == hkMods {
            onDismiss?()
            return nil
        }

        switch event.keyCode {
        case 125: moveSelection(by: 1);  return nil         // ↓
        case 126: moveSelection(by: -1); return nil         // ↑
        case 36, 76: pasteSelected();    return nil         // ↩  numpad-↩
        case 53:  onDismiss?();          return nil         // ⎋
        case 0  where mods == .command:                     // ⌘A — select all in search field
            searchField.currentEditor()?.selectAll(nil)
            return nil
        case 35 where mods == .command:                     // ⌘P
            togglePinSelected(); return nil
        case 1  where mods == .command:                     // ⌘S
            toggleSensitiveSelected(); return nil
        case 51 where mods == .command:                     // ⌘⌫
            deleteSelected(); return nil
        default:
            return event
        }
    }

    // MARK: - Data

    private func reload(query: String) {
        clips = query.isEmpty
            ? ClipStore.shared.recent(limit: 200)
            : ClipStore.shared.search(query: query, limit: 200)
        tableView.reloadData()
        emptyLabel.isHidden = !clips.isEmpty
        if !clips.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - Actions

    @objc private func rowDoubleClicked() { pasteSelected() }

    private func pasteSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < clips.count else { return }
        let clip = clips[row]

        // Sensitive clip and not yet authenticated → request auth, then paste
        if clip.sensitive && !isAuthenticated {
            onAuthNeeded? { [weak self] in
                guard let self else { return }
                self.isAuthenticated = true
                self.tableView.reloadData()          // reveal content
                self.onPaste?(clip.content)
            }
            return
        }
        onPaste?(clip.content)
    }

    private func moveSelection(by delta: Int) {
        guard !clips.isEmpty else { return }
        let next = max(0, min(clips.count - 1, tableView.selectedRow + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func deleteSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < clips.count else { return }
        ClipStore.shared.delete(id: clips[row].id)
        reload(query: searchField.stringValue)
        NotificationCenter.default.post(name: .clipStoreDidChange, object: nil)
    }

    private func togglePinSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < clips.count else { return }
        ClipStore.shared.togglePin(id: clips[row].id)
        reload(query: searchField.stringValue)
        NotificationCenter.default.post(name: .clipStoreDidChange, object: nil)
    }

    private func toggleSensitiveSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < clips.count else { return }
        let clip = clips[row]
        ClipStore.shared.markSensitive(id: clip.id, sensitive: !clip.sensitive)
        reload(query: searchField.stringValue)
    }
}

// MARK: - NSTextFieldDelegate

extension SearchViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reload(query: searchField.stringValue)
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension SearchViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { clips.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = ClipCellView()
        cell.configure(with: clips[row], isAuthenticated: isAuthenticated)
        return cell
    }
}

// MARK: - ClipCellView

final class ClipCellView: NSView {
    private let appIcon   = NSImageView()
    private let preview   = NSTextField(labelWithString: "")
    private let subtitle  = NSTextField(labelWithString: "")
    private let timestamp = NSTextField(labelWithString: "")
    private let pinIcon   = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { return nil }  // not used; prevents fatalError in production

    private func setup() {
        [appIcon, preview, subtitle, timestamp, pinIcon].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        appIcon.imageScaling         = .scaleProportionallyDown
        appIcon.wantsLayer           = true
        appIcon.layer?.cornerRadius  = 4
        appIcon.layer?.masksToBounds = true

        preview.font                 = .systemFont(ofSize: 13, weight: .regular)
        preview.textColor            = .labelColor
        preview.lineBreakMode        = .byTruncatingTail
        preview.maximumNumberOfLines = 1

        subtitle.font                 = .systemFont(ofSize: 11)
        subtitle.textColor            = .tertiaryLabelColor
        subtitle.lineBreakMode        = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1

        timestamp.font      = .systemFont(ofSize: 11)
        timestamp.textColor = .secondaryLabelColor
        timestamp.alignment = .right

        pinIcon.image            = NSImage(systemSymbolName: "pin.fill",
                                           accessibilityDescription: nil)
        pinIcon.contentTintColor = .systemOrange
        pinIcon.imageScaling     = .scaleProportionallyDown

        [appIcon, preview, subtitle, timestamp, pinIcon].forEach { addSubview($0) }

        NSLayoutConstraint.activate([
            appIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            appIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 22),
            appIcon.heightAnchor.constraint(equalToConstant: 22),

            timestamp.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            timestamp.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            timestamp.widthAnchor.constraint(equalToConstant: 68),

            pinIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            pinIcon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            pinIcon.widthAnchor.constraint(equalToConstant: 9),
            pinIcon.heightAnchor.constraint(equalToConstant: 11),

            preview.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 10),
            preview.trailingAnchor.constraint(equalTo: timestamp.leadingAnchor, constant: -8),
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            subtitle.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            subtitle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    func configure(with clip: ClipStore.Clip, isAuthenticated: Bool) {
        // ── Sensitive + not yet authenticated → locked card ───────────────────
        if clip.sensitive && !isAuthenticated {
            appIcon.image            = NSImage(systemSymbolName: "lock.fill",
                                               accessibilityDescription: nil)
            appIcon.contentTintColor = .systemOrange
            appIcon.layer?.cornerRadius = 0

            preview.stringValue = "Sensitive"
            preview.textColor   = .secondaryLabelColor
            preview.font        = .systemFont(ofSize: 13, weight: .medium)

            subtitle.stringValue = "↩ authenticate & paste   ⌘S to untag"
            subtitle.textColor   = .tertiaryLabelColor

            timestamp.stringValue = relativeTime(clip.ts)
            pinIcon.isHidden      = true
            return
        }

        // ── Normal clip ────────────────────────────────────────────────────────
        appIcon.contentTintColor = nil     // clear any tint from locked state
        appIcon.layer?.cornerRadius = 4
        preview.textColor = .labelColor
        preview.font      = .systemFont(ofSize: 13, weight: .regular)

        let oneLiner = clip.content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ↵ ")
        preview.stringValue   = oneLiner
        timestamp.stringValue = relativeTime(clip.ts)
        pinIcon.isHidden      = !clip.pinned

        // Sensitive badge even when authenticated (faint indicator)
        if clip.sensitive {
            subtitle.stringValue = "🔒  Sensitive"
            subtitle.textColor   = .secondaryLabelColor
            appIcon.image        = NSImage(systemSymbolName: "lock.fill",
                                           accessibilityDescription: nil)
            appIcon.contentTintColor = .tertiaryLabelColor
            appIcon.layer?.cornerRadius = 0
        } else if let bundleId = clip.source,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            appIcon.image = NSWorkspace.shared.icon(forFile: appURL.path)
            let info = Bundle(url: appURL)?.infoDictionary
            let name = info?["CFBundleDisplayName"] as? String
                    ?? info?["CFBundleName"] as? String
                    ?? bundleId
            subtitle.stringValue = name
            subtitle.textColor   = .tertiaryLabelColor
        } else {
            appIcon.image        = nil
            subtitle.stringValue = clip.source ?? ""
            subtitle.textColor   = .tertiaryLabelColor
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        switch s {
        case 0..<60:         return "now"
        case 60..<3600:      return "\(s / 60)m"
        case 3600..<86400:   return "\(s / 3600)h"
        case 86400..<604800: return "\(s / 86400)d"
        default:
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return f.string(from: date)
        }
    }
}
