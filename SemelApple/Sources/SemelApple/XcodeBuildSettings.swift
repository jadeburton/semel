//
//  XcodeBuildSettings.swift
//  SemelApple
//
//  A target's build settings, evaluated the way Xcode evaluates them: four levels —
//  project xcconfig, project configuration, target xcconfig, target configuration — each
//  a run of assignments over the one below, an xcconfig with its includes spliced in
//  where they are named (`XcconfigExpansion`), `$(inherited)` reaching back to the
//  assignments before, a conditional setting (`KEY[sdk=macosx*]`, `KEY[config=Debug]`)
//  applying when its conditions hold, and `$(VAR)` references resolved against the
//  result. Defaults are the few a bundle cannot do without; Xcode's hundreds of others are
//  not needed to build one.

import Foundation

struct XcodeBuildSettings {

    /// The settings after evaluation, by key.
    let values: [String: String]

    subscript(key: String) -> String? {
        values[key]
    }

    /// Evaluates the settings of `target` in `configuration` for the SDK named `sdk`
    /// (`iphonesimulator`), with `xcconfig` giving, for each xcconfig path a configuration
    /// is based on (relative to the project's folder), its assignments with its includes
    /// spliced in — nil or empty for a file that is not there, which is then an empty
    /// level — and `extra` as the values the converter itself knows (`TARGET_NAME`).
    static func resolve(project: XcodeProject,
                        target: XcodeProject.Target,
                        configuration name: String,
                        sdk: String,
                        xcconfig: (String) -> [XcodeSettingAssignment]?,
                        extra: [String: String]) throws -> XcodeBuildSettings {
        guard let projectConfiguration = project.configuration(named: name) else {
            throw XcodeProjectError.noSuchConfiguration(name, available: project.configurations.map(\.name))
        }
        guard let targetConfiguration = target.configuration(named: name) else {
            throw XcodeProjectError.noSuchConfiguration(name, available: target.configurations.map(\.name))
        }

        // Xcode's levels, lowest first. Each xcconfig is read in its own order; a
        // configuration's settings are a dictionary, read in key order.
        var assignments = Self.assignments(from: defaults)
        assignments += projectConfiguration.xcconfigPath.flatMap(xcconfig) ?? []
        assignments += Self.assignments(from: projectConfiguration.settings)
        assignments += targetConfiguration.xcconfigPath.flatMap(xcconfig) ?? []
        assignments += Self.assignments(from: targetConfiguration.settings)
        assignments += Self.assignments(from: extra)

        let context = XcodeSettingContext(sdk: sdk, configuration: name)
        return XcodeBuildSettings(values: resolveReferences(in: evaluate(assignments, in: context)))
    }

    /// A level held as a dictionary, as assignments in key order. Sorted, so the result
    /// does not depend on `Dictionary`'s iteration order, and the order is also the one
    /// that gives Xcode's answer: `KEY` sorts before `KEY[sdk=…]`, so a matching condition
    /// overrides the plain key of its level; and of two conditions that both match —
    /// `KEY[sdk=iphone*]` and `KEY[sdk=iphonesimulator*]` for an `iphonesimulator` build —
    /// the broader ends `*]`, and `*` sorts below every character an SDK name continues
    /// with, so the more specific one comes later and has the last word.
    static func assignments(from level: [String: String]) -> [XcodeSettingAssignment] {
        level.sorted { $0.key < $1.key }.compactMap { XcodeSettingAssignment(key: $0.key, value: $0.value) }
    }

    /// Every setting's value after the assignments, lowest level first, each overriding
    /// what came before it when its conditions hold. That one pass is Xcode's model whole:
    /// a level is only a run of assignments, so `$(inherited)` means the value the
    /// assignments before this one gave — in a lower level, earlier in the same file, or
    /// in a file it includes, which is how NetNewsWire's debug file extends its project
    /// file's `GCC_PREPROCESSOR_DEFINITIONS` with `DEBUG=1 … $(inherited)`. A setting
    /// nothing assigned before inherits nothing. Other references wait for the whole
    /// table (`resolveReferences`): they name the final value, not the one below.
    static func evaluate(_ assignments: [XcodeSettingAssignment], in context: XcodeSettingContext) -> [String: String] {
        var values: [String: String] = [:]
        for assignment in assignments where assignment.applies(in: context) {
            let inherited = values[assignment.name] ?? ""
            values[assignment.name] = assignment.value
                .replacingOccurrences(of: "$(inherited)", with: inherited)
                .replacingOccurrences(of: "${inherited}", with: inherited)
                .trimmingCharacters(in: .whitespaces)
        }
        return values
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
