// ProductsWindow.swift
// semel-monitor
//
// The products window: the folders of `output:` and the errors on the left, the selected
// folder's products on the right with the settle's marks and their sizes, or the error
// report's lines, selectable; *Copy paths* and *Export…* under them. Everything it shows
// is `ProductsWindowModel`'s; what the person selects goes back to the presenter, which
// hands a new model down.

import AppKit
import SemelMonitor
import SemelNodeKit

final class ProductsWindow: NSObject, NSWindowDelegate {

    var onSelectSection: (ProductsSection) -> Void = { _ in }
    var onSelectRows:    (Set<String>) -> Void = { _ in }
    var onExport:        (ExportRequest) -> Void = { _ in }
    var onClose:         () -> Void = {}

    let window: NSWindow

    private let sidebar      = NSTableView()
    private let productTable = NSTableView()
    private let productsView: NSScrollView
    private let errorsText: NSTextView
    private let errorsView: NSScrollView
    private let placeholder  = NSTextField(labelWithString: "")
    private let copyButton   = NSButton(title: "Copy paths", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private let statusLine   = NSTextField(labelWithString: "")

    private var model: ProductsWindowModel?
    private var rows: [ProductRow] = []

    /// While the tables are reloaded from a model, their selection is the model's, not the
    /// person's, and is not sent back.
    private var isShowingModel = false

    private enum Column {
        static let product = NSUserInterfaceItemIdentifier("product")
        static let mark    = NSUserInterfaceItemIdentifier("mark")
        static let size    = NSUserInterfaceItemIdentifier("size")
        static let section = NSUserInterfaceItemIdentifier("section")
    }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        productsView = NSScrollView()
        errorsView   = NSTextView.scrollableTextView()
        errorsText   = (errorsView.documentView as? NSTextView) ?? NSTextView()
        super.init()
        window.title                = "Products · \(FileSystemName.output)"
        window.isReleasedWhenClosed = false
        window.minSize              = NSSize(width: 480, height: 280)
        window.delegate             = self
        window.center()
        layOut()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Drawing a display

    func show(_ display: ProductsPresenter.Display) {
        switch display {
        case .closed:
            return
        case .loading:
            model = nil
            showPlaceholder("Reading output:…")
        case .failed(let reason):
            model = nil
            showPlaceholder(reason)
        case .shown(let newModel):
            show(newModel)
        }
    }

    private func show(_ newModel: ProductsWindowModel) {
        model = newModel
        rows  = newModel.rows
        isShowingModel = true
        defer { isShowingModel = false }

        sidebar.reloadData()
        if let index = newModel.sections.firstIndex(of: newModel.section) {
            sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        placeholder.isHidden = true
        switch newModel.section {
        case .folder:
            productsView.isHidden = false
            errorsView.isHidden   = true
            productTable.reloadData()
            let selected = IndexSet(rows.indices.filter { newModel.selectedRows.contains(rows[$0].path) })
            productTable.selectRowIndexes(selected, byExtendingSelection: false)
        case .errors:
            productsView.isHidden = true
            errorsView.isHidden   = false
            errorsText.string     = newModel.errorLines.joined(separator: "\n")
        }
        copyButton.isEnabled   = !newModel.copiedPaths.isEmpty
        exportButton.title     = newModel.exportTitle
        exportButton.isEnabled = newModel.exportRequest != nil
    }

    private func showPlaceholder(_ text: String) {
        sidebar.reloadData()
        placeholder.stringValue = text
        placeholder.isHidden    = false
        productsView.isHidden   = true
        errorsView.isHidden     = true
        copyButton.isEnabled    = false
        exportButton.isEnabled  = false
    }

    /// A line under the buttons: what the last export came to.
    func say(_ text: String) {
        statusLine.stringValue = text
    }

    // MARK: - The person

    @objc private func copyPaths() {
        guard let model else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.copiedPaths.joined(separator: "\n"), forType: .string)
        say("Copied \(model.copiedPaths.count) \(model.copiedPaths.count == 1 ? "path" : "paths").")
    }

    @objc private func export() {
        guard let request = model?.exportRequest else {
            return
        }
        onExport(request)
    }

    /// A double-click on a folder among the products opens it, as the Finder does.
    @objc private func openRow() {
        let index = productTable.clickedRow
        guard rows.indices.contains(index), rows[index].isFolder else {
            return
        }
        onSelectSection(.folder(rows[index].path))
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    // MARK: - Layout

    private func layOut() {
        let sidebarColumn = NSTableColumn(identifier: Column.section)
        sidebarColumn.title = "Folders"
        sidebar.addTableColumn(sidebarColumn)
        sidebar.headerView = nil
        sidebar.style      = .sourceList
        sidebar.dataSource = self
        sidebar.delegate   = self
        let sidebarView = NSScrollView()
        sidebarView.documentView        = sidebar
        sidebarView.hasVerticalScroller = true
        sidebarView.drawsBackground     = false

        for (identifier, title, width) in [(Column.product, "Product", 240.0), (Column.mark, "This settle", 100.0),
                                           (Column.size, "Size", 90.0)] {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            productTable.addTableColumn(column)
        }
        productTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        productTable.allowsMultipleSelection = true
        productTable.usesAlternatingRowBackgroundColors = true
        productTable.dataSource   = self
        productTable.delegate     = self
        productTable.target       = self
        productTable.doubleAction = #selector(openRow)
        productsView.documentView        = productTable
        productsView.hasVerticalScroller = true

        errorsText.isEditable   = false
        errorsText.isSelectable = true
        errorsText.font         = .monospacedSystemFont(ofSize: 11, weight: .regular)
        errorsText.textContainerInset = NSSize(width: 8, height: 8)
        errorsView.isHidden           = true

        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center

        let detail = NSView()
        for view in [productsView, errorsView, placeholder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            detail.addSubview(view)
        }
        NSLayoutConstraint.activate([productsView, errorsView].flatMap { view in [
            view.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            view.topAnchor.constraint(equalTo: detail.topAnchor),
            view.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ] } + [
            placeholder.centerXAnchor.constraint(equalTo: detail.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: detail.centerYAnchor),
        ])

        copyButton.target   = self
        copyButton.action   = #selector(copyPaths)
        exportButton.target = self
        exportButton.action = #selector(export)
        exportButton.keyEquivalent = "\r"
        for button in [copyButton, exportButton] {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        statusLine.textColor     = .secondaryLabelColor
        statusLine.lineBreakMode = .byTruncatingMiddle
        statusLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLine.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [statusLine, copyButton, exportButton])
        footer.orientation = .horizontal
        footer.spacing     = 8
        footer.setHuggingPriority(.defaultLow, for: .horizontal)

        // Plain constraints rather than a split view: the column keeps its width as the
        // window grows, and the products take the rest.
        let columnRule = NSBox()
        columnRule.boxType = .separator
        let footerRule = NSBox()
        footerRule.boxType = .separator
        // A separator hugs its own short length, which would pull the window down to it.
        columnRule.setContentHuggingPriority(.defaultLow, for: .vertical)
        footerRule.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let content = NSView()
        for view in [sidebarView, columnRule, detail, footerRule, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let margin: CGFloat       = 12
        let footerHeight: CGFloat = 44
        NSLayoutConstraint.activate([
            sidebarView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: footerRule.topAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: 190),
            columnRule.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            columnRule.topAnchor.constraint(equalTo: content.topAnchor),
            columnRule.bottomAnchor.constraint(equalTo: footerRule.topAnchor),
            columnRule.widthAnchor.constraint(equalToConstant: 1),
            detail.leadingAnchor.constraint(equalTo: columnRule.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detail.topAnchor.constraint(equalTo: content.topAnchor),
            detail.bottomAnchor.constraint(equalTo: footerRule.topAnchor),
            footerRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footerRule.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -footerHeight),
            footer.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -footerHeight / 2),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
        ])
        window.contentView = content
    }
}

// MARK: - The tables

extension ProductsWindow: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sidebar ? model?.sections.count ?? 0 : rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let model, let identifier = tableColumn?.identifier else {
            return nil
        }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        if tableView === sidebar {
            let section = model.sections[row]
            field.stringValue = model.title(of: section)
            if section == .errors {
                field.textColor = .secondaryLabelColor
            }
            return field
        }
        let product = rows[row]
        switch identifier {
        case Column.product:
            field.stringValue = product.name
        case Column.mark:
            field.stringValue = product.mark?.word ?? ""
            switch product.mark {
            case .noValue:              field.textColor = .systemRed
            case .appeared, .changed:   field.textColor = .systemGreen
            case nil:                   break
            }
        default:
            field.stringValue = product.sizeText
            field.alignment   = .right
            field.textColor   = product.size == nil ? .tertiaryLabelColor : .labelColor
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingModel, let model, let tableView = notification.object as? NSTableView else {
            return
        }
        if tableView === sidebar {
            let index = sidebar.selectedRow
            if model.sections.indices.contains(index) {
                onSelectSection(model.sections[index])
            }
            return
        }
        onSelectRows(Set(productTable.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].path : nil }))
    }
}
