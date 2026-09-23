//
//  XcodeBuildSettings.swift
//  SemelApple
//
//  A target's build settings, evaluated the way Xcode evaluates them: four layers —
//  project xcconfig, project configuration, target xcconfig, target configuration — each
//  overriding the one below, `$(inherited)` reaching down a layer, a conditional setting
//  (`KEY[sdk=iphonesimulator*]`) applying when its condition matches the platform, and
//  `$(VAR)` references resolved against the result. Defaults are the few a bundle cannot
//  do without; Xcode's hundreds of others are not needed to build one.

import Foundation

struct XcodeBuildSettings {

    /// The settings after evaluation, by key.
    let values: [String: String]

    subscript(key: String) -> String? {
        values[key]
    }

    /// `KEY = value` lines of an `.xcconfig`; `//` comments and `#include` lines are
    /// dropped — an included xcconfig is a rarity these projects do not use, and reading
    /// one would mean another file to wire.
    static func parseXcconfig(_ text: String) -> [String: String] {
        var settings: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.components(separatedBy: "//").first ?? ""
            guard let equals = line.firstIndex(of: "="), !line.hasPrefix("#") else {
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                continue
            }
            settings[key] = value
        }
        return settings
    }

    /// Evaluates the settings of `target` in `configuration` for the SDK named `sdk`
    /// (`iphonesimulator`), with `xcconfig` mapping each xcconfig path the project names
    /// to its contents — an absent file is an empty layer — and `extra` as the values the
    /// converter itself knows (`TARGET_NAME`).
    static func resolve(project: XcodeProject,
                        target: XcodeProject.Target,
                        configuration name: String,
                        sdk: String,
                        xcconfig: (String) -> String?,
                        extra: [String: String]) throws -> XcodeBuildSettings {
        guard let projectConfiguration = project.configuration(named: name) else {
            throw XcodeProjectError.noSuchConfiguration(name, available: project.configurations.map(\.name))
        }
        guard let targetConfiguration = target.configuration(named: name) else {
            throw XcodeProjectError.noSuchConfiguration(name, available: target.configurations.map(\.name))
        }

        let layers: [[String: String]] = [
            defaults,
            projectConfiguration.xcconfigPath.flatMap(xcconfig).map(parseXcconfig) ?? [:],
            projectConfiguration.settings,
            targetConfiguration.xcconfigPath.flatMap(xcconfig).map(parseXcconfig) ?? [:],
            targetConfiguration.settings,
            extra,
        ]

        // Layer by layer, so `$(inherited)` in one sees the value the layers below gave.
        var resolved: [String: String] = [:]
        for layer in layers {
            for (rawKey, value) in applyingConditions(layer, sdk: sdk).sorted(by: { $0.key < $1.key }) {
                let inherited = resolved[rawKey] ?? ""
                resolved[rawKey] = value.replacingOccurrences(of: "$(inherited)", with: inherited)
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        return XcodeBuildSettings(values: resolveReferences(in: resolved))
    }

    /// References, resolved so that `$(NAME)` never expands before `NAME` itself has:
    /// a value may name a setting that names another, so `PRODUCT_MODULE_NAME` (naming
    /// `PRODUCT_NAME`, naming `TARGET_NAME`) must not see `PRODUCT_NAME` half-expanded.
    /// The order the table is walked in must not matter: a key visited before its
    /// reference resolves would apply its operator (`:c99extidentifier`) to the literal
    /// reference text instead of the value it names, and the wrong answer would have no
    /// `$` left to retry. So each key is resolved by first resolving what it names,
    /// which bottoms out at the same base values whatever the visiting order.
    static func resolveReferences(in values: [String: String]) -> [String: String] {
        var resolved: [String: String] = [:]
        var resolving: Set<String> = []

        func value(for key: String, raw: String) -> String {
            if let already = resolved[key] {
                return already
            }
            guard resolving.insert(key).inserted else {
                // A cyclic reference. The key already being resolved returns its raw text,
                // so the cycle's members keep a `$(…)` reference between them, unresolved,
                // instead of expanding forever.
                return raw
            }
            let result = substitute(raw) { name in values[name].map { value(for: name, raw: $0) } }
            resolving.remove(key)
            resolved[key] = result
            return result
        }

        // Sorted so the result does not depend on `Dictionary`'s iteration order.
        for (key, raw) in values.sorted(by: { $0.key < $1.key }) {
            resolved[key] = value(for: key, raw: raw)
        }
        return resolved
    }

    /// The layer with conditional keys folded in: `KEY[sdk=iphonesimulator*]` replaces
    /// `KEY` when the SDK matches, and is dropped otherwise. Only the SDK condition is
    /// honoured; arch and config conditions are rare in a project file, and a wrong
    /// guess there is quieter than a wrong SDK.
    private static func applyingConditions(_ layer: [String: String], sdk: String) -> [String: String] {
        var result: [String: String] = [:]
        var conditional: [String: String] = [:]
        // Sorted: two conditions on one key can both match — `KEY[sdk=iphone*]` and
        // `KEY[sdk=iphonesimulator*]` for an `iphonesimulator` build — and the last one
        // written wins. A Dictionary's iteration order is seeded per process, so an
        // unsorted walk would give the key a different value from one run to the next,
        // and that value reaches the command line the formula states (B-04).
        for (key, value) in layer.sorted(by: { $0.key < $1.key }) {
            guard let bracket = key.firstIndex(of: "[") else {
                result[key] = value
                continue
            }
            let base = String(key[..<bracket])
            let condition = key[key.index(after: bracket)...].dropLast()
            guard condition.hasPrefix("sdk=") else {
                continue
            }
            let pattern = condition.dropFirst("sdk=".count)
            let matches = pattern.hasSuffix("*") ? sdk.hasPrefix(pattern.dropLast()) : sdk == pattern
            if matches {
                conditional[base] = value
            }
        }
        return result.merging(conditional) { _, matched in matched }
    }

    /// `$(NAME)` and `${NAME}`, each replaced by `lookup(NAME)`, with the two operators a
    /// bundle's identity goes through — `$(PRODUCT_NAME:c99extidentifier)` for a module
    /// name, `:rfc1034identifier` for a bundle identifier — applied to what `lookup`
    /// returns. A nil lookup leaves the reference as it is, for `InfoPlistBuilder` to
    /// report if it reaches a plist.
    private static func substitute(_ value: String, lookup: (String) -> String?) -> String {
        guard let reference = reference else {
            return value
        }
        var result = value
        for match in reference.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let whole = Range(match.range, in: value), let nameRange = Range(match.range(at: 1), in: value),
                  var replacement = lookup(String(value[nameRange])) else {
                continue
            }
            if let operatorRange = Range(match.range(at: 2), in: value) {
                replacement = apply(operator: String(value[operatorRange]), to: replacement)
            }
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }

    private static let reference = try? NSRegularExpression(pattern: #"\$[({]([A-Za-z_][A-Za-z0-9_]*)(?::([a-z0-9]+))?[)}]"#)

    /// The names the resolved values still reference, sorted: every one a setting nobody
    /// defined, which is what a missing xcconfig looks like from here. Names Xcode
    /// provides from the build itself are left out; no xcconfig would define them.
    var unresolvedReferences: [String] {
        Self.unresolvedReferences(in: values)
    }

    static func unresolvedReferences(in values: [String: String]) -> [String] {
        guard let reference = reference else {
            return []
        }
        var names = Set<String>()
        for value in values.values where value.contains("$") {
            for match in reference.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                if let nameRange = Range(match.range(at: 1), in: value) {
                    names.insert(String(value[nameRange]))
                }
            }
        }
        return names.subtracting(providedByXcode).sorted()
    }

    /// Settings Xcode derives from the build rather than reads from a file: the project's
    /// location, the SDK, the configuration. A reference to one is not a missing value.
    static let providedByXcode: Set<String> = [
        "SRCROOT", "PROJECT_DIR", "PROJECT_NAME", "PROJECT_FILE_PATH", "SDKROOT", "PLATFORM_NAME",
        "EFFECTIVE_PLATFORM_NAME", "CONFIGURATION", "DEVELOPER_DIR", "BUILT_PRODUCTS_DIR",
        "TARGET_BUILD_DIR", "ARCHS", "HOME", "USER", "inherited",
    ]

    private static func apply(operator name: String, to value: String) -> String {
        switch name {
        case "c99extidentifier":
            let cleaned = String(value.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : Character("_") })
            return cleaned.first?.isNumber == true ? "_" + cleaned : cleaned
        case "rfc1034identifier":
            return String(value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : Character("-") })
        default:
            return value
        }
    }

    /// What a target has when its project says nothing: the values a bundle cannot do
    /// without, and no more.
    private static let defaults: [String: String] = [
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "PRODUCT_MODULE_NAME": "$(PRODUCT_NAME:c99extidentifier)",
        "SWIFT_VERSION": "5",
        "MARKETING_VERSION": "1.0",
        "CURRENT_PROJECT_VERSION": "1",
        "TARGETED_DEVICE_FAMILY": "1,2",
    ]
}
