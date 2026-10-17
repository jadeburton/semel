// ProductsWindowModel.swift
// SemelMonitor
//
// What the products window shows, as a value: `output:` folder by folder as `ls` lists it,
// the products the settle moved marked, every error in the report's lines, and what is
// selected — with the export and the copied paths a selection comes to. The window only
// draws it and hands the person's choices back, so all of it is tested without AppKit.
//
//     output:   │ Product        This settle   Size
//     c         │ config.txt                   23 bytes
//     Errors (0)│ hello          changed       33 KB
//               │ hello.dylib    changed       33 KB

import SemelCLI
import SemelNodeKit
import SemelProtocol

/// What the window lists, read from the engine in one go: `output:` and the errors.
public struct ProductsSnapshot: Equatable, Sendable {
    public let folders: [FolderListing]
    public let errors: [ErrorRecord]

    public init(folders: [FolderListing], errors: [ErrorRecord]) {
        self.folders = folders
        self.errors  = errors
    }

    /// Read through the prompt's own code: the streamed listing `ls` makes and the records
    /// `errors` prints.
    public static func read(through interpreter: CommandInterpreter) throws -> ProductsSnapshot {
        ProductsSnapshot(folders: try interpreter.outputFolders(), errors: try interpreter.errorRecords())
    }

    /// One settle's products and errors as the events said them, in the shape a listing of
    /// `output:` has, so the live window shows them through the products window's model
    /// and asks the engine for nothing. Each folder holds the settle's products in it, as
    /// `ls` orders them: what appeared or changed, and what the errors left without a
    /// value; a tree product is one entry, its folder, as the card names it. What
    /// disappeared is not listed, as the products window does not list it. Sizes are not
    /// in the events, so none is given.
    public static func ofSettle(appeared: [String], changed: [String], treeFolders: [String: String],
                                errors: [ErrorRecord]) -> ProductsSnapshot {
        var entries: [String: [String: ListEntry]] = [:]
        func add(_ product: StoppedProduct, status: EntryStatus) {
            let named = product.treeFolder ?? product.path
            guard let path = ProductsWindowModel.pathBelowRoot(named) else {
                return
            }
            let folder = Path(path).deletingLastComponent?.string ?? ""
            entries[folder, default: [:]][path] = ListEntry(path: path, kind: product.treeFolder == nil ? .file : .folder,
                                                            size: nil, mode: nil, status: status)
        }
        for path in changed + appeared {
            add(StoppedProduct(path: path, treeFolder: treeFolders[path]), status: .none)
        }
        // After the products that moved: a product an error left without a value is said
        // to have none, whatever else the settle said of it.
        for product in errors.flatMap(\.products) {
            add(product, status: .failed)
        }
        let folders = entries.keys.sorted().map { folder in
            FolderListing(folder: folder, entries: ListingOrder.sorted(Array(entries[folder, default: [:]].values)))
        }
        return ProductsSnapshot(folders: folders, errors: errors)
    }
}

/// What the settle did to a product, in the events' words.
public enum ProductMark: Equatable, Sendable {
    case appeared
    case changed
    /// The listing says the product failed: it is in error, as the report and `ls` say.
    case noValue

    public var word: String {
        switch self {
        case .appeared: return "appeared"
        case .changed:  return "changed"
        case .noValue:  return ValueState.inError.word
        }
    }
}

/// One line on the right: a product, or a subfolder as `ls` lists it among them.
public struct ProductRow: Equatable, Sendable {
    /// Below the root of `output:`, as the listing has it.
    public let path: String
    /// As `ls` names it in its folder; a folder with a trailing `/`.
    public let name: String
    public let isFolder: Bool
    public let mark: ProductMark?
    public let size: Int?

    /// `1.2 MB`, `640 KB`, `23 bytes`; `—` for a folder or a product with no bytes to count.
    public var sizeText: String {
        size.map(ByteSize.text) ?? "—"
    }
}

/// The left column: each folder, then the errors.
public enum ProductsSection: Hashable, Sendable {
    /// Below the root of `output:`; empty for the root.
    case folder(String)
    case errors
}

/// What *Export…* is asked to write: `export <folder> --into <dir>`, narrowed to a
/// selection when there is one.
public struct ExportRequest: Equatable, Sendable {
    /// Below the root of `output:`; empty for the root.
    public let folder: String
    /// Paths below the root, products or folders; nil for the whole folder.
    public let selection: Set<String>?
    /// The name a save panel offers: the folder's own.
    public let suggestedName: String
}

public struct ProductsWindowModel: Equatable, Sendable {

    public private(set) var snapshot: ProductsSnapshot

    /// The paths below `output:`'s root the settle the marks come from made appear or
    /// change: the newest card's, or the card that was clicked until a later settle.
    public private(set) var appeared: Set<String> = []
    public private(set) var changed: Set<String> = []

    /// What the left column has selected.
    public private(set) var section: ProductsSection

    /// The rows selected on the right, by path; always rows of `section`.
    public private(set) var selectedRows: Set<String> = []

    /// The window for `card` — the one clicked, or the newest for *Products…* — opened on
    /// the folder of the first product it names, or on the errors for an error card.
    public init(snapshot: ProductsSnapshot, card: Card?) {
        self.snapshot = snapshot
        self.section  = .folder("")
        mark(from: card)
        section = Self.openingSection(for: card, in: snapshot)
    }

    /// The listing read again after a settle, its marks those of `card`: what is selected
    /// stays selected while it is still there.
    public mutating func refresh(with newSnapshot: ProductsSnapshot, card: Card?) {
        snapshot = newSnapshot
        mark(from: card)
        if case .folder(let folder) = section, !newSnapshot.folders.contains(where: { $0.folder == folder }) {
            section = .folder("")
        }
        let shown = Set(rows.map(\.path))
        selectedRows = selectedRows.intersection(shown)
    }

    public mutating func select(_ newSection: ProductsSection) {
        guard newSection != section else {
            return
        }
        section      = newSection
        selectedRows = []
    }

    /// Rows of the section shown; any other path is ignored.
    public mutating func selectRows(_ paths: Set<String>) {
        selectedRows = paths.intersection(rows.map(\.path))
    }

    // MARK: - The left column

    /// Each folder and the errors section, in the order the column lists them.
    public var sections: [ProductsSection] {
        snapshot.folders.map { .folder($0.folder) } + [.errors]
    }

    /// `output:` for the root, a folder by its path below it, `Errors (2)`.
    public func title(of section: ProductsSection) -> String {
        switch section {
        case .folder(let folder): return folder.isEmpty ? FileSystemName.output : folder
        case .errors:             return "Errors (\(ErrorReportRenderer.errorCount(of: snapshot.errors)))"
        }
    }

    // MARK: - The right side

    /// The folder's entries as `ls` lists them, each with its mark and size. None for the
    /// errors section.
    public var rows: [ProductRow] {
        guard case .folder(let folder) = section else {
            return []
        }
        return rows(in: folder)
    }

    /// One folder's entries as `ls` lists them, whichever is selected: what the live window
    /// lists, every folder of the settle under the one before.
    public func rows(in folder: String) -> [ProductRow] {
        guard let listing = snapshot.folders.first(where: { $0.folder == folder }) else {
            return []
        }
        return listing.entries.map { entry in
            let name = Path(entry.path).lastComponent ?? entry.path
            return ProductRow(path: entry.path, name: entry.kind == .folder ? "\(name)/" : name,
                              isFolder: entry.kind == .folder, mark: mark(of: entry), size: entry.size)
        }
    }

    /// The report as `errors` prints it, plain: what the errors section shows, selectable.
    public var errorLines: [String] {
        guard !snapshot.errors.isEmpty else {
            return ["No errors."]
        }
        return ErrorReportRenderer.lines(for: snapshot.errors, style: ErrorReportStyle())
    }

    // MARK: - Export and copy

    /// The export the button makes: the selected rows, or the whole folder when none is
    /// selected. Nil in the errors section or for a folder with nothing in it.
    public var exportRequest: ExportRequest? {
        guard case .folder(let folder) = section, !rows.isEmpty else {
            return nil
        }
        let suggestedName = Path(folder).lastComponent ?? "output"
        return ExportRequest(folder: folder, selection: selectedRows.isEmpty ? nil : selectedRows,
                             suggestedName: suggestedName)
    }

    /// `Export 2 products…`, `Export 1 folder…`, `Export 3 items…`, or the folder's own
    /// name with nothing selected: `Export c…`.
    public var exportTitle: String {
        guard case .folder(let folder) = section else {
            return "Export…"
        }
        let selected = rows.filter { selectedRows.contains($0.path) }
        guard !selected.isEmpty else {
            return "Export \(title(of: .folder(folder)))…"
        }
        let folders = selected.filter(\.isFolder).count
        let noun: String
        switch folders {
        case 0:              noun = selected.count == 1 ? "product" : "products"
        case selected.count: noun = selected.count == 1 ? "folder" : "folders"
        default:             noun = "items"
        }
        return "Export \(selected.count) \(noun)…"
    }

    /// The `output:` paths *Copy paths* copies, one per line: the selected rows, or the
    /// folder itself; in the errors section, the products without a value.
    public var copiedPaths: [String] {
        let root = FileSystemName.output
        switch section {
        case .folder(let folder):
            let paths = selectedRows.isEmpty ? [folder] : rows.map(\.path).filter(selectedRows.contains)
            return paths.map { $0.isEmpty ? root : "\(root)/\($0)" }
        case .errors:
            return ErrorReportRenderer.productsWithoutValue(snapshot.errors).sorted()
        }
    }

    // MARK: - Marks

    /// The settle's paths, and the folder of each tree product it moved, marked as the card
    /// names the tree: a tree's folder is listed among its parent's entries, and is the
    /// product a person built.
    private mutating func mark(from card: Card?) {
        guard let card, case .result(let changedPaths, let appearedPaths, _, _, _) = card.content else {
            appeared = []
            changed  = []
            return
        }
        let moved = card.movedProducts
        let trees = { (products: [StoppedProduct]) in products.compactMap(\.treeFolder) }
        appeared = Set((appearedPaths + trees(moved.appeared)).compactMap(Self.pathBelowRoot))
        changed  = Set((changedPaths + trees(moved.changed)).compactMap(Self.pathBelowRoot))
    }

    /// A failure is a state the listing reads now; appeared and changed are what the
    /// settle said. A folder carries no mark unless it is a tree product's.
    private func mark(of entry: ListEntry) -> ProductMark? {
        if entry.status == .failed {
            return .noValue
        }
        if changed.contains(entry.path) {
            return .changed
        }
        return appeared.contains(entry.path) ? .appeared : nil
    }

    /// `c/hello` for `output:/c/hello`, the form the listing's paths take.
    static func pathBelowRoot(_ outputPath: String) -> String? {
        let prefix = "\(FileSystemName.output)/"
        return outputPath.hasPrefix(prefix) ? String(outputPath.dropFirst(prefix.count)) : nil
    }

    /// The folder of the first product a result card names, where the person looks first;
    /// the errors for an error card; otherwise the first folder holding a product.
    private static func openingSection(for card: Card?, in snapshot: ProductsSnapshot) -> ProductsSection {
        if card?.kind == .errors {
            return .errors
        }
        let listed = Set(snapshot.folders.map(\.folder))
        if let first = card?.products.first.flatMap({ pathBelowRoot($0.path) }) {
            let folder = Path(first).deletingLastComponent?.string ?? ""
            if listed.contains(folder) {
                return .folder(folder)
            }
        }
        let holding = snapshot.folders.first { $0.entries.contains { $0.kind == .file } }
        return .folder(holding?.folder ?? "")
    }
}

/// A byte count as the window writes it, the same on every machine whatever its locale:
/// decimal units as the Finder counts them, a whole number of bytes and kilobytes, one
/// decimal place above.
public enum ByteSize {
    public static func text(_ bytes: Int) -> String {
        let kilo = 1000.0
        let value = Double(bytes)
        switch value {
        case ..<kilo:
            return bytes == 1 ? "1 byte" : "\(bytes) bytes"
        case ..<(kilo * kilo):
            return "\(Int((value / kilo).rounded())) KB"
        case ..<(kilo * kilo * kilo):
            return oneDecimal(value / (kilo * kilo)) + " MB"
        default:
            return oneDecimal(value / (kilo * kilo * kilo)) + " GB"
        }
    }

    private static func oneDecimal(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }
}
