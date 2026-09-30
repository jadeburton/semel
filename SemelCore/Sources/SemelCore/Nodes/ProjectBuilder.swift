//
//  ProjectBuilder.swift
//  semel
//

import SemelNodeKit

public struct ProjectBuilder: Node {
    public static let kind: UInt = 6
    /// 2: a `**` pattern walks down and demands the subfolders it reaches, and a capture
    /// after a `**` reads the file's own name (B-108).
    /// 3: every node that asks for its files' modes has them wired beside the files
    /// (`wiringFileMetadata`), a pushed file among the sources that publish one.
    /// 4: an include that cannot be read yet still asks for the includes after it (B-125).
    /// 5: a pattern's folder is asked for as a tree, one wire, and a `**` expands against
    /// it on the pass it arrives (B-135).
    public static let implementationVersion = 5

    static let outputFolderProperty   = "outputFolder"
    static let projectFileInputPort   = "projectFile"
    static let productInputPort       = "input"
    static let statusOutputPort       = "status"
    /// The subtree manifest of the folder each wildcard pattern names before its first
    /// wildcard, keyed by that folder's path (B-135): everything a pattern can match, at
    /// every depth, on one wire.
    static let folderTreesInputPort   = "folderTrees"
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
    /// which is shared by every project that reads it. A type name the registry does not
    /// know is also false, so the stamp depends on the toolchains the process registered.
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
            .dynamic(folderTreesInputPort),
            .dynamic(treesInputPort),
            .dynamic(graphImportsInputPort),
            .dynamic(includesInputPort),
        ],
        outputPorts: [statusOutputPort]
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
        let outputFolder = thisNode.properties[Self.outputFolderProperty].map { Path($0) } ?? parentFolder

        // The folder trees already wired to our 'folderTrees' port, keyed by folder path: one
        // per pattern's folder, each the whole tree below it. On the first run these are
        // empty; the run after has every one.
        let folderTrees   = FolderTreeWalk.trees(in: input, port: Self.folderTreesInputPort)
        let treeManifests = decodeTreeManifests(input.inputValues[Self.treesInputPort] ?? [:])

        // Record every folder path the formula references via a wildcard, and every file
        // path it references via import(), so we can wire them and be rescheduled whenever
        // their contents change.
        final class GlobRecord { var folderPaths = Set<String>() }
        final class ImportRecord { var filePaths = Set<String>(); var anyMissing = false }

        let record       = GlobRecord()
        let importRecord = ImportRecord()

        let wildcardExpander: (String) throws -> [String] = { pattern in
            let folder = Self.extractFolderPath(fromGlobPattern: pattern)
            guard !folder.isEmpty else {
                return []
            }
            record.folderPaths.insert(folder)
            guard let tree = folderTrees[folder] else {
                return []
            }
            return try Self.wildcardMatch(pattern: pattern, folderPath: folder, tree: tree)
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
        // does: the node the `include` names is recorded — its rendered spec is the wire's
        // name, its tree is what is wired there — so it can be wired, absent or still
        // pending on the first passes, present once that node has run.
        final class IncludeRecord { var specs: [String: GraphSpecNode] = [:]; var anyMissing = false }
        let includeRecord = IncludeRecord()

        let includeReader: (GraphSpecNode) throws -> String? = { included in
            let spec = included.asString(omitOutputPort: false)
            includeRecord.specs[spec] = included
            guard let nodeValue = input.inputValues[Self.includesInputPort]?[spec],
                  let hash = try? nodeValue.expectValue() else {
                includeRecord.anyMissing = true
                return nil
            }
            return try hash.resolveAsString()
        }

        // An `except` that removes every item is an error only once the trees have arrived:
        // before, a pattern has matched nothing, so `{f: <src/**/*.c> except <src/gen.c>}`
        // removes all it has so far. Thrown then, the pass would return no specs, the tree
        // would never be demanded, and the error would stand for good; the specs the pass
        // did record ask for the trees instead (B-55).
        let products: [String: GraphSpecNode]
        do {
            products = try FormulaFile.parse(projectFileContent,
                                             basePath: parentFolder,
                                             wildcardExpander: wildcardExpander,
                                             fileReader: fileReader,
                                             includeReader: includeReader)
        } catch FormulaParseError.forEachExceptLeavesNothing where !record.folderPaths.isSubset(of: Set(folderTrees.keys)) {
            products = [:]
        }

        // There are two kinds of Formula files: those without wildcardExpander wildcards, and
        // those with. Files with wildcards require multiple passes — the initial passes
        // may not have discovered all files yet, resulting in an empty objectFiles list
        // that would produce bad product specs. Similarly, imported .graph files
        // may not be wired yet on the first pass. In both cases we suppress product
        // specs until all dependencies are ready, while still emitting the wire
        // specs that will make the missing dependencies available on the next pass.

        // Build output-file specs for each formula product.
        var productSpecs = [String: GraphSpecNode]()
        // The tree-valued expressions behind tree products, keyed by the product folder.
        var treeSpecs = [String: GraphSpecNode]()

        // A pattern has its whole answer once its folder's tree has arrived: the tree is every
        // name below the folder, so no pattern waits on a walk.
        let wildcardsReady = record.folderPaths.isSubset(of: Set(folderTrees.keys))
        let importsReady = !importRecord.anyMissing
        let includesReady = !includeRecord.anyMissing

        /// The wrapper that publishes `shapeNode`'s value at `fullPath`, with the source's
        /// `fileMetadata` port wired in when it has one, so chmod can be applied on cp.
        func outputFileSpec(fullPath: Path, shapeNode: GraphSpecNode) -> GraphSpecNode {
            let shapeNode = shapeNode.adding(property: Self.projectRootProperty, value: outputFolder.string,
                                             where: Self.isCacheable)
            return GraphSpecNode(OutputFile.self,
                                 properties: [OutputFile.pathProperty: fullPath.string],
                                 inputs: [OutputFile.inputPort: ["product": shapeNode]])
                .wiringFileMetadata()
                .port(OutputFile.statusOutputPort)
        }

        /// Two products at one path would be two nodes with one name in one folder; the
        /// formula is wrong, and saying which path is the whole help there is.
        func publish(_ fullPath: Path, _ spec: GraphSpecNode) throws {
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
                    try publish(fullPath, outputFileSpec(fullPath: fullPath, shapeNode: shapeNode))
                    continue
                }

                // A tree product: the expression's value is a manifest of files, decided
                // by the node that made them, so it is wired here first and expanded once
                // it has arrived — as a wildcard's folder manifest is. Until then the
                // tree's files are simply not yet products.
                let treeSpec = shapeNode
                    .adding(property: Self.projectRootProperty, value: outputFolder.string, where: Self.isCacheable)
                treeSpecs[fullPath.string] = treeSpec
                guard let manifest = treeManifests[fullPath.string] else {
                    continue
                }
                for entry in manifest.entries {
                    let entryShape = GraphSpecNode(TreeFile.self,
                                                   properties: [TreeFile.nameProperty: entry.path],
                                                   inputs: [TreeFile.treeInputPort: ["tree": treeSpec]])
                        .port(TreeFile.outputPort)
                    let entryPath = fullPath / Path(entry.path)
                    try publish(entryPath, outputFileSpec(fullPath: entryPath, shapeNode: entryShape))
                }
            }
        }

        // Wire each wildcard-referenced folder's tree into our 'folderTrees' port so we are
        // rescheduled whenever a name below it changes — a file added three folders down is
        // one a `**` matches. A pattern that reads one level is woken by a name deeper down
        // too; it expands to the same paths, and its products do not move.
        var folderSpecs = [String: GraphSpecNode]()
        for folderPath in record.folderPaths {
            folderSpecs[folderPath] = .folderTree(at: folderPath)
        }

        // Wire each imported .graph file into our 'graphImports' port so we are
        // automatically rescheduled whenever its content changes.
        var importSpecs = [String: GraphSpecNode]()
        for importPath in importRecord.filePaths {
            importSpecs[importPath] = .staticFile(at: importPath)
        }

        // Wire every node an `include` names: its rendered spec is the wire's name and its
        // tree is what is wired there. Nothing here knows what the node is.
        let includeSpecs = includeRecord.specs

        // Nothing here says what happened to the products. Which of them exist, and how
        // that differs from what the user was last told, is the engine's settle diff
        // against the artifact snapshot table (B-50) — answered once per settle, over the
        // whole graph, and durable across a restart, none of which a builder holding one
        // project's statuses can do.
        return .init(
            outputValues: [Self.statusOutputPort: .value(try "OK".intern())],
            inputWireSpecs: [
                Self.productInputPort:         productSpecs,
                Self.folderTreesInputPort:     folderSpecs,
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
    static func extractFolderPath(fromGlobPattern pattern: String) -> String {
        guard let wildcardIndex = pattern.firstIndex(where: { $0 == "*" || $0 == "?" }) else {
            return ""
        }
        let prefix = String(pattern[..<wildcardIndex])
        if let lastSlash = prefix.lastIndex(of: "/") {
            return String(prefix[..<lastSlash])
        }
        return ""
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

    /// The pinned files below `folderPath` whose path relative to it matches the rest of
    /// `pattern`, as full paths, sorted, read from the folder's `tree`.
    ///
    /// What follows `folderPath` is matched segment by segment (`WildcardPath`): `*` and
    /// `?` stay inside one name, and a `**` segment stands for zero or more folders, so
    /// `src/**/*.c` matches `src/a.c` and `src/lib/a.c` and `src/**` every file below
    /// `src`. A pattern whose rest is one name — `src/*.c` — reads `src`'s own listing and
    /// no other; one that goes deeper reads the tree down into the subfolders it can
    /// reach, never into a hidden one, as a hidden file is never matched either. The
    /// folder the pattern names before its first wildcard is taken as written, hidden or not.
    static func wildcardMatch(pattern: String,
                              folderPath: String,
                              tree: FolderSubtreeManifest) throws -> [String] {
        let base         = Path(folderPath)
        let restSegments = Path(String(pattern.dropFirst(folderPath.count + 1))).segments

        let manifests = try tree.folderManifests(at: folderPath) { subfolder in
            guard let relative = Path(subfolder).relative(to: base),
                  relative.lastComponent?.hasPrefix(".") == false else {
                return false
            }
            return WildcardPath.canMatchBelow(pattern: restSegments, folder: relative.segments)
        }

        var paths: [String] = []
        for (folder, manifest) in manifests.sorted(by: { $0.key < $1.key }) {
            guard let relativeFolder = Path(folder).relative(to: base) else {
                continue
            }
            for entry in manifest.entries where !entry.isFolder && entry.isPinned && !entry.name.hasPrefix(".") {
                let relative = relativeFolder / entry.name
                if WildcardPath.matches(pattern: restSegments, path: relative.segments) {
                    paths.append((Path(folder) / entry.name).string)
                }
            }
        }
        return paths.sorted()
    }
}
