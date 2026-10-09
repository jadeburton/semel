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

    /// 2: the engine's `projectRoot` stamp is no longer an entry of the plist.
    /// 3: the `pkgInfo` port (B-77).
    /// 4: several wires on `base` are an error naming them, where one was taken (B-141).
    /// 5: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    public static let implementationVersion = 5

    // MARK: Ports

    /// The project's own Info.plist, at most one wire; absent for a bundle built from
    /// keys alone.
    static let base = "base"
    /// Partial plists to merge over the base, in wire-key order — actool's, and any
    /// other compiler's.
    static let partials = "partials"
    static let output = "plist"
    /// The bundle's `PkgInfo`, from the plist as built: its `CFBundlePackageType` and its
    /// `CFBundleSignature`, four bytes each, `????` for one that is not there or not four
    /// ASCII characters — `APPL????` for an application with no creator code, which is
    /// what Xcode 26.6 wrote for NetNewsWire's and for a probe's. Xcode writes one for an
    /// application (`GENERATE_PKGINFO_FILE`); a formula takes this port where it wants one.
    static let pkgInfo = "pkgInfo"
    /// A JSON dictionary of entries, for keys no formula identifier can spell and values
    /// no string can carry.
    static let keysProperty = "keys"
    /// A JSON dictionary of build settings, name to value: variables a `$(NAME)` may
    /// name, and never entries. A converter hands over a target's whole evaluated settings
    /// this way, since a project's Info.plist may name any of them — NetNewsWire's name
    /// `$(ORGANIZATION_IDENTIFIER)` and `$(APP_GROUP_ID)` — and a property would put each
    /// one in the plist as a key of its own.
    static let buildSettingsProperty = "buildSettings"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.optional(base), .optional(partials, .many)],
        outputPorts: [output, pkgInfo]
    )

    // MARK: Processing

    /// Every property of the node is a plist entry, and every property is a variable a
    /// `$(NAME)` reference can name. Both are the same thing in Xcode — `PRODUCT_NAME` is
    /// a build setting and `$(PRODUCT_NAME)` its reference — so the formula writes them
    /// once: `InfoPlistBuilder(CFBundleName: '$(PRODUCT_NAME)', PRODUCT_NAME: 'Hello')`.
    /// Precedence: base, then partials, then properties. The `buildSettings` dictionary
    /// is variables only, beneath the properties.
    public func process(input: ProcessInput) throws -> ProcessOutput {
        var merged: [String: Any] = [:]

        if let baseWire = try input.onlyWire(onOptionalPort: Self.base) {
            merged = try Self.dictionary(fromPlist: baseWire.value, on: Self.base, named: baseWire.key)
        }
        for (key, value) in (input.inputValues[Self.partials] ?? [:]).sorted(by: { $0.key < $1.key }) {
            merged.merge(try Self.dictionary(fromPlist: value, on: Self.partials, named: key)) { _, partial in partial }
        }
        // `keys` is a JSON dictionary of entries, typed as JSON types them — the form a
        // converter writes, since a plist key like `UISupportedInterfaceOrientations~ipad`
        // is no formula identifier. Every other property is one string entry.
        if let keysJSON = thisNode.properties[Self.keysProperty] {
            guard let keys = try? JSONSerialization.jsonObject(with: Data(keysJSON.utf8)) as? [String: Any] else {
                throw ErrorCondition.propertyNotOfForm(type: "InfoPlistBuilder", property: Self.keysProperty, form: .jsonDictionary)
            }
            merged.merge(keys) { _, key in key }
        }
        var variables: [String: String] = [:]
        if let settingsJSON = thisNode.properties[Self.buildSettingsProperty] {
            guard let settings = try? JSONSerialization.jsonObject(with: Data(settingsJSON.utf8)) as? [String: String] else {
                throw ErrorCondition.propertyNotOfForm(type: "InfoPlistBuilder", property: Self.buildSettingsProperty,
                                                       form: .jsonStringDictionary)
            }
            variables = settings
        }
        // What the engine stamps on a node for its cache (`projectRoot`) is not an entry:
        // it would put the build's root in every plist, and one the cache hands another
        // project would carry the first project's.
        for (key, value) in thisNode.properties
        where key != Self.keysProperty && key != Self.buildSettingsProperty && !Self.cacheKeyExcludedProperties.contains(key) {
            merged[key] = Self.typed(value)
            variables[key] = value
        }

        var unresolved = Set<String>()
        let resolved = Self.substitute(merged, variables: variables, unresolved: &unresolved)
        guard unresolved.isEmpty else {
            let error = try ErrorDocument.engine(.undefinedPlistVariables(names: unresolved.sorted()), subject: nil).published()
            return .init(outputValues: [Self.output: error, Self.pkgInfo: error], inputWireSpecs: [:])
        }

        let data = try PropertyListSerialization.data(fromPropertyList: resolved, format: .xml, options: 0)
        let plist = resolved as? [String: Any] ?? [:]
        return .init(outputValues: [Self.output:  .value(try [UInt8](data).intern()),
                                    Self.pkgInfo: .value(try Array(Self.pkgInfo(of: plist).utf8).intern())],
                     inputWireSpecs: [:])
    }

    /// `APPL????`: the package type and the creator code, each a four-character code, or
    /// `????` in its place.
    static func pkgInfo(of plist: [String: Any]) -> String {
        func code(_ key: String) -> String {
            guard let value = plist[key] as? String, value.utf8.count == 4, value.allSatisfy(\.isASCII) else {
                return "????"
            }
            return value
        }
        return code("CFBundlePackageType") + code("CFBundleSignature")
    }

    /// A property is a string, and a plist has arrays, dictionaries and booleans. A value
    /// written as JSON — `["iPhoneSimulator"]`, `{}` — is read back as what it says, and
    /// `true`/`false` as booleans; a number stays the string it is, since `CFBundleVersion`
    /// is `"1"`, never `1`.
    static func typed(_ value: String) -> Any {
        switch value {
        case "true":  return true
        case "false": return false
        default:
            guard value.hasPrefix("[") || value.hasPrefix("{"),
                  let object = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]) else {
                return value
            }
            return object
        }
    }

    private static func dictionary(fromPlist value: NodeValue, on port: String, named name: String) throws -> [String: Any] {
        let hash = try value.expectValue()
        guard let bytes = try DataObjectStore.shared.read(hash: hash) else {
            throw ErrorCondition.inputHasNoContent(port: port, wire: name)
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any] else {
            throw ErrorCondition.inputNotOfForm(port: port, wire: name, form: .propertyListDictionary)
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
