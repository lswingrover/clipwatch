import AppKit

// MARK: - SearchViewController
//
// The floating panel's content: a search field on top, clip list below.
//
// Key routing strategy:
//   NSEvent.addLocalMonitorForEvents intercepts ↑↓/↩/⎋/⌘P/⌘⌫ before
//   the field editor sees them. This is reliable in NSPanel with
//   .nonactivatingPanel where NSTextFieldDelegate.control(_:textView:doCommandBy:)
//   is not delivered consistently. The monitor is installed when the panel
//   appears (prepareForDisplay) and torn down when it hides (reset) to
//   avoid leaking.
//
// Layout:
//   [🔍 Search clipboard history…                      ]
//   ──────────────────────────────────────────────────
//   [app icon] [content preview...............] [  2h ]
//              [Source App Name               ] [ 📌  ]
//   ──────────────────────────────────────────────────
//   ↑↓ navigate   ↩ paste   ⌘P pin   ⌘⌫ delete   esc dismiss

final class SearchViewController: NSViewController {

    var onPaste:   ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private var clips: [ClipStore.Clip] = []
    private var searchField: NSTextField!
    private var tableView:   NSTableView!
    private var scrollView:  NSScrollView!
    private var emptyLabel:  NSTextField!
    private var keyMonitor:  Any?   // local key-down monitor

    // MARK: - View lifecycle

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 540, height: 440))
        root.blendingMode  = .behindWindow
        root.material      = .popover
        root.state         = .active
        root.wantsLayer    = true
        root.layer?.cornerRadius = 12
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
        icon.image             = NSImage(systemSymbolName: "magnifyingglass",
                                        accessibilityDescription: nil)
        icon.contentTintColor  = .tertiaryLabelColor
        icon.imageScaling      = .scaleProportionallyDown
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
            "↑↓ navigate   ↩ paste   ⌘P pin   ⌘⌫ delete   esc dismiss")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.textColor = .quaternaryLabelColor
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

    func prepareForDisplay() {
        searchField.stringValue = ""
        reload(query: "")
        view.window?.makeFirstResponder(searchField)
        installKeyMonitor()
    }

    func reset() {
        removeKeyMonitor()
        searchField.stringValue = ""
        clips = []
        tableView.reloadData()
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

    /// Returns nil to consume the event; returns the event to let it fall through.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 125: moveSelection(by: 1);  return nil         // ↓
        case 126: moveSelection(by: -1); return nil         // ↑
        case 36, 76: pasteSelected();    return nil         // ↩  numpad-↩
        case 53:  onDismiss?();          return nil         // ⎋
        case 35 where mods == .command:                     // ⌘P
            togglePinSelected(); return nil
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
        onPaste?(clips[row].content)
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
        cell.configure(with: clips[row])
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
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        [appIcon, preview, subtitle, timestamp, pinIcon].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        // App icon — small, rounded
        appIcon.imageScaling      = .scaleProportionallyDown
        appIcon.wantsLayer        = true
        appIcon.layer?.cornerRadius = 4
        appIcon.layer?.masksToBounds = true

        // Content preview — line 1, normal weight
        preview.font                 = .systemFont(ofSize: 13, weight: .regular)
        preview.textColor            = .labelColor
        preview.lineBreakMode        = .byTruncatingTail
        preview.maximumNumberOfLines = 1

        // Source app name — line 2, lighter
        subtitle.font                 = .systemFont(ofSize: 11)
        subtitle.textColor            = .tertiaryLabelColor
        subtitle.lineBreakMode        = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1

        // Timestamp — top-right
        timestamp.font      = .systemFont(ofSize: 11)
        timestamp.textColor = .secondaryLabelColor
        timestamp.alignment = .right

        // Pin badge — bottom-right
        pinIcon.image            = NSImage(systemSymbolName: "pin.fill",
                                           accessibilityDescription: nil)
        pinIcon.contentTintColor = .systemOrange
        pinIcon.imageScaling     = .scaleProportionallyDown

        [appIcon, preview, subtitle, timestamp, pinIcon].forEach { addSubview($0) }

        NSLayoutConstraint.activate([
            // App icon — left column, centered vertically
            appIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            appIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 22),
            appIcon.heightAnchor.constraint(equalToConstant: 22),

            // Timestamp — top-right
            timestamp.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            timestamp.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            timestamp.widthAnchor.constraint(equalToConstant: 68),

            // Pin icon — bottom-right
            pinIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            pinIcon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            pinIcon.widthAnchor.constraint(equalToConstant: 9),
            pinIcon.heightAnchor.constraint(equalToConstant: 11),

            // Preview — top text line
            preview.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 10),
            preview.trailingAnchor.constraint(equalTo: timestamp.leadingAnchor, constant: -8),
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            // Subtitle — bottom text line
            subtitle.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            subtitle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    func configure(with clip: ClipStore.Clip) {
        // Collapse newlines into a readable one-liner
        let oneLiner = clip.content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ↵ ")
        preview.stringValue   = oneLiner
        timestamp.stringValue = relativeTime(clip.ts)
        pinIcon.isHidden      = !clip.pinned

        // Source app icon + display name
        if let bundleId = clip.source,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            appIcon.image = NSWorkspace.shared.icon(forFile: appURL.path)
            let info = Bundle(url: appURL)?.infoDictionary
            let name = info?["CFBundleDisplayName"] as? String
                    ?? info?["CFBundleName"] as? String
                    ?? bundleId
            subtitle.stringValue = name
        } else {
            appIcon.image        = nil
            subtitle.stringValue = clip.source ?? ""
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
