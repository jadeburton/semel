// ErrorReportRenderer.swift
// semel
//
// The error report: what has no value, and why, as a timeless statement (the 2026-10-09
// error report design).
//
// Every line is drawn here from the typed values a node published — its `ErrorDocument` —
// and nothing the engine sends is a sentence to repeat or take apart. The report leads
// with products: one heading per set of products that share the same errors, and under it
// each error, a block:
//
//     libConversations.a, libExplore.a, libLists.a and 2 more:
//     Packages/Models/Sources/Models/Account.swift:201:28: error: cannot convert value …
//       target: Models
//
// line one the diagnostic, then what the failing function belongs to, then — where the
// engine can state one as a fact — what to change. An error is printed in full once; a
// later heading that needs it again names it by its first line and `(above)`. Errors no
// product needs come last, under `no product:`. The report ends with one summary line,
// counting errors and products; nodes are not counted.

import Foundation
import SemelNodeKit
import SemelProtocol

/// How a report is drawn: whether the engine's facts are shown under each block
/// (`--verbose`), and whether there is colour.
public struct ErrorReportStyle: Equatable, Sendable {
    public var verbose: Bool
    public var colour:  Bool

    public init(verbose: Bool = false, colour: Bool = false) {
        self.verbose = verbose
        self.colour  = colour
    }
}

/// Whether a report is drawn in colour, decided once per process as the progress line
/// decides whether it is drawn: at a terminal that is not `dumb`, and not when `NO_COLOR`
/// is set (no-color.org), so a log or a pipe is plain text.
public enum ColourPolicy {
    public static let variable = "NO_COLOR"

    static func colours(environment: [String: String], standardOutputIsTerminal: Bool) -> Bool {
        guard standardOutputIsTerminal, environment["TERM"] != "dumb" else {
            return false
        }
        // Any value turns it off, the empty string included, as no-color.org asks.
        return environment[variable] == nil
    }

    /// The decision for this process.
    public static func inThisProcess() -> Bool {
        colours(environment: ProcessInfo.processInfo.environment, standardOutputIsTerminal: isatty(STDOUT_FILENO) == 1)
    }
}

/// What became of an export a report is about, for its summary line.
public enum ExportOutcome: Equatable, Sendable {
    /// No export was made: products the build names have no value.
    case nothing
    /// Every product had a value and was exported, to a folder as the reader typed it.
    case whole(destination: String)
    /// `--into` exported what had a value: `exported` of `products`.
    case partial(exported: Int, of: Int)
}

/// One block of a report: one cause, merged with every other record of the same cause.
/// Two compilers missing one machine setting publish two documents differing only in the
/// source each compiles, and they are one error: one block naming both sources.
struct ErrorBlock: Equatable {
    var document: ErrorDocument
    /// Each subject the merged documents name, in the order met.
    var subjects: [ErrorDocument.Subject]
    /// Every product without a value because of it.
    var products: [StoppedProduct]
    var facts:    [ErrorFacts]
}

public enum ErrorReportRenderer {

    /// How many products a heading names before it counts the rest.
    static let productsNamed = 3

    /// How many paths a condition's own lines name before they count the rest.
    static let pathsNamed = 5

    /// The heading of the errors no product needs.
    static let noProductHeading = "no product:"

    /// What follows an error's first line under a heading after the one it is printed under.
    static let aboveMarker = "(above)"

    // MARK: - The whole report

    /// The headings, each with its errors, and the summary line at the end. What `errors`
    /// prints, and the idle-time report after a settle.
    static func lines(for records: [ErrorRecord], style: ErrorReportStyle,
                      export: ExportOutcome? = nil) -> [String] {
        let blocks = Self.blocks(for: records)
        return groupLines(blocks, style: style)
            + [summaryLine(errors: blocks.count, productsWithoutValue: productCount(blocks), export: export)]
    }

    /// One condition as a report draws it, with no heading and no summary: an error a
    /// command meets outside a build, such as a batch the lock barrier refuses.
    static func lines(for condition: ErrorCondition) -> [String] {
        let document = ErrorDocument.engine(condition, subject: nil)
        return BlockRenderer(names: ProductNames(products: []), style: ErrorReportStyle())
            .lines(for: ErrorBlock(document: document, subjects: [], products: [], facts: []))
    }

    /// `errors <product>`: that product's heading and its errors, alone. `product` is the
    /// full path asked about, `output:/…`; the records are the server's answer for it, and
    /// none means the product has a value.
    static func productView(_ records: [ErrorRecord], product: String, style: ErrorReportStyle) -> [String] {
        let isTree = records.contains { record in record.products.contains { $0.treeFolder == product } }
        let name   = ProductNames(products: [StoppedProduct(path: product, treeFolder: isTree ? product : nil)])
            .name(of: product, isTree: isTree)
        guard !records.isEmpty else {
            return ["\(ProductNames.headingName(name)) has a value."]
        }
        let blocks   = Self.blocks(for: records)
        let renderer = BlockRenderer(names: ProductNames(products: blocks.flatMap(\.products)), style: style)
        var lines    = [renderer.heading("\(ProductNames.headingName(name)):")]
        for block in blocks {
            lines.append(contentsOf: renderer.lines(for: block))
            lines.append("")
        }
        return lines + [summaryLine(errors: blocks.count, productsWithoutValue: productCount(blocks), export: nil)]
    }

    /// The summary line, in its four forms: the counts alone, as `errors` and the report
    /// after a settle say them; and after an export, nothing exported, all of it, or what
    /// had a value.
    static func summaryLine(errors: Int, productsWithoutValue: Int, export: ExportOutcome?) -> String {
        var parts = ["\(errors) \(errors == 1 ? "error" : "errors")"]
        switch productsWithoutValue {
        case 0:  parts.append("every product has a value")
        case 1:  parts.append("1 product without a value")
        default: parts.append("\(productsWithoutValue) products without a value")
        }
        switch export {
        case nil:
            break
        case .nothing:
            parts.append("nothing exported")
        case .whole(let destination):
            parts.append("exported to \(destination)")
        case .partial(let exported, let products):
            parts.append(exported == 0 ? "nothing exported" : "\(exported) of \(products) products exported")
        }
        return parts.joined(separator: " · ")
    }

    /// The report's summary line for these records, with no export: what a view too small
    /// for the report — a notification card — says under the error it shows.
    public static func summaryLine(for records: [ErrorRecord]) -> String {
        let blocks = Self.blocks(for: records)
        return summaryLine(errors: blocks.count, productsWithoutValue: productCount(blocks), export: nil)
    }

    /// How many errors the report counts for these records: one per cause, merged as its
    /// blocks are.
    public static func errorCount(of records: [ErrorRecord]) -> Int {
        blocks(for: records).count
    }

    /// Line one of the first error the report prints — the first block under its first
    /// heading — drawn plain. Nil for no records. A view that shows one error shows this
    /// one, so it reads as the report's top line and as the tool wrote it.
    public static func firstLine(of records: [ErrorRecord]) -> String? {
        let blocks = Self.blocks(for: records)
        guard let index = groups(of: blocks).first?.blocks.first else {
            return nil
        }
        let renderer = BlockRenderer(names: ProductNames(products: blocks.flatMap(\.products)), style: ErrorReportStyle())
        return renderer.lines(for: blocks[index]).first
    }

    /// The products a report's records name, each once, as the headings count them: a
    /// tree product once, by its folder.
    public static func productsWithoutValue(_ records: [ErrorRecord]) -> Set<String> {
        Set(records.flatMap { $0.products.map(ProductNames.key(of:)) })
    }

    // MARK: - Blocks

    /// Every record's causes, merged, in the order of their first lines: the same graph
    /// gives the same report.
    static func blocks(for records: [ErrorRecord]) -> [ErrorBlock] {
        var blocks: [ErrorBlock] = []
        var index: [ErrorDocument.MergeKey: Int] = [:]
        for record in records {
            for cause in record.document.causes {
                guard let position = index[cause.mergeKey] else {
                    index[cause.mergeKey] = blocks.count
                    blocks.append(ErrorBlock(document: cause, subjects: cause.subject.map { [$0] } ?? [],
                                             products: record.products, facts: [record.facts]))
                    continue
                }
                if let subject = cause.subject, !blocks[position].subjects.contains(subject) {
                    blocks[position].subjects.append(subject)
                }
                for product in record.products where !blocks[position].products.contains(product) {
                    blocks[position].products.append(product)
                }
                if !blocks[position].facts.contains(record.facts) {
                    blocks[position].facts.append(record.facts)
                }
            }
        }
        // Rendered plain for the order, so colour never moves a block.
        let plain = ErrorReportStyle()
        return blocks
            .map { ($0, BlockRenderer(names: ProductNames(products: blocks.flatMap(\.products)), style: plain)
                        .lines(for: $0).joined(separator: "\n")) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    // MARK: - Headings

    /// The products that share one set of errors, under one heading: `productKeys` in path order,
    /// empty for the errors no product needs; `blocks` indices into the report's blocks, in
    /// line-one order.
    struct Group: Equatable {
        var productKeys: [String]
        var blocks:      [Int]
    }

    /// One group per set of products with the same errors, in path order of each group's
    /// first product, and the errors no product needs last.
    static func groups(of blocks: [ErrorBlock]) -> [Group] {
        var blocksByKey: [String: [Int]] = [:]
        var unneeded: [Int] = []
        for (index, block) in blocks.enumerated() {
            let productKeys = Set(block.products.map(ProductNames.key(of:)))
            if productKeys.isEmpty {
                unneeded.append(index)
            }
            for key in productKeys.sorted() {
                blocksByKey[key, default: []].append(index)
            }
        }
        var groups: [Group] = []
        var positionBySet: [[Int]: Int] = [:]
        for key in blocksByKey.keys.sorted() {
            let set = blocksByKey[key] ?? []
            if let position = positionBySet[set] {
                groups[position].productKeys.append(key)
            } else {
                positionBySet[set] = groups.count
                groups.append(Group(productKeys: [key], blocks: set))
            }
        }
        if !unneeded.isEmpty {
            groups.append(Group(productKeys: [], blocks: unneeded))
        }
        return groups
    }

    /// Each heading and its errors: an error in full under the first heading that needs
    /// it, and by its first line and `(above)` under every later one, so the report holds
    /// each error once and every product's heading still names all it waits on.
    private static func groupLines(_ blocks: [ErrorBlock], style: ErrorReportStyle) -> [String] {
        let names    = ProductNames(products: blocks.flatMap(\.products))
        let renderer = BlockRenderer(names: names, style: style)
        var printed: Set<Int> = []
        var lines: [String] = []
        for group in groups(of: blocks) {
            lines.append(renderer.heading(group.productKeys.isEmpty ? noProductHeading : names.heading(ofKeys: group.productKeys)))
            var afterAbove = false
            for index in group.blocks {
                if printed.contains(index) {
                    lines.append(renderer.aboveLine(for: blocks[index]))
                    afterAbove = true
                    continue
                }
                if afterAbove {
                    lines.append("")
                    afterAbove = false
                }
                printed.insert(index)
                lines.append(contentsOf: renderer.lines(for: blocks[index]))
                lines.append("")
            }
            if lines.last != "" {
                lines.append("")
            }
        }
        return lines
    }

    private static func productCount(_ blocks: [ErrorBlock]) -> Int {
        Set(blocks.flatMap { $0.products.map(ProductNames.key(of:)) }).count
    }
}

// MARK: - Product names

/// How a heading names products: by file name, and by the path under `output:` only
/// where two products of the report share a file name. A tree product is named by its
/// folder, `IceCubesApp.app/`, once for all its entries.
public struct ProductNames {
    private let ambiguous: Set<String>

    public init(products: [StoppedProduct]) {
        var keysByName: [String: Set<String>] = [:]
        for product in products {
            let key = Self.key(of: product)
            keysByName[Self.fileName(of: key), default: []].insert(key)
        }
        ambiguous = Set(keysByName.filter { $0.value.count > 1 }.keys)
    }

    /// The product a heading's name stands for: its own path, or its tree's folder with a
    /// separator.
    public static func key(of product: StoppedProduct) -> String {
        product.treeFolder.map { "\($0)/" } ?? product.path
    }

    /// The names of the products, each once, in path order.
    func names(of products: [StoppedProduct]) -> [String] {
        Set(products.map(Self.key(of:))).sorted().map(name(ofKey:))
    }

    /// A heading for products by their keys: three names in path order, then how many
    /// more, and a colon.
    func heading(ofKeys keys: [String]) -> String {
        let named = keys.sorted().map { Self.headingName(name(ofKey: $0)) }
        let shown = named.prefix(ErrorReportRenderer.productsNamed).joined(separator: ", ")
        let rest  = named.count - ErrorReportRenderer.productsNamed
        return (rest > 0 ? "\(shown) and \(rest) more" : shown) + ":"
    }

    /// A name as a heading carries it: a tree's without its separator, since the colon
    /// after it ends the name.
    public static func headingName(_ name: String) -> String {
        name.hasSuffix("/") ? String(name.dropLast()) : name
    }

    /// One product's name, a tree's with its separator: its file name, or its path under
    /// `output:` where another product these names were made for shares the file name.
    public func name(of product: StoppedProduct) -> String {
        name(ofKey: Self.key(of: product))
    }

    func name(of path: String, isTree: Bool) -> String {
        name(ofKey: isTree ? "\(path)/" : path)
    }

    private func name(ofKey key: String) -> String {
        let fileName = Self.fileName(of: key)
        guard ambiguous.contains(fileName) else {
            return fileName
        }
        return OutputPaths.underOutput(key)
    }

    /// The last component of a product's path, a tree's with its separator.
    static func fileName(of key: String) -> String {
        let isTree = key.hasSuffix("/")
        let trimmed = isTree ? String(key.dropLast()) : key
        let name = Path(trimmed).lastComponent ?? trimmed
        return isTree ? "\(name)/" : name
    }
}

enum OutputPaths {
    /// A path in the output file system without its root: what a heading falls back to.
    static func underOutput(_ path: String) -> String {
        let prefix = "\(FileSystemName.output)/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

// MARK: - One block

/// Draws one block. The two `switch`es a report is made of are here: one over every
/// `ErrorCondition`, in `ConditionLines`, and one each over `Subject` and `Remedy`.
struct BlockRenderer {
    let names: ProductNames
    let style: ErrorReportStyle

    func lines(for block: ErrorBlock) -> [String] {
        var lines = diagnosticLines(block.document.diagnostic)
        if let subjectLine = subjectLine(block.subjects) {
            lines.append(subjectLine)
        }
        if let remedy = block.document.remedy {
            lines.append(remedyLine(remedy))
        }
        if style.verbose {
            lines.append(contentsOf: verboseLines(block.facts))
        }
        return lines
    }

    // MARK: Line one

    /// Line one and what continues it, indented under it.
    private func diagnosticLines(_ diagnostic: ErrorDocument.Diagnostic) -> [String] {
        switch diagnostic {
        case .tool(let text, _):
            let printed = text
                .components(separatedBy: "\n")
                .map { substituted($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
                .filter { !$0.isEmpty }
            guard let first = printed.first else {
                return [""]
            }
            return [styledToolLine(first)] + printed.dropFirst().map { "  \(styledToolLine($0))" }
        case .engine(let condition):
            let drawn = ConditionLines(path: displayed).lines(for: condition)
            let headline = drawn.path.map { bold($0) + drawn.headline } ?? drawn.headline
            return [headline] + drawn.details.map { labelled($0.label, $0.value) } + drawn.continuation.map { "  \($0)" }
        case .several(let documents):
            // Expanded into blocks before a block is drawn; drawn here only for a caller
            // that hands one over whole.
            return documents.flatMap { diagnosticLines($0.diagnostic) }
        }
    }

    /// A tool's line, with the engine's `input:/` written as the path on disk relative to
    /// the session's base — the input file system's root is the base, so the prefix is
    /// dropped and the base itself never printed: a substitution of a known prefix, not a
    /// reading of the text.
    private func substituted(_ line: String) -> String {
        line.replacingOccurrences(of: "\(FileSystemName.input)/", with: "")
    }

    /// The location bold and `error:` red, on a line that has them: presentation only, so
    /// a line that has neither is drawn as it is.
    private func styledToolLine(_ line: String) -> String {
        guard style.colour, let marker = line.range(of: ": error:") else {
            return line
        }
        let location = String(line[..<marker.lowerBound])
        let rest     = String(line[marker.upperBound...])
        return bold(location) + ": " + red("error:") + rest
    }

    /// A path in the input file system as the reader finds it on disk, relative to the base.
    private func displayed(_ path: String) -> String {
        let root = FileSystemName.input
        if path == root || path == "\(root)/" {
            return "."
        }
        if path.hasPrefix("\(root)/") {
            return String(path.dropFirst(root.count + 1))
        }
        return path
    }

    // MARK: Subject

    private func subjectLine(_ subjects: [ErrorDocument.Subject]) -> String? {
        guard let first = subjects.first else {
            return nil
        }
        let values = subjects.map(subjectValue)
        var seen: Set<String> = []
        let unique = values.filter { seen.insert($0).inserted }
        return labelled(subjectLabel(first), unique.joined(separator: ", "))
    }

    private func subjectLabel(_ subject: ErrorDocument.Subject) -> String {
        switch subject {
        case .target:   return "target"
        case .product:  return "product"
        case .package:  return "package"
        case .resource: return "resource"
        case .formula:  return "formula"
        case .project:  return "project"
        case .source:   return "source"
        }
    }

    private func subjectValue(_ subject: ErrorDocument.Subject) -> String {
        switch subject {
        case .target(let name):    return name
        case .package(let name):   return name
        case .product(let path):   return Path(path).lastComponent ?? path
        case .resource(let path):  return Path(path).lastComponent ?? path
        case .project(let path):   return Path(path).lastComponent ?? path
        case .formula(let path):   return displayed(path)
        case .source(let path):    return displayed(path)
        }
    }

    // MARK: Headings

    /// A heading, bold where there is colour.
    func heading(_ text: String) -> String {
        bold(text)
    }

    /// An error already printed under an earlier heading: its first line, and `(above)`.
    func aboveLine(for block: ErrorBlock) -> String {
        (diagnosticLines(block.document.diagnostic).first ?? "") + " " + dim(ErrorReportRenderer.aboveMarker)
    }

    // MARK: Remedy

    private func remedyLine(_ remedy: ErrorDocument.Remedy) -> String {
        switch remedy {
        case .relock:
            return labelled("re-lock with", "semel-swift prepare")
        case .missingFolder(let tried):
            guard let first = tried.first else {
                return labelled("missing", "a folder")
            }
            let others = tried.dropFirst()
            return labelled("missing", others.isEmpty ? first : "\(first) (also tried \(others.joined(separator: ", ")))")
        case .setting(let keys):
            return labelled("set", keys.joined(separator: ", "))
        case .register(let kind):
            return labelled("register", "kind \(kind)")
        case .registerType(let name):
            return labelled("register", name)
        case .writeMachineFile(let commands):
            let written = commands.map { command in
                ([command.command, command.folder ?? MachineFileWriter.folderPlaceholder] + command.flags).joined(separator: " ")
            }
            return labelled("write with", written.joined(separator: " and "))
        case .vendor:
            return labelled("vendor with", "semel-swift prepare")
        case .delete(let path):
            return labelled("delete", path)
        }
    }

    // MARK: --verbose

    private func verboseLines(_ facts: [ErrorFacts]) -> [String] {
        var types: [String] = []
        var idsByType: [String: [Int64]] = [:]
        var ports: Set<String> = []
        var carried = 0
        for fact in facts {
            if idsByType[fact.nodeType] == nil {
                types.append(fact.nodeType)
            }
            idsByType[fact.nodeType, default: []].append(contentsOf: fact.nodeIDs)
            ports.formUnion(fact.ports)
            carried += fact.carrierCount
        }
        let nodes = types.map { type in
            "\(type) " + (idsByType[type] ?? []).sorted().map { "#\($0)" }.joined(separator: ", ")
        }
        return [labelled("node", nodes.joined(separator: "; ")),
                labelled("ports", ports.sorted().joined(separator: ", ")),
                labelled("carried by", "\(carried) \(carried == 1 ? "node" : "nodes")")]
    }

    // MARK: Drawing

    private func labelled(_ label: String, _ value: String) -> String {
        "  \(dim("\(label):")) \(value)"
    }

    private func bold(_ text: String) -> String {
        style.colour ? "\u{1B}[1m\(text)\u{1B}[0m" : text
    }

    private func red(_ text: String) -> String {
        style.colour ? "\u{1B}[31m\(text)\u{1B}[0m" : text
    }

    private func dim(_ text: String) -> String {
        style.colour ? "\u{1B}[2m\(text)\u{1B}[0m" : text
    }
}
