// LiveWindow.swift
// semel-monitor
//
// The live window behind *Show window*: the settle's counts and a bar for pending against
// scheduled, the nodes running now with their type, name and how long each has run, and
// under them the last settle's products, marked as the products window marks them, and its
// errors in the report's lines. Everything it shows is `LiveWindowModel`'s, read on every
// event while it is open and, while a settle runs, twice a second for the elapsed times.

import AppKit
import SemelMonitor

final class LiveWindow: NSObject, NSWindowDelegate {

    /// The model and the app's clock now, read whenever the window redraws.
    var read: () -> (model: LiveWindowModel, now: Duration) = { (LiveWindowModel(), .zero) }

    private let window: NSWindow
    private let countsLine   = NSTextField(labelWithString: "")
    private let bar          = NSProgressIndicator()
    private let runningTable = NSTableView()
    private let settleLine   = NSTextField(labelWithString: "")
    private let productTable = NSTableView()
    private let errorsText: NSTextView
    private let errorsView: NSScrollView

    private var runningRows: [RunningNodeRow] = []
    private var productRows: [(folder: String, row: ProductRow)] = []
    private var ticker: Timer?

    /// How often the elapsed times are redrawn while a settle runs and no event comes.
    private static let tick: TimeInterval = 0.5

    private enum Column {
        static let type    = NSUserInterfaceItemIdentifier("type")
        static let name    = NSUserInterfaceItemIdentifier("name")
        static let elapsed = NSUserInterfaceItemIdentifier("elapsed")
        static let folder  = NSUserInterfaceItemIdentifier("folder")
        static let product = NSUserInterfaceItemIdentifier("product")
        static let mark    = NSUserInterfaceItemIdentifier("mark")
    }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        errorsView = NSTextView.scrollableTextView()
        errorsText = (errorsView.documentView as? NSTextView) ?? NSTextView()
        super.init()
        window.isReleasedWhenClosed = false
        window.minSize              = NSSize(width: 420, height: 320)
        window.delegate             = self
        window.center()
        layOut()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refresh()
    }

    /// Redraws from the model, when the window is open.
    func refresh() {
        guard window.isVisible else {
            stopTicking()
            return
        }
        let (model, now) = read()
        window.title           = model.title
        countsLine.stringValue = model.countsLine ?? "No settle yet"
        bar.doubleValue        = model.barFraction
        runningRows            = model.runningRows(at: now)
        runningTable.reloadData()
        settleLine.stringValue = model.lastSettleLine ?? ""
        productRows = model.lastSettle.map { products in
            products.sections.flatMap { section -> [(folder: String, row: ProductRow)] in
                guard case .folder(let folder) = section else {
                    return []
                }
                return products.rows(in: folder).map { (products.title(of: section), $0) }
            }
        } ?? []
        productTable.reloadData()
        let errors = model.lastSettle.map { $0.snapshot.errors.isEmpty ? [] : $0.errorLines } ?? []
        errorsText.string   = errors.joined(separator: "\n")
        errorsView.isHidden = errors.isEmpty
        model.phase == .settling ? startTicking() : stopTicking()
    }

    func windowWillClose(_ notification: Notification) {
        stopTicking()
    }

    private func startTicking() {
        guard ticker == nil else {
            return
        }
        ticker = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - Layout

    private func layOut() {
        countsLine.textColor = .secondaryLabelColor
        countsLine.font      = .systemFont(ofSize: 12)
        bar.style            = .bar
        bar.isIndeterminate  = false
        bar.minValue         = 0
        bar.maxValue         = 1
        settleLine.font      = .boldSystemFont(ofSize: 12)

        let runningView = table(runningTable, columns: [(Column.type, "Type", 150), (Column.name, "Name", 260),
                                                        (Column.elapsed, "Elapsed", 70)])
        let productsView = table(productTable, columns: [(Column.folder, "Folder", 150), (Column.product, "Product", 220),
                                                         (Column.mark, "This settle", 100)])
        errorsText.isEditable   = false
        errorsText.isSelectable = true
        errorsText.font         = .monospacedSystemFont(ofSize: 11, weight: .regular)
        errorsView.isHidden     = true

        let stack = NSStackView(views: [countsLine, bar, runningView, settleLine, productsView, errorsView])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 8
        stack.edgeInsets  = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [bar, runningView, productsView, errorsView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        NSLayoutConstraint.activate([
            runningView.heightAnchor.constraint(equalToConstant: 150),
            productsView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            errorsView.heightAnchor.constraint(equalToConstant: 90),
        ])
        window.contentView = stack
    }

    private func table(_ tableView: NSTableView, columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)]) -> NSScrollView {
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.columnAutoresizingStyle            = .lastColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate   = self
        let scrollView = NSScrollView()
        scrollView.documentView        = tableView
        scrollView.hasVerticalScroller = true
        return scrollView
    }
}

// MARK: - The tables

extension LiveWindow: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === runningTable ? runningRows.count : productRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else {
            return nil
        }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        if tableView === runningTable {
            let node = runningRows[row]
            switch identifier {
            case Column.type: field.stringValue = node.type
            case Column.name: field.stringValue = node.name
            default:
                field.stringValue = ElapsedText.text(node.elapsed)
                field.alignment   = .right
                field.font        = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            return field
        }
        let entry = productRows[row]
        switch identifier {
        case Column.folder:
            field.stringValue = entry.folder
            field.textColor   = .secondaryLabelColor
        case Column.product:
            field.stringValue = entry.row.name
        default:
            field.stringValue = entry.row.mark?.word ?? ""
            switch entry.row.mark {
            case .noValue:            field.textColor = .systemRed
            case .appeared, .changed: field.textColor = .systemGreen
            case nil:                 break
            }
        }
        return field
    }
}
