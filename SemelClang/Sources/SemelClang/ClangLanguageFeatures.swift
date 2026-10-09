// ClangLanguageFeatures.swift
// SemelClang
//
// Clang modules and automatic reference counting, as settings both clang stages read.

import Foundation
import SemelNodeKit

/// What an Objective-C target built the way SwiftPM builds one asks of each clang stage:
/// `modules` and `objectiveCARC`, and the preprocessor's `moduleName` (B-55, B-77).
///
/// Settings rather than flags in `arguments`, because the flags a source takes depend on its
/// language and the settings are per target: SwiftPM passes `-fobjc-arc` to every file of a
/// C-family target on Darwin, which matters only to Objective-C. The node knows the file's
/// language, as it does for `cStandard` and `cxxStandard`, so it decides; `arguments` could
/// say only one thing for every file. And a key of their own for the reason `defines` has
/// one: the converter lays these over the project's settings as literals, and a literal
/// `arguments` would replace the project's.
///
/// Both stages need both. The preprocessor evaluates `__has_feature(objc_arc)` — FMDB picks
/// `retain`/`release` macros by it — and loads the modules an `@import` names, whose macros
/// the rest of the file sees (`TARGET_OS_MAC` after `@import Foundation;`). Its output keeps
/// each import as `@import` or `#pragma clang module import`, so the compiler loads the
/// modules again, which is why a compiler with `modules` requires `sdkPath`.
///
/// Modules are for Objective-C alone, where SwiftPM enables them for every file but C++.
/// Loading them twice brings their macros back to text the preprocessor already expanded,
/// and a macro that names itself expands a second time: the SDK's `#define ts_64 uts.ts_64`
/// turns PLCrashReporter's `thread.ts_64` into `thread.uts.ts_64` and then, compiled,
/// `thread.uts.uts.ts_64`. Only Objective-C can write `@import`, so only it needs modules
/// to compile at all; C loses nothing it had, and C++ never had them.
/// ISSUE: an Objective-C source using such a macro fails the same way (B-55's residual 11).
struct ClangLanguageFeatures {
    /// `modules=true`: `-fmodules` for Objective-C, with the module cache inside the sandbox.
    let modules: Bool
    /// `objectiveCARC=true`: `-fobjc-arc` for Objective-C and Objective-C++.
    let objectiveCARC: Bool
    /// `moduleName`: the module the source belongs to, `-fmodule-name` with `modules`, so
    /// the target's own headers are included as text rather than imported as the module
    /// they make — which is what SwiftPM passes. Only the preprocessor reads it: what it
    /// hands on is text in which the target's own headers are already expanded.
    let moduleName: String?

    init(properties: [String: String], namespace: String, readsModuleName: Bool) throws {
        modules       = try Self.flag("modules", in: properties, namespace: namespace)
        objectiveCARC = try Self.flag("objectiveCARC", in: properties, namespace: namespace)
        moduleName    = readsModuleName ? properties["moduleName"] : nil
    }

    /// The module cache, a folder of the sandbox: the modules a run builds are derived from
    /// the SDK and the inputs, so they live and die with the run and are never an output. A
    /// shared cache outside the sandbox would be a writable directory every run reads, the
    /// hole the sandbox exists to close (B-49). Relative, like every path on a command line
    /// here; clang does not record it in the object.
    static let moduleCachePath = "\(ToolSandbox.derivedStateFolderName)/clang-module-cache"

    /// The flags for a source in `language`, clang's `-x` spelling.
    func arguments(forLanguage language: String) -> [String] {
        var arguments: [String] = []
        let isObjectiveC = language == "objective-c" || language == "objective-c++"
        if objectiveCARC, isObjectiveC {
            arguments.append("-fobjc-arc")
        }
        if loadsModules(forLanguage: language) {
            arguments.append("-fmodules")
            arguments.append("-fmodules-cache-path=\(Self.moduleCachePath)")
            if let moduleName {
                arguments.append("-fmodule-name=\(moduleName)")
            }
        }
        return arguments
    }

    /// Whether a source in `language` loads modules, and so needs the SDK they come from.
    func loadsModules(forLanguage language: String) -> Bool {
        modules && language == "objective-c"
    }

    /// `true` or `false`, or absent for off. Anything else is a mistake worth naming: a
    /// `yes` read as off would build without ARC and leak without a word.
    private static func flag(_ key: String, in properties: [String: String], namespace: String) throws -> Bool {
        switch properties[key] {
        case nil, "false":
            return false
        case "true":
            return true
        case let value?:
            throw ErrorCondition.settingNotAccepted(key: "\(namespace).\(key)", value: value, accepted: ["true", "false"])
        }
    }
}
