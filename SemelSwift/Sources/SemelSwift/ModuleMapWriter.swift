// ModuleMapWriter.swift
// SemelSwift
//
// The module map SwiftPM writes for a C target whose public headers have none (B-55).

import Foundation
import SemelNodeKit
import SemelDatabaseModels

/// A clang module map for a C-family target, from what the target is rather than from any
/// file: `ModuleMapWriter(moduleName: 'CrashReporter', umbrellaHeader: 'CrashReporter.h')`.
///
/// SwiftPM makes a C target importable from Swift whether or not its public-headers folder
/// holds a `module.modulemap`: when it holds none, SwiftPM writes one — an umbrella header
/// named for the module, or the folder itself as an umbrella directory. PLCrashReporter's
/// `import CrashReporter`, Zip's `import Minizip` and NetNewsWire's `import RSDatabaseObjC`
/// all rest on it. Which of the two a target gets is decided by the converter from the
/// folder's listing, the way SwiftPM decides (`PackageClangTarget.ModuleMap`); this node
/// only writes it, so its value is its properties and it depends on nothing.
///
/// The map is written to sit in the public-headers folder, beside the headers, so every path
/// in it is relative to that folder — what makes one map right wherever the folder is
/// placed, and keeps the sandbox's own directory out of it.
///
/// Like `SettingsLiteral`, a source: no input ports, published when created and never
/// again, since the properties are its identity.
struct ModuleMapWriter: Node {
    public static let kind: UInt = 39

    static let outputPort = "output"

    /// The module the map declares, as Swift imports it: the target's c99 name.
    static let moduleNameProperty = "moduleName"
    /// The umbrella header, relative to the public-headers folder: `CrashReporter.h`, or
    /// `Kit/Kit.h` when it sits in a folder of the module's name.
    static let umbrellaHeaderProperty = "umbrellaHeader"
    /// The umbrella directory, relative to the public-headers folder: `.`, the folder.
    static let umbrellaDirectoryProperty = "umbrellaDirectory"

    public static let descriptor = NodeDescriptor(inputPorts: [], outputPorts: [outputPort])

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public func didCreate() throws -> ProcessOutput? {
        ProcessOutput(outputValues: [Self.outputPort: .value(try Self.moduleMap(properties: thisNode.properties).intern())],
                      inputWireSpecs: [:])
    }

    /// Never reached in a working graph: a node declaring no input ports is not scheduled.
    public func process(input: ProcessInput) throws -> ProcessOutput {
        throw NodeError.sourceCannotProcess(type: "\(Self.self)")
    }

    /// The map's text: SwiftPM's, with the paths relative to the folder the map sits in.
    /// Exactly one umbrella is named; a writer given both or neither says which it got.
    static func moduleMap(properties: [String: String]) throws -> String {
        guard let moduleName = properties[moduleNameProperty], !moduleName.isEmpty else {
            throw ErrorCondition.propertyMissing(type: "ModuleMapWriter", property: moduleNameProperty, alternatives: [])
        }
        let umbrella: String
        switch (properties[umbrellaHeaderProperty], properties[umbrellaDirectoryProperty]) {
        case (let header?, nil):
            umbrella = "umbrella header \"\(escaped(header))\""
        case (nil, let directory?):
            umbrella = "umbrella \"\(escaped(directory))\""
        default:
            throw ErrorCondition.propertiesExclusive(type: "ModuleMapWriter",
                                                     properties: [umbrellaHeaderProperty, umbrellaDirectoryProperty])
        }
        return "module \(moduleName) {\n    \(umbrella)\n    export *\n}\n"
    }

    /// A module map's string literal escapes a quote and a backslash, as C's does.
    private static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
