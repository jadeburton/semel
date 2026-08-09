//
//  ProjectBuilder.swift
//  build_system
//

public struct ProjectBuilder: NodeFunction {
    public static let kind: UInt = 6

    static let projectFileInputPort = "projectFile"
    static let productInputPort     = "input"
    static let statusOutputPort     = "status"
    static let foldersInputPort     = "folders"

    static let descriptor = NodeFunctionDescriptor(
        inputPorts: [
            .required(projectFileInputPort),
            .dynamic(productInputPort),
            .dynamic(foldersInputPort),
        ],
        outputPorts: [statusOutputPort]
    )

    var embeddedNode: Node?

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        let inputValue = input.inputValues[Self.projectFileInputPort]!.first!
        let projectFileName    = inputValue.key
        let projectFileContent = try inputValue.value.expectValue().resolveAsString()

        let parentFolder = (Path(projectFileName).deletingLastComponent) ?? Path(".")

        // Decode any folder manifests already wired to our 'folders' port.
        // On the first run these are empty; subsequent runs have real data.
        let folderManifests = decodeFolderManifests(input.inputValues[Self.foldersInputPort] ?? [:])

        // Record every folder path that the formula references via a glob so we can
        // wire them and trigger re-processing when their contents change.
        final class GlobRecord { var folderPaths = Set<String>() }
        let record  = GlobRecord()
        let capture = self   // value-type copy for use inside @escaping closure

        let globber: (String) throws -> [String] = { pattern in
            let folder = capture.extractFolderPath(fromGlobPattern: pattern)
            if !folder.isEmpty { record.folderPaths.insert(folder) }
            return capture.globMatch(pattern: pattern,
                                     folderPath: folder,
                                     manifests: folderManifests)
        }

        let products = try FormulaFile.parse(projectFileContent,
                                             basePath: parentFolder,
                                             globber: globber)

        // There are two kinds of Formula files. One contains no globber wildcards; the other does.
        // Formula files with wildcards require multiple passes and the initial passes may not yet have discovered all files,
        // resulting in empty entries in the GraphShape expectations, which then cause errors when we attempt to apply them.
        // These errors will cause all other expectations to fail, which we don't want - we need the folder expectations to work.
        // To avoid this, we just don't output any product expectations until we have one or more folders bound.

        // Build output-file expectations for each formula product.
        var productExpectations = [String: String]()

        // Either we don't have any globbing or we do, and we have bound folders - then emit product expectations
        if record.folderPaths.isEmpty || !folderManifests.isEmpty {

            for (productName, shapeNode) in products {

                let fullPath = Path(Folder.outputFileSystemName)
                    / (parentFolder.deletingFirstComponent ?? Path(""))
                    / Path(productName)

                let wrapper = try GraphShapeNode.parse(
                    "OutputFile(path: '\(fullPath)', input: ['product': \(shapeNode.asString(omitOutputPort: false))]).status"
                )

                productExpectations[fullPath.string] = wrapper.asString(omitOutputPort: false)
            }

        }

        // Wire each glob-referenced folder's manifest into our 'folders' port so we
        // are automatically rescheduled whenever the folder's contents change.
        var folderExpectations = [String: String]()
        for folderPath in record.folderPaths {
            folderExpectations[folderPath] = "Folder(path: '\(folderPath)').manifest"
        }

        return .init(
            outputValues: [Self.statusOutputPort: .value("OK".intern())],
            inputWireExpectations: [
                Self.productInputPort: productExpectations,
                Self.foldersInputPort: folderExpectations
            ]
        )
    }

    // MARK: - Glob helpers

    /// Extracts the base folder path from a glob pattern — everything before the
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
                  let manifest: FolderManifest = try? PolyFactory.decodeAndCast(encodedJSON: json)
            else { continue }
            result[folderPath] = manifest
        }
        return result
    }

    /// Return the sorted list of logical paths that satisfy `pattern`, matched
    /// against the immediate pinned-file children of the relevant folder manifest.
    private func globMatch(
        pattern: String,
        folderPath: String,
        manifests: [String: FolderManifest]
    ) -> [String] {
        guard !folderPath.isEmpty, let manifest = manifests[folderPath] else { return [] }

        // The segment pattern is whatever follows "folderPath/" in the full pattern.
        let tailPattern = String(pattern.dropFirst(folderPath.count + 1))

        return manifest.entries
            .filter { entry in
                !entry.name.hasPrefix(".")
                    && !entry.isFolder
                    && entry.isPinned
                    && segmentMatches(pattern: tailPattern, name: entry.name)
            }
            .map { "\(folderPath)/\($0.name)" }
            .sorted()
    }

    // Standard NFA-free glob matcher (same algorithm as FileWildcardMatcher).
    private func segmentMatches(pattern: String, name: String) -> Bool {
        let p = Array(pattern.unicodeScalars)
        let t = Array(name.unicodeScalars)
        var pi = 0, ti = 0, starPI = -1, starTI = -1
        while ti < t.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == t[ti]) {
                pi += 1; ti += 1
            } else if pi < p.count && p[pi] == "*" {
                starPI = pi + 1; starTI = ti; pi += 1
            } else if starPI != -1 {
                starTI += 1; ti = starTI; pi = starPI
            } else { return false }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
