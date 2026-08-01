// SwiftFormulaConverter.swift
// BuildSystemCore
//
// Converts a `swift package dump-package` JSON manifest into a .fmla formula
// string that ProjectBuilder can consume as its projectFile input.
//
// Wire topology:
//   Folder(path: 'inputFileSystem/.../MyPkg').manifest -> SwiftFormulaConverter.packageFolder
//   SwiftPackageReaderTool.packageJSON                 -> SwiftFormulaConverter.packageJSON
//   SwiftFormulaConverter.formula                      -> ProjectBuilder.projectFile
//
// `packageFolder` is wired to a Folder.manifest rather than stored as a
// property so the node re-runs whenever files are added to or removed from the
// package root (e.g. a new Sources/NewTarget directory appears). The package
// path is read from FolderManifest.baseFolderPath at process time.

import Foundation

struct SwiftFormulaConverter: NodeFunction {
    static let kind: UInt = 24

    static let packageFolder = "packageFolder"
    static let packageJSON   = "packageJSON"
    static let formulaOutput = "formula"
    static let infoLog       = "infoLog"

    var embeddedNode: Node?

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    let descriptor = NodeFunctionDescriptor(
        staticInputPorts: [packageFolder, packageJSON],
        outputPorts:      [formulaOutput, infoLog])

    // MARK: - Processing

    func process(input: ProcessInput) throws -> ProcessOutput {

        // Decode the FolderManifest from the packageFolder port to get the
        // package root path and react to filesystem changes.
        guard let packageFolderInputValue = input.inputValues[Self.packageFolder]?.values.first else {
            throw NodeError.missingInput(name: Self.packageFolder)
        }

        let manifestJSON = try packageFolderInputValue.expectValue().resolveAsString()

        guard let folderManifest = try? PolyFactory.decode(encodedJSON: manifestJSON) as? FolderManifest else {
            return .init(
                outputValues: [
                    Self.formulaOutput: .noValue(reason: .error(message: "SwiftFormulaConverter: could not decode FolderManifest from packageFolder input")),
                    Self.infoLog:       .value("".intern())],
                inputWireExpectations: [:])
        }

        let packageFolder = folderManifest.baseFolderPath

        guard let jsonEntry = input.inputValues[Self.packageJSON]?.values.first else {
            throw NodeError.missingInput(name: Self.packageJSON)
        }

        let jsonString = try jsonEntry.expectValue().resolveAsString()

        do {
            let manifest = try SPMManifest.decode(jsonString)
            let formula  = generateFormula(manifest: manifest, packageFolder: packageFolder)

            return .init(
                outputValues: [Self.formulaOutput: .value(formula.intern()),
                               Self.infoLog:       .value("".intern())],
                inputWireExpectations: [:])

        } catch {
            return .init(
                outputValues: [
                    Self.formulaOutput: .noValue(reason: .error(message: "SwiftFormulaConverter: \(error)")),
                    Self.infoLog:       .value("JSON parse error: \(error)".intern())],
                inputWireExpectations: [:])
        }
    }

    // MARK: - SPM JSON model

    private struct SPMManifest: Decodable {
        let name: String
        let targets: [SPMTarget]
        let products: [SPMProduct]

        static func decode(_ json: String) throws -> SPMManifest {
            try JSONDecoder().decode(SPMManifest.self, from: Data(json.utf8))
        }
    }

    private struct SPMTarget: Decodable {
        let name: String
        let type: String?
        let path: String?
        let dependencies: [SPMTargetDependency]

        // SPM default: Sources/<TargetName> relative to the package root.
        var sourcesRelativePath: String { path ?? "Sources/\(name)" }
    }

    // Handles the two dependency shapes emitted by different Swift versions:
    //   array form  – {"byName": ["Name", null]}
    //   object form – {"byName": {"name": "Name", "condition": null}}
    // Only in-package target dependencies (byName / target keys) are extracted;
    // external product dependencies are ignored for formula generation.
    private struct SPMTargetDependency: Decodable {
        let targetName: String?

        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String)          { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int)       { nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            var found: String? = nil

            for key in ["byName", "target"] {
                guard found == nil, c.contains(AnyKey(key)) else { continue }
                if let arr = try? c.decode([String?].self, forKey: AnyKey(key)) {
                    found = arr.compactMap { $0 }.first
                } else if let sub = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(key)),
                          let n   = try? sub.decode(String.self, forKey: AnyKey("name")) {
                    found = n
                }
            }
            targetName = found
        }
    }

    private struct SPMProduct: Decodable {
        let name: String
        let targets: [String]
        let productType: ProductType

        enum ProductType { case executable, library, other }

        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String)          { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int)       { nil }
        }

        enum CodingKeys: String, CodingKey { case name, targets, type }

        init(from decoder: Decoder) throws {
            let c   = try decoder.container(keyedBy: CodingKeys.self)
            name    = try c.decode(String.self,   forKey: .name)
            targets = try c.decode([String].self, forKey: .targets)
            let tc  = try c.nestedContainer(keyedBy: AnyKey.self, forKey: .type)
            if      tc.contains(AnyKey("executable")) { productType = .executable }
            else if tc.contains(AnyKey("library"))    { productType = .library }
            else                                       { productType = .other }
        }
    }

    // MARK: - Formula generation

    private func generateFormula(manifest: SPMManifest, packageFolder: String) -> String {
        let targetsByName = Dictionary(uniqueKeysWithValues: manifest.targets.map { ($0.name, $0) })
        var lines: [String] = []

        for product in manifest.products {
            guard product.productType != .other,
                  let primaryTargetName = product.targets.first,
                  let primaryTarget = targetsByName[primaryTargetName] else { continue }

            let isLibrary    = (product.productType == .library)
            let compilerExpr = buildCompilerExpr(for: primaryTarget,
                                                 targetsByName: targetsByName,
                                                 packageFolder: packageFolder,
                                                 visited: [])

            let outputName   = isLibrary ? "lib\(product.name).dylib" : product.name
            let dynLib       = isLibrary ? ", dynamicLibrary: 'true'" : ""
            let linkerConfig = "Configuration(outputName: '\(outputName)'\(dynLib)).output"

            // The wire key for the linker's object input is the filename swiftc
            // receives on the command line; "<module>.o" matches the file
            // SwiftCompilerTool emits in the sandbox.
            let objectWireKey = "\(primaryTarget.name).o"

            let line =
                "product '\(product.name)' = " +
                "SwiftLinkerTool(" +
                "configuration <- ['config': \(linkerConfig)], " +
                "input <- ['\(objectWireKey)': \(compilerExpr).object]" +
                ").output"

            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }

    // Returns a SwiftCompilerTool(...) expression (without a trailing port)
    // so the caller can append .object or .swiftmodule as needed.
    private func buildCompilerExpr(for target: SPMTarget,
                                   targetsByName: [String: SPMTarget],
                                   packageFolder: String,
                                   visited: Set<String>) -> String {
        let sourcesPath = "\(packageFolder)/\(target.sourcesRelativePath)"
        let configExpr  = "Configuration(moduleName: '\(target.name)').output"
        let folderExpr  = "Folder(path: '\(sourcesPath)').manifest"

        // Collect in-package target dependencies, guarding against cycles.
        var moduleWires: [String] = []
        var nextVisited = visited
        nextVisited.insert(target.name)

        for dep in target.dependencies {
            guard let depName   = dep.targetName,
                  let depTarget = targetsByName[depName],
                  !nextVisited.contains(depName) else { continue }
            let depExpr = buildCompilerExpr(for: depTarget,
                                            targetsByName: targetsByName,
                                            packageFolder: packageFolder,
                                            visited: nextVisited)
            // Wire key is the module name; SwiftCompilerTool appends ".swiftmodule"
            // to produce the filename placed in the sandbox.
            moduleWires.append("'\(depName)': \(depExpr).swiftmodule")
        }

        var args = "configuration <- ['config': \(configExpr)], inputFolder <- ['sources': \(folderExpr)]"
        if !moduleWires.isEmpty {
            args += ", inputModules <- [\(moduleWires.joined(separator: ", "))]"
        }
        return "SwiftCompilerTool(\(args))"
    }
}
