import AppKit
import MIDIstatCore

/// Resizable window listing every event since launch (or since "Clear Log").
final class LogWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: EventStore
    private let shownCategories: () -> EventCategories
    private let setCategory: (EventCategories, Bool) -> Void
    private let onClear: () -> Void

    private let tableView = LogTableView()
    private let scrollView = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    private let realtimeCheckbox = NSButton(checkboxWithTitle: "Show Clock & Active Sensing", target: nil, action: nil)
    private let aftertouchCheckbox = NSButton(checkboxWithTitle: "Show Aftertouch", target: nil, action: nil)

    private var rows: [MIDIEvent] = []
    private var reloadScheduled = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private enum Column: String, CaseIterable {
        case time = "Time", source = "Device", channel = "Ch", message = "Message"

        var width: CGFloat {
            switch self {
            case .time: return 125
            case .source: return 160
            case .channel: return 34
            case .message: return 360
            }
        }
    }

    init(store: EventStore,
         shownCategories: @escaping () -> EventCategories,
         setCategory: @escaping (EventCategories, Bool) -> Void,
         onClear: @escaping () -> Void) {
        self.store = store
        self.shownCategories = shownCategories
        self.setCategory = setCategory
        self.onClear = onClear

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "MIDIstat — MIDI Log"
        window.minSize = NSSize(width: 640, height: 240)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        window.center()
        window.setFrameAutosaveName("MIDIstatLogWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func buildContent(in window: NSWindow) {
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.rawValue
            tableColumn.width = column.width
            tableColumn.minWidth = 30
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .fullWidth
        tableView.rowHeight = ceil(mono.boundingRectForFont.height) + 2
        tableView.copyHandler = { [weak self] in self?.copySelection() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        realtimeCheckbox.target = self
        realtimeCheckbox.action = #selector(toggleCategory(_:))
        aftertouchCheckbox.target = self
        aftertouchCheckbox.action = #selector(toggleCategory(_:))

        let clearButton = NSButton(title: "Clear Log", target: self, action: #selector(clearLog))
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.keyEquivalent = "\u{1b}"  // Esc

        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [realtimeCheckbox, aftertouchCheckbox, countLabel, spacer, clearButton, closeButton])
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)

        let content = NSView()
        for view in [scrollView, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    // MARK: - Updates

    var isKeyAndVisible: Bool { window?.isVisible == true && window?.isKeyWindow == true }

    func show() {
        guard let window else { return }
        reload(scrollToEnd: true)
        // A menu bar app is usually not the active app: bring the window above
        // other apps' windows explicitly and take the focus.
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activateTakingFocus()
    }

    func closeLog() {
        window?.performClose(nil)
    }

    /// Called for every new event; reloads at most ~10 times per second.
    func eventsDidChange() {
        guard window?.isVisible == true, !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reload(scrollToEnd: self.isScrolledToEnd)
        }
    }

    func settingsDidChange() {
        guard window?.isVisible == true else { return }
        reload(scrollToEnd: true)
    }

    private func reload(scrollToEnd: Bool) {
        let shown = shownCategories()
        realtimeCheckbox.state = shown.contains(.continuousRealtime) ? .on : .off
        aftertouchCheckbox.state = shown.contains(.aftertouch) ? .on : .off
        rows = store.events(including: shown)
        tableView.reloadData()
        updateCountLabel(shown: shown)
        if scrollToEnd, !rows.isEmpty { tableView.scrollRowToVisible(rows.count - 1) }
    }

    private func updateCountLabel(shown: EventCategories) {
        var text = "\(rows.count) event\(rows.count == 1 ? "" : "s")"
        if let hidden = store.hiddenSummary(shown: shown) { text += " · \(hidden)" }
        if rows.count >= store.limit { text += " — showing the most recent \(store.limit)" }
        countLabel.stringValue = text
    }

    private var isScrolledToEnd: Bool {
        let visible = scrollView.contentView.bounds
        return visible.maxY >= tableView.bounds.height - tableView.rowHeight * 2
    }

    // MARK: - Actions

    @objc private func toggleCategory(_ sender: NSButton) {
        let category: EventCategories = sender === aftertouchCheckbox ? .aftertouch : .continuousRealtime
        setCategory(category, sender.state == .on)
    }

    @objc private func clearLog() {
        onClear()
    }

    @objc private func closeWindow() {
        closeLog()
    }

    private func copySelection() {
        let lines = tableView.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }.map { event in
            [Self.timeFormatter.string(from: event.date), event.source ?? "",
             event.channel.map(String.init) ?? "", MIDIFormat.description(of: event.kind)]
                .joined(separator: "\t")
        }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let identifier = tableColumn.identifier
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = identifier
            f.lineBreakMode = .byTruncatingTail
            f.font = column == .source ? .systemFont(ofSize: NSFont.systemFontSize)
                : .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            if column == .channel { f.alignment = .right }
            return f
        }()
        let event = rows[row]
        switch column {
        case .time: field.stringValue = Self.timeFormatter.string(from: event.date)
        case .source: field.stringValue = event.source ?? ""
        case .channel: field.stringValue = event.channel.map(String.init) ?? ""
        case .message: field.stringValue = MIDIFormat.description(of: event.kind)
        }
        return field
    }
}

/// Table view that supports ⌘C (copy selected rows) and ⌘A.
final class LogTableView: NSTableView {
    var copyHandler: (() -> Void)?

    @objc func copy(_ sender: Any?) { copyHandler?() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRowIndexes.count > 0 }
        return super.validateUserInterfaceItem(item)
    }
}
