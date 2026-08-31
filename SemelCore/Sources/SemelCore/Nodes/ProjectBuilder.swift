//
//  ProjectBuilder.swift
//  build_system
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

    public static let descriptor = NodeDescriptor(
        inputPorts: [
            .required(projectFileInputPort),
            .dynamic(productInputPort),
            .dynamic(foldersInputPort),
            .dynamic(graphImportsInputPort),
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

        let products = try FormulaFile.parse(projectFileContent,
                                             basePath: parentFolder,
                                             wildcardExpander: wildcardExpander,
                                             fileReader: fileReader)

        // There are two kinds of Formula files: those without wildcardExpander wildcards, and
        // those with. Files with wildcards require multiple passes — the initial passes
        // may not have discovered all files yet, resulting in an empty objectFiles list
        // that would produce bad product expectations. Similarly, imported .graph files
        // may not be wired yet on the first pass. In both cases we suppress product
        // expectations until all dependencies are ready, while still emitting the wire
        // expectations that will make the missing dependencies available on the next pass.

        // Build output-file expectations for each formula product.
        var productExpectations = [String: String]()

        let wildcardsReady   = record.folderPaths.isEmpty || !folderManifests.isEmpty
        let importsReady = !importRecord.anyMissing

        if wildcardsReady && importsReady {
            for (productName, shapeNode) in products {

                let fullPath = Path(Folder.outputFileSystemName)
                    / (outputFolder.deletingFirstComponent ?? Path(""))
                    / Path(productName)

                // If the source node type exposes a "fileMetadata" output port,
                // wire it into the OutputFile wrapper so chmod can be applied on cp.
                var metadataWire = ""
                if let nodeType = TypeRegistry.nodeType(forTypeName: shapeNode.typeName) as? Node.Type,
                   nodeType.descriptor.outputPorts.contains(FileMetadata.portName) {
                    let metaShape = GraphShapeNode(typeName: shapeNode.typeName,
                                                   properties: shapeNode.properties,
                                                   inputs: shapeNode.inputs,
                                                   outputs: shapeNode.outputs,
                                                   outputPort: FileMetadata.portName)
                    metadataWire = ", \(FileMetadata.portName): ['metadata': \(metaShape.asString(omitOutputPort: false))]"
                }

                let wrapper = try GraphShapeNode.parse(
                    "OutputFile(path: '\(fullPath)', input: ['product': \(shapeNode.asString(omitOutputPort: false))]\(metadataWire)).status"
                )

                productExpectations[fullPath.string] = wrapper.asString(omitOutputPort: false)
            }
        }

        // Wire each wildcard-referenced folder's manifest into our 'folders' port so we
        // are automatically rescheduled whenever the folder's contents change.
        var folderExpectations = [String: String]()
        for folderPath in record.folderPaths {
            folderExpectations[folderPath] = "Folder(path: '\(folderPath)').manifest"
        }

        // Wire each imported .graph file into our 'graphImports' port so we are
        // automatically rescheduled whenever its content changes.
        var importExpectations = [String: String]()
        for importPath in importRecord.filePaths {
            importExpectations[importPath] = "StaticFile(path: '\(importPath)').output"
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
                print("\(path): Deleted")
            }
        }

        return .init(
            outputValues: [Self.statusOutputPort:   .value(try "OK".intern()),
                           Self.productsOutputPort: .value(try ProductPresence.encode(existingProducts).intern())],
            inputWireExpectations: [
                Self.productInputPort:      productExpectations,
                Self.foldersInputPort:      folderExpectations,
                Self.graphImportsInputPort: importExpectations,
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
