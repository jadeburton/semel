//
//  InfoPlistBuilder.swift
//  SemelApple
//
//  A bundle's Info.plist is assembled, not written: a base file from the project, the
//  partial plists the resource compilers emit (actool's icon keys), and the keys a build
//  setting supplies (`INFOPLIST_KEY_*`, the bundle identifier), with `$(VAR)` references
//  resolved. No tool runs; this is a merge.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

public struct InfoPlistBuilder: Node {
    public static let kind: UInt = 31

    // MARK: Ports

    /// The project's own Info.plist, at most one wire; absent for a bundle built from
    /// keys alone.
    static let base = "base"
    /// Partial plists to merge over the base, in wire-key order — actool's, and any
    /// other compiler's.
    static let partials = "partials"
    static let output = "plist"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.optional(base), .optional(partials)],
        outputPorts: [output]
    )

    // MARK: Processing

    /// Every property of the node is a plist entry, and every property is a variable a
    /// `$(NAME)` reference can name. Both are the same thing in Xcode — `PRODUCT_NAME` is
    /// a build setting and `$(PRODUCT_NAME)` its reference — so the formula writes them
    /// once: `InfoPlistBuilder(CFBundleName: '$(PRODUCT_NAME)', PRODUCT_NAME: 'Hello')`.
    /// Precedence: base, then partials, then properties.
    public func process(input: ProcessInput) throws -> ProcessOutput {
        var merged: [String: Any] = [:]

        if let baseWire = input.inputValues[Self.base]?.first {
            merged = try Self.dictionary(fromPlist: baseWire.value, named: baseWire.key)
        }
        for (key, value) in (input.inputValues[Self.partials] ?? [:]).sorted(by: { $0.key < $1.key }) {
            merged.merge(try Self.dictionary(fromPlist: value, named: key)) { _, partial in partial }
        }
        for (key, value) in thisNode.properties {
            merged[key] = value
        }

        var unresolved = Set<String>()
        let resolved = Self.substitute(merged, variables: thisNode.properties, unresolved: &unresolved)
        guard unresolved.isEmpty else {
            let message = "Info.plist references undefined variables: " + unresolved.sorted().joined(separator: ", ")
            return .init(outputValues: [Self.output: .noValue(reason: .error(messageDataObjectHash: try message.intern()))],
                         inputWireSpecs: [:])
        }

        let data = try PropertyListSerialization.data(fromPropertyList: resolved, format: .xml, options: 0)
        return .init(outputValues: [Self.output: .value(try [UInt8](data).intern())], inputWireSpecs: [:])
    }

    private static func dictionary(fromPlist value: NodeValue, named name: String) throws -> [String: Any] {
        let hash = try value.expectValue()
        guard let bytes = try DataObjectStore.shared.read(hash: hash) else {
            throw NodeError.other(message: "Info.plist input '\(name)' has no content")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any] else {
            throw NodeError.other(message: "Info.plist input '\(name)' is not a property list dictionary")
        }
        return plist
    }

    /// `$(NAME)` and `${NAME}` in every string value, at any depth; a name with no
    /// variable is collected rather than left in place, since `$(PRODUCT_BUNDLE_IDENTIFIER)`
    /// as a bundle identifier is a bundle that will not install.
    static func substitute(_ value: Any, variables: [String: String], unresolved: inout Set<String>) -> Any {
        switch value {
        case let string as String:
            return substitute(string, variables: variables, unresolved: &unresolved)
        case let array as [Any]:
            return array.map { substitute($0, variables: variables, unresolved: &unresolved) }
        case let dictionary as [String: Any]:
            return dictionary.mapValues { substitute($0, variables: variables, unresolved: &unresolved) }
        default:
            return value
        }
    }

    private static let reference = try? NSRegularExpression(pattern: #"\$[({]([A-Za-z_][A-Za-z0-9_]*)[)}]"#)

    private static func substitute(_ string: String, variables: [String: String], unresolved: inout Set<String>) -> String {
        guard let reference, string.contains("$") else {
            return string
        }
        var result = string
        for match in reference.matches(in: string, range: NSRange(string.startIndex..., in: string)).reversed() {
            guard let whole = Range(match.range, in: string), let nameRange = Range(match.range(at: 1), in: string) else {
                continue
            }
            let name = String(string[nameRange])
            guard let replacement = variables[name] else {
                unresolved.insert(name)
                continue
            }
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }
}
