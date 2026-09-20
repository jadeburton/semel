//
//  ProjectBuilder.swift
//  semel
//

import SemelNodeKit

public struct ProjectBuilder: Node {
    public static let kind: UInt = 6

    static let projectFileInputPort   = "projectFile"
    static let productInputPort       = "input"
    static let statusOutputPort       = "status"
    /// The set of product paths that currently exist, carried between passes so
    /// ProductPresence can say what appeared or disappeared. See ProductPresence.
    static let productsOutputPort     = "products"
    static let foldersInputPort       = "folders"
    static let graphImportsInputPort  = "graphImports"
    /// The formula text each `include <expr>` statement's node produces, keyed by the
    /// node's rendered spec — which is also the spec wired there. The engine knows nothing
    /// about what the node is; a Swift package's is `SwiftFormulaConverter(path: <.>)`.
    static let includesInputPort      = "includes"
    /// The tree value behind each product named with a trailing `/`, keyed by the product
    /// folder's output path. Read on the next pass and expanded into one `OutputFile` per
    /// entry, the way a wildcard's folder manifest is.
    static let treesInputPort         = "trees"

    /// Whether `spec` gets `projectRootProperty` stamped on it: true for a node with a
    /// static input port, the ones the cache handles, and false for a file-system node,
    /// which is shared by every project that reads it.
    static func isCacheable(_ spec: GraphSpecNode) -> Bool {
        guard let type = TypeRegistry.nodeType(forTypeName: spec.typeName) as? Node.Type else {
            return false
        }
        return !type.descriptor.staticInputPorts.isEmpty
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [
            .required(projectFileInputPort),
            .dynamic(productInputPort),
            .dynamic(foldersInputPort),
            .dynamic(treesInputPort),
            .dynamic(graphImportsInputPort),
            .dynamic(includesInputPort),
        ],
        outputPorts: [statusOutputPort, productsOutputPort]
    )

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let inputValue = input.inputValues[Self.projectFileInputPort]!.first!
        let projectFileName    = inputValue.key
        let projectFileContent = try inputValue.value.expectValue().resolveAsString()

        // Base for resolving <rel/path> literals inside the formula text.
        let parentFolder = (Path(projectFileName).deletingLastComponent) ?? Path(".")

        // Where this project's products are written.  Deliberately separate from
        // `parentFolder`: only the ProjectFinder plugin that created this node knows
        // whether the project file *is* the project's directory (a Swift package is wired
        // by its package folder) or merely sits inside it (a .fmla file).  Inferring it
        // from the wire key put a package's products in its *parent*, so a package whose
        // folder also held other packages produced a file on the very path their output
        // folder needed — two children of one folder with the same name.
        let outputFolder = thisNode.properties["outputFolder"].map { Path($0) } ?? parentFolder

        // Decode any folder manifests already wired to our 'folders' port.
        // On the first run these are empty; subsequent runs have real data.
        let folderManifests = decodeFolderManifests(input.inputValues[Self.foldersInputPort] ?? [:])
        let treeManifests   = decodeTreeManifests(input.inputValues[Self.treesInputPort] ?? [:])

        // Record every folder path the formula references via a wildcard and every file
        // path it references via import(), so we can wire them and be rescheduled
        // whenever their contents change.
        final class GlobRecord   { var folderPaths = Set<String>() }
        final class ImportRecord { var filePaths = Set<String>(); var anyMissing = false }

        let record       = GlobRecord()
        let importRecord = ImportRecord()
        let capture      = self   // value-type copy for use inside @escaping closures

        let wildcardExpander: (String) throws -> [String] = { pattern in
            let folder = capture.extractFolderPath(fromGlobPattern: pattern)
            if !folder.isEmpty { record.folderPaths.insert(folder) }
            return capture.wildcardMatch(pattern: pattern,
                                     folderPath: folder,
                                     manifests: folderManifests)
        }

        let fileReader: (String) throws -> String? = { path in
            importRecord.filePaths.insert(path)
            guard let nodeValue = input.inputValues[Self.graphImportsInputPort]?[path] else {
                importRecord.anyMissing = true
                return nil
            }
            return try nodeValue.expectValue().resolveAsString()
        }

        // An included formula arrives on a wire of its own, the same way an imported file
        // does: the node the `include` names is recorded by its spec so it can be wired,
        // absent or still pending on the first passes, present once that node has run.
        final class IncludeRecord { var specs = Set<String>(); var anyMissing = false }
        let includeRecord = IncludeRecord()

        let includeReader: (String) throws -> String? = { spec in
            includeRecord.specs.insert(spec)
            guard let nodeValue = input.inputValues[Self.includesInputPort]?[spec],
                  let hash = try? nodeValue.expectValue() else {
                includeRecord.anyMissing = true
                return nil
            }
            return try hash.resolveAsString()
        }

        let products = try FormulaFile.parse(projectFileContent,
                                             basePath: parentFolder,
                                             wildcardExpander: wildcardExpander,
                                             fileReader: fileReader,
                                             includeReader: includeReader)

        // There are two kinds of Formula files: those without wildcardExpander wildcards, and
        // those with. Files with wildcards require multiple passes — the initial passes
        // may not have discovered all files yet, resulting in an empty objectFiles list
        // that would produce bad product specs. Similarly, imported .graph files
        // may not be wired yet on the first pass. In both cases we suppress product
        // specs until all dependencies are ready, while still emitting the wire
        // specs that will make the missing dependencies available on the next pass.

        // Build output-file specs for each formula product.
        var productSpecs = [String: String]()
        // The tree-valued expressions behind tree products, keyed by the product folder.
        var treeSpecs = [String: String]()

        let wildcardsReady   = record.folderPaths.isEmpty || !folderManifests.isEmpty
        let importsReady = !importRecord.anyMissing
        let includesReady = !includeRecord.anyMissing

        /// The wrapper that publishes `shapeNode`'s value at `fullPath`, with the source's
        /// `fileMetadata` port wired in when it has one, so chmod can be applied on cp.
        func outputFileSpec(fullPath: Path, shapeNode: GraphSpecNode) throws -> String {
            let shapeNode = shapeNode.adding(property: Self.projectRootProperty, value: outputFolder.string,
                                             where: Self.isCacheable)
            var metadataWire = ""
            if let nodeType = TypeRegistry.nodeType(forTypeName: shapeNode.typeName) as? Node.Type,
               nodeType.descriptor.outputPorts.contains(FileMetadata.portName) {
                let metaShape = GraphSpecNode(typeName: shapeNode.typeName,
                                               properties: shapeNode.properties,
                                               inputs: shapeNode.inputs,
                                               outputs: shapeNode.outputs,
                                               outputPort: FileMetadata.portName)
                metadataWire = ", \(FileMetadata.portName): ['metadata': \(metaShape.asString(omitOutputPort: false))]"
            }
            let wrapper = try GraphSpecNode.parse(
                "OutputFile(path: '\(fullPath)', input: ['product': \(shapeNode.asString(omitOutputPort: false))]\(metadataWire)).status"
            )
            return wrapper.asString(omitOutputPort: false)
        }

        /// Two products at one path would be two nodes with one name in one folder; the
        /// formula is wrong, and saying which path is the whole help there is.
        func publish(_ fullPath: Path, _ spec: String) throws {
            guard productSpecs[fullPath.string] == nil else {
                throw NodeError.other(message: "two products at \(fullPath)")
            }
            productSpecs[fullPath.string] = spec
        }

        if wildcardsReady && importsReady && includesReady {
            // Sorted: a duplicate path must be reported the same way every pass.
            for (productName, shapeNode) in products.sorted(by: { $0.key < $1.key }) {

                let fullPath = Path(Folder.outputFileSystemName)
                    / (outputFolder.deletingFirstComponent ?? Path(""))
                    / Path(productName)

                guard productName.hasSuffix("/") else {
                    try publish(fullPath, try outputFileSpec(fullPath: fullPath, shapeNode: shapeNode))
                    continue
                }

                // A tree product: the expression's value is a manifest of files, decided
                // by the node that made them, so it is wired here first and expanded once
                // it has arrived — as a wildcard's folder manifest is. Until then the
                // tree's files are simply not yet products.
                let treeSpec = shapeNode
                    .adding(property: Self.projectRootProperty, value: outputFolder.string, where: Self.isCacheable)
                    .asString(omitOutputPort: false)
                treeSpecs[fullPath.string] = treeSpec
                guard let manifest = treeManifests[fullPath.string] else {
                    continue
                }
                for entry in manifest.entries {
                    let entryShape = try GraphSpecNode.parse(
                        "TreeFile(name: '\(entry.path)', tree: ['tree': \(treeSpec)]).output")
                    let entryPath = fullPath / Path(entry.path)
                    try publish(entryPath, try outputFileSpec(fullPath: entryPath, shapeNode: entryShape))
                }
            }
        }

        // Wire each wildcard-referenced folder's manifest into our 'folders' port so we
        // are automatically rescheduled whenever the folder's contents change.
        var folderSpecs = [String: String]()
        for folderPath in record.folderPaths {
            folderSpecs[folderPath] = "Folder(path: '\(folderPath)').manifest"
        }

        // Wire each imported .graph file into our 'graphImports' port so we are
        // automatically rescheduled whenever its content changes.
        var importSpecs = [String: String]()
        for importPath in importRecord.filePaths {
            importSpecs[importPath] = "StaticFile(path: '\(importPath)').output"
        }

        // Wire every node an `include` names: the spec is both the wire's key and what is
        // wired there. Nothing here knows what the node is.
        var includeSpecs = [String: String]()
        for spec in includeRecord.specs {
            includeSpecs[spec] = spec
        }

        // Which products exist, and what that means happened. The decision lives in
        // ProductPresence; all this does is hand it the previous set and the statuses
        // arriving on the product port, and report what comes back.
        let (productEvents, existingProducts) = ProductPresence.reconcile(
            existingBefore: ProductPresence.decode(try thisNode.readFromOutputPort(Self.productsOutputPort)),
            statuses: (input.inputValues[Self.productInputPort] ?? [:]))

        for event in productEvents {
            // Only deletions are printed. A creation is already announced by OutputFile's
            // own status line, and saying it twice would be worse than not saying it.
            if case .deleted(let path) = event {
                BuildEngine.notice("\(path): Deleted")
            }
        }

        return .init(
            outputValues: [Self.statusOutputPort:   .value(try "OK".intern()),
                           Self.productsOutputPort: .value(try ProductPresence.encode(existingProducts).intern())],
            inputWireSpecs: [
                Self.productInputPort:         productSpecs,
                Self.foldersInputPort:         folderSpecs,
                Self.treesInputPort:           treeSpecs,
                Self.graphImportsInputPort:    importSpecs,
                Self.includesInputPort:        includeSpecs,
            ]
        )
    }

    // MARK: - Glob helpers

    /// Extracts the base folder path from a wildcard pattern — everything before the
    /// first wildcard character, trimmed to the last '/'.
    /// e.g.  "input:/src/*.c"  →  "input:/src"
    ///        "input:/**/*.c"  →  "input:"
    private func extractFolderPath(fromGlobPattern pattern: String) -> String {
        guard let wildcardIdx = pattern.firstIndex(where: { $0 == "*" || $0 == "?" }) else {
            return ""
        }
        let prefix = String(pattern[..<wildcardIdx])
        if let lastSlash = prefix.lastIndex(of: "/") {
            return String(prefix[..<lastSlash])
        }
        return ""
    }

    /// Decode the `FolderManifest` values arriving on the 'folders' dynamic port.
    private func decodeFolderManifests(_ inputs: [String: NodeValue]) -> [String: FolderManifest] {
        var result: [String: FolderManifest] = [:]

        for (folderPath, nodeValue) in inputs {

            guard let json = try? nodeValue.expectValue().resolveAsString(),
                  let manifest: FolderManifest = try? TypeRegistry.decodeAndCast(encodedJSON: json) else {

                continue
            }

            result[folderPath] = manifest
        }
        return result
    }

    /// Decode the `TreeManifest` values arriving on the 'trees' dynamic port. A tree that
    /// is pending or errored is skipped: its files are not products yet, and the error is
    /// the producing node's to report.
    private func decodeTreeManifests(_ inputs: [String: NodeValue]) -> [String: TreeManifest] {
        var result: [String: TreeManifest] = [:]

        for (productFolder, nodeValue) in inputs {

            guard let json = try? nodeValue.expectValue().resolveAsString(),
                  let manifest: TreeManifest = try? TypeRegistry.decodeAndCast(encodedJSON: json) else {

                continue
            }

            result[productFolder] = manifest
        }
        return result
    }

    /// Return the sorted list of logical paths that satisfy `pattern`, matched
    /// against the immediate pinned-file children of the relevant folder manifest.
    private func wildcardMatch(
        pattern: String,
        folderPath: String,
        manifests: [String: FolderManifest]
    ) -> [String] {
        guard !folderPath.isEmpty, let manifest = manifests[folderPath] else {
            return []
        }

        // The segment pattern is whatever follows "folderPath/" in the full pattern.
        let tailPattern = String(pattern.dropFirst(folderPath.count + 1))

        return manifest.entries
            .filter { entry in
                !entry.name.hasPrefix(".")
                    && !entry.isFolder
                    && entry.isPinned
                    && WildcardSegment.matches(pattern: tailPattern, name: entry.name)
            }
            .map { "\(folderPath)/\($0.name)" }
            .sorted()
    }
}
