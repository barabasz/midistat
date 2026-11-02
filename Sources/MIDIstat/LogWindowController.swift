import AppKit
import MIDIstatCore

/// Resizable window listing every event since launch (or since "Clear Log"),
/// with a filter field at the top.
final class LogWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: EventStore
    struct Settings {
        var aftertouch: Bool
        var alwaysOnTop: Bool
    }

    private(set) var settings: Settings
    private let saveSettings: (Settings) -> Void
    private let onClear: () -> Void
    /// Names of the connected MIDI inputs, so the Device column fits them before any event arrives.
    private let deviceNames: () -> [String]
    /// The columns are fitted the first time the window is shown in a session.
    private var columnsFitted = false

    private let tableView = LogTableView()
    private let scrollView = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let aftertouchCheckbox = NSButton(checkboxWithTitle: "Aftertouch", target: nil, action: nil)
    private let onTopCheckbox = NSButton(checkboxWithTitle: "Always on Top", target: nil, action: nil)

    /// The rows are read straight from the store, never copied: keeping a
    /// reference to the store's array would make every append copy the whole
    /// history. With a filter, `matches` holds the indexes of the matching events.
    private var matches: [Int]?
    private var rowCount = 0
    /// What the rows were built from, to update the table incrementally.
    private var rowsShown: EventCategories = []
    private var rowsQuery: [String] = []
    private var rowsSourceCount = 0
    private var rowsAppendedCount = 0
    private var rowsGeneration = -1
    private var reloadScheduled = false
    private var lastReload = Date.distantPast
    /// Most table updates per second while MIDI streams in. Each update of the
    /// table (insert, scroll, redraw) costs a few milliseconds; 10 per second
    /// keeps the log visually live (1–2 new lines at a time) at moderate CPU.
    private static let maxUpdatesPerSecond = 10.0

    fileprivate static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private enum Column: String, CaseIterable {
        case time = "Time", source = "Device", channel = "Ch", message = "Message", note = "Note", value = "Value"

        var width: CGFloat {
            switch self {
            case .time: return 125
            case .source: return 160
            case .channel: return 34
            case .message: return 260
            case .note: return 50
            case .value: return 70
            }
        }

        var font: NSFont {
            self == .source ? .systemFont(ofSize: NSFont.systemFontSize)
                : .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        var isRightAligned: Bool { self == .channel || self == .value }

        func text(of event: MIDIEvent) -> String {
            switch self {
            case .time: return LogWindowController.timeFormatter.string(from: event.date)
            case .source: return event.source ?? ""
            case .channel: return event.channel.map(String.init) ?? ""
            case .message: return MIDIFormat.logColumns(of: event.kind).message
            case .note: return MIDIFormat.logColumns(of: event.kind).note ?? ""
            case .value: return MIDIFormat.logColumns(of: event.kind).value ?? ""
            }
        }
    }

    init(store: EventStore,
         settings: Settings,
         saveSettings: @escaping (Settings) -> Void,
         deviceNames: @escaping () -> [String],
         onClear: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.saveSettings = saveSettings
        self.onClear = onClear
        self.deviceNames = deviceNames

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 480),
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
        window.setAlwaysOnTop(settings.alwaysOnTop)
        aftertouchCheckbox.state = settings.aftertouch ? .on : .off
        onTopCheckbox.state = settings.alwaysOnTop ? .on : .off
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
            // Only the message column absorbs window resizing.
            tableColumn.resizingMask = column == .message ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.style = .fullWidth
        tableView.rowHeight = ceil(mono.boundingRectForFont.height) + 2
        tableView.copyHandler = { [weak self] in self?.copySelection() }

        // Note: drawing the table into a single layer (canDrawSubviewsIntoLayer)
        // looked cheaper in short tests but backs the whole table height with one
        // bitmap, so memory and CPU grow with the history (150 MB in benchmark.sh).
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        aftertouchCheckbox.target = self
        aftertouchCheckbox.action = #selector(toggleAftertouch(_:))
        onTopCheckbox.target = self
        onTopCheckbox.action = #selector(toggleAlwaysOnTop(_:))

        let resetColumnsButton = NSButton(title: "Reset Columns", target: self, action: #selector(resetColumns))
        resetColumnsButton.toolTip = "Put the columns back in their order and fit their widths to the content."
        let clearButton = NSButton(title: "Clear Log", target: self, action: #selector(clearLog))
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        // Esc closes the window via cancelOperation(_:), unless the filter field is being edited.

        searchField.placeholderString = "Filter: words that must all appear, e.g. d4 on, xkey 064 (⌘F)"
        searchField.sendsSearchStringImmediately = false  // filters after a short typing pause
        searchField.target = self
        searchField.action = #selector(filterChanged(_:))

        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [aftertouchCheckbox, onTopCheckbox, countLabel, spacer, resetColumnsButton, clearButton, closeButton])
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)

        let content = NSView()
        for view in [searchField, scrollView, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
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

    /// With `takeFocus` false (used by the control API) the window is brought
    /// to the front without interrupting the app the user is working in.
    func show(takeFocus: Bool = true) {
        guard let window else { return }
        reload(scrollToEnd: true)
        if !columnsFitted {
            // The default widths may not fit the (restored) window: fit them, as Reset Columns does.
            columnsFitted = true
            window.contentView?.layoutSubtreeIfNeeded()
            resetColumns()
        }
        DesktopReturn.cancel(window)  // opened explicitly: show it here
        // A menu bar app is usually not the active app: bring the window above
        // other apps' windows explicitly and take the focus.
        window.orderFrontRegardless()
        if takeFocus {
            window.makeKey()
            NSApp.activateTakingFocus()
        }
    }

    /// Also true while hidden, waiting to come back on a regular desktop.
    var isVisible: Bool { window?.isShownOrWaiting == true }

    func closeLog() {
        guard let window else { return }
        if DesktopReturn.isWaiting(window) {
            DesktopReturn.cancel(window)  // hidden already; just stop waiting
        } else {
            window.performClose(nil)
        }
    }

    /// Called for every new event. The first event after a quiet moment shows
    /// at once; during a stream (fast passages, aftertouch) the table updates at
    /// most `maxUpdatesPerSecond` times per second, since inserting and
    /// scrolling to new rows is the main cost.
    func eventsDidChange() {
        guard window?.isVisible == true, !reloadScheduled else { return }
        reloadScheduled = true
        let delay = max(0, lastReload.addingTimeInterval(1 / Self.maxUpdatesPerSecond).timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.lastReload = Date()
            self.reload(scrollToEnd: self.isScrolledToEnd)
        }
    }

    func settingsDidChange() {
        guard window?.isVisible == true else { return }
        reload(scrollToEnd: true)
    }

    private var shownCategories: EventCategories { settings.aftertouch ? [.aftertouch] : [] }

    /// The event shown in a table row (nil if the history changed since the last update).
    private func event(atRow row: Int) -> MIDIEvent? {
        let all = store.events(including: rowsShown)
        let index = matches.map { row < $0.count ? $0[row] : Int.max } ?? row
        return index < all.count ? all[index] : nil
    }

    private func reload(scrollToEnd: Bool) {
        let shown = shownCategories
        aftertouchCheckbox.state = settings.aftertouch ? .on : .off
        let query = Self.terms(searchField.stringValue)
        let all = store.events(including: shown)
        let appended = store.appendedCount(including: shown)
        let added = appended - rowsAppendedCount
        if store.generation == rowsGeneration, shown == rowsShown, query == rowsQuery,
           added >= 0, all.count == rowsSourceCount + added {
            // Common case: new events at the end. Insert just the matching ones;
            // reloading the whole table for every update costs a lot of CPU.
            var newRows = added
            if query.isEmpty == false {
                let new = (rowsSourceCount..<all.count).filter { Self.matches(all[$0], query) }
                matches?.append(contentsOf: new)
                newRows = new.count
            }
            if newRows > 0 {
                rowCount += newRows
                tableView.insertRows(at: IndexSet(integersIn: rowCount - newRows..<rowCount), withAnimation: [])
            }
        } else {
            // Option or filter changed, log cleared or history trimmed.
            matches = query.isEmpty ? nil : all.indices.filter { Self.matches(all[$0], query) }
            rowCount = matches?.count ?? all.count
            rowsShown = shown
            tableView.reloadData()
        }
        rowsShown = shown
        rowsQuery = query
        rowsSourceCount = all.count
        rowsAppendedCount = appended
        rowsGeneration = store.generation
        updateCountLabel(shown: shown, filtered: !query.isEmpty)
        if scrollToEnd, rowCount > 0 { tableView.scrollRowToVisible(rowCount - 1) }
    }

    private func updateCountLabel(shown: EventCategories, filtered: Bool) {
        var text = filtered
            ? "\(rowCount) of \(rowsSourceCount) events match"
            : "\(rowCount) event\(rowCount == 1 ? "" : "s")"
        if let hidden = store.hiddenSummary(shown: shown) { text += " · \(hidden)" }
        if rowsSourceCount >= store.limit { text += " — showing the most recent \(store.limit)" }
        countLabel.stringValue = text
    }

    // MARK: - Filter

    /// Lower-cased words of the filter; every word must appear in the row.
    private static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The text of all columns of a row, as searched by the filter.
    private static func searchText(_ event: MIDIEvent) -> String {
        let columns = MIDIFormat.logColumns(of: event.kind)
        return [timeFormatter.string(from: event.date), event.source ?? "",
                event.channel.map { "ch \($0)" } ?? "", columns.message, columns.note ?? "", columns.value ?? ""]
            .joined(separator: " ").lowercased()
    }

    private static func matches(_ event: MIDIEvent, _ terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let text = searchText(event)
        return terms.allSatisfy { text.contains($0) }
    }

    @objc private func filterChanged(_ sender: NSSearchField) {
        reload(scrollToEnd: true)
    }

    /// ⌘F: brings the window forward and puts the cursor in the filter field.
    func focusFilter() {
        show()
        window?.makeFirstResponder(searchField)
    }

    /// Esc: closes the window (the filter field handles Esc itself while editing).
    override func cancelOperation(_ sender: Any?) {
        closeLog()
    }

    private var isScrolledToEnd: Bool {
        let visible = scrollView.contentView.bounds
        return visible.maxY >= tableView.bounds.height - tableView.rowHeight * 2
    }

    // MARK: - Actions

    @objc private func toggleAftertouch(_ sender: NSButton) {
        setAftertouch(sender.state == .on)
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSButton) {
        setAlwaysOnTop(sender.state == .on)
    }

    func setAftertouch(_ on: Bool) {
        settings.aftertouch = on
        saveSettings(settings)
        settingsDidChange()
    }

    func setAlwaysOnTop(_ on: Bool) {
        settings.alwaysOnTop = on
        onTopCheckbox.state = on ? .on : .off
        saveSettings(settings)
        window?.setAlwaysOnTop(on)
    }

    @objc private func clearLog() {
        onClear()
    }

    @objc private func closeWindow() {
        closeLog()
    }

    private func copySelection() {
        let lines = tableView.selectedRowIndexes.compactMap { event(atRow: $0) }.map { event in
            Column.allCases.map { $0.text(of: event) }.joined(separator: "\t")
        }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let identifier = tableColumn.identifier
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = identifier
            f.lineBreakMode = .byTruncatingTail
            f.font = column.font
            if column.isRightAligned { f.alignment = .right }
            return f
        }()
        guard let event = event(atRow: row) else {
            field.stringValue = ""
            return field
        }
        field.stringValue = column.text(of: event)
        return field
    }

    // MARK: - Columns

    /// Puts the columns back in their default order and fits each to its widest
    /// content among the rows shown, its title and the widest values expected. Space left over goes to
    /// the message column, so the table fills the window.
    @objc private func resetColumns() {
        for (index, column) in Column.allCases.enumerated() {
            let current = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
            if current >= 0, current != index { tableView.moveColumn(current, toColumn: index) }
        }
        // Distinct texts only: the log can hold 100,000 rows, but few different strings per column.
        var texts = Dictionary(uniqueKeysWithValues: Column.allCases.map { ($0, Set<String>()) })
        for row in 0..<rowCount {
            guard let event = event(atRow: row) else { continue }
            for column in Column.allCases where column != .time { texts[column]?.insert(column.text(of: event)) }
        }
        // Also the widest values that may come, so that a short or empty log leaves room for them.
        texts[.time] = ["00:00:00.000"]
        texts[.source]?.formUnion(deviceNames())
        texts[.channel]?.insert("16")
        texts[.note]?.insert("C#-1")
        texts[.value]?.insert("-8192")
        let padding: CGFloat = 16  // cell insets and the column separator
        var widths: [Column: CGFloat] = [:]
        for column in Column.allCases {
            let header = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))?.headerCell
            let headerFont = header?.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let title = (column.rawValue as NSString).size(withAttributes: [.font: headerFont]).width
            let content = texts[column, default: []].map {
                ($0 as NSString).size(withAttributes: [.font: column.font]).width
            }.max() ?? 0
            widths[column] = ceil(max(title, content)) + padding
        }
        // Each column also takes the spacing between cells.
        let available = scrollView.contentView.bounds.width
            - tableView.intercellSpacing.width * CGFloat(Column.allCases.count)
        let total = widths.values.reduce(0, +)
        if total < available { widths[.message, default: 0] += floor(available - total) }
        // Set the widths without the table redistributing them after each change.
        let style = tableView.columnAutoresizingStyle
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        for column in Column.allCases {
            tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))?.width = widths[column] ?? column.width
        }
        tableView.columnAutoresizingStyle = style
        tableView.sizeToFit()
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
