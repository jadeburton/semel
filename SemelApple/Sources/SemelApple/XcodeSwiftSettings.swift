//
//  XcodeSwiftSettings.swift
//  SemelApple
//
//  What a target's evaluated build settings tell its Swift compiler, the way Xcode tells
//  it: the compilation conditions, the upcoming and experimental features the language
//  settings turn on, the concurrency, isolation and memory-safety checking they choose,
//  warnings as errors, and `OTHER_SWIFT_FLAGS` as they stand. Typed, for the emitter to
//  hand `SwiftCompiler` as the literals a package's `swiftSettings` become (B-77, as
//  PR #137 gave packages): `defines`, `upcomingFeatures`, `experimentalFeatures`, and the
//  flags as `unsafeFlags`, passed as they stand.
//
//  The table is Xcode 26.6's (`Swift.xcspec`): each setting, the command-line arguments
//  each of its values gives, and whether it holds only below Swift 6, where the feature
//  is the language mode's own.

import Foundation

struct XcodeSwiftSettings: Equatable {
    /// `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, each a `-D`.
    var defines: [String] = []
    /// Each an `-enable-upcoming-feature`; `Name:migrate` for a setting set to `MIGRATE`.
    var upcomingFeatures: [String] = []
    /// Each an `-enable-experimental-feature`.
    var experimentalFeatures: [String] = []
    /// Everything else, in Xcode's order: `OTHER_SWIFT_FLAGS` first, then the flags the
    /// language settings give (`-strict-concurrency=targeted`, `-enable-bare-slash-regex`,
    /// `-default-isolation=MainActor`, `-strict-memory-safety`), then the warnings policy
    /// (`-warnings-as-errors`, `-suppress-warnings`).
    var flags: [String] = []

    /// One boolean or three-way language setting: the feature it enables, and whether it
    /// holds only below Swift 6 (Xcode's `Condition` on `EFFECTIVE_SWIFT_VERSION`).
    struct Feature {
        let setting: String
        let name: String
        let onlyBeforeSwift6: Bool
        let experimental: Bool

        init(_ setting: String, _ name: String, onlyBeforeSwift6: Bool = true, experimental: Bool = false) {
            self.setting = setting
            self.name = name
            self.onlyBeforeSwift6 = onlyBeforeSwift6
            self.experimental = experimental
        }
    }

    /// Xcode 26.6's feature settings in the order its specification lists them, which is
    /// the order it passes them in.
    static let features: [Feature] = [
        Feature("SWIFT_UPCOMING_FEATURE_CONCISE_MAGIC_FILE", "ConciseMagicFile"),
        Feature("SWIFT_UPCOMING_FEATURE_FORWARD_TRAILING_CLOSURES", "ForwardTrailingClosures"),
        Feature("SWIFT_UPCOMING_FEATURE_DEPRECATE_APPLICATION_MAIN", "DeprecateApplicationMain"),
        Feature("SWIFT_UPCOMING_FEATURE_IMPORT_OBJC_FORWARD_DECLS", "ImportObjcForwardDeclarations"),
        Feature("SWIFT_UPCOMING_FEATURE_DISABLE_OUTWARD_ACTOR_ISOLATION", "DisableOutwardActorInference"),
        Feature("SWIFT_UPCOMING_FEATURE_ISOLATED_DEFAULT_VALUES", "IsolatedDefaultValues"),
        Feature("SWIFT_UPCOMING_FEATURE_GLOBAL_CONCURRENCY", "GlobalConcurrency"),
        Feature("SWIFT_UPCOMING_FEATURE_INFER_SENDABLE_FROM_CAPTURES", "InferSendableFromCaptures"),
        Feature("SWIFT_UPCOMING_FEATURE_IMPLICIT_OPEN_EXISTENTIALS", "ImplicitOpenExistentials"),
        Feature("SWIFT_UPCOMING_FEATURE_REGION_BASED_ISOLATION", "RegionBasedIsolation"),
        Feature("SWIFT_UPCOMING_FEATURE_DYNAMIC_ACTOR_ISOLATION", "DynamicActorIsolation"),
        Feature("SWIFT_UPCOMING_FEATURE_NONFROZEN_ENUM_EXHAUSTIVITY", "NonfrozenEnumExhaustivity"),
        Feature("SWIFT_UPCOMING_FEATURE_GLOBAL_ACTOR_ISOLATED_TYPES_USABILITY", "GlobalActorIsolatedTypesUsability"),
        Feature("SWIFT_UPCOMING_FEATURE_INTERNAL_IMPORTS_BY_DEFAULT", "InternalImportsByDefault", onlyBeforeSwift6: false),
        Feature("SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY", "MemberImportVisibility", onlyBeforeSwift6: false),
        Feature("SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY", "ExistentialAny", onlyBeforeSwift6: false),
        Feature("SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES", "InferIsolatedConformances", onlyBeforeSwift6: false),
        Feature("SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT", "NonisolatedNonsendingByDefault", onlyBeforeSwift6: false),
        Feature("SWIFT_EXPERIMENTAL_FEATURE_DEBUG_DESCRIPTION_MACRO", "DebugDescriptionMacro", onlyBeforeSwift6: false, experimental: true),
    ]

    init(defines: [String] = [], upcomingFeatures: [String] = [], experimentalFeatures: [String] = [], flags: [String] = []) {
        self.defines = defines
        self.upcomingFeatures = upcomingFeatures
        self.experimentalFeatures = experimentalFeatures
        self.flags = flags
    }

    /// What `settings` tell the compiler of a target compiled in `languageMode` (the major
    /// mode, `5` or `6`; nil is the compiler's own, Swift 5).
    init(settings: XcodeBuildSettings, languageMode: String?) {
        let beforeSwift6 = (languageMode.flatMap { Int($0) } ?? 5) < 6
        defines = settings.list("SWIFT_ACTIVE_COMPILATION_CONDITIONS")

        for feature in Self.features where beforeSwift6 || !feature.onlyBeforeSwift6 {
            let name: String
            switch settings[feature.setting] {
            case "YES":     name = feature.name
            case "MIGRATE": name = "\(feature.name):migrate"
            default:        continue
            }
            if feature.experimental {
                experimentalFeatures.append(name)
            } else {
                upcomingFeatures.append(name)
            }
        }

        flags = settings.list("OTHER_SWIFT_FLAGS")
        if beforeSwift6 {
            // Minimal is no flag; complete, and any value Xcode does not name, is the
            // Swift 6 feature itself.
            switch settings["SWIFT_STRICT_CONCURRENCY"] ?? "minimal" {
            case "minimal":  break
            case "targeted": flags.append("-strict-concurrency=targeted")
            default:         upcomingFeatures.append("StrictConcurrency")
            }
            if settings["SWIFT_ENABLE_BARE_SLASH_REGEX"] == "YES" {
                flags.append("-enable-bare-slash-regex")
            }
        }
        if settings["SWIFT_DEFAULT_ACTOR_ISOLATION"] == "MainActor" {
            flags.append("-default-isolation=MainActor")
        }
        switch settings["SWIFT_STRICT_MEMORY_SAFETY"] {
        case "YES":     flags.append("-strict-memory-safety")
        case "MIGRATE": flags.append("-strict-memory-safety:migrate")
        default:        break
        }
        if settings["SWIFT_TREAT_WARNINGS_AS_ERRORS"] == "YES" {
            flags.append("-warnings-as-errors")
        }
        if settings["SWIFT_SUPPRESS_WARNINGS"] == "YES" {
            flags.append("-suppress-warnings")
        }
    }

    /// The literals `SwiftCompiler` reads them from, as the Swift converter writes a
    /// package target's: lists comma-joined, and the flags a JSON list of strings, since a
    /// flag is free text and may hold a comma. An apostrophe is written `'`, which JSON
    /// allows and the formula's lexer never takes for a quote.
    func literals() throws -> [String: String] {
        var literals: [String: String] = [:]
        if !defines.isEmpty {
            literals["defines"] = defines.joined(separator: ",")
        }
        if !upcomingFeatures.isEmpty {
            literals["upcomingFeatures"] = upcomingFeatures.joined(separator: ",")
        }
        if !experimentalFeatures.isEmpty {
            literals["experimentalFeatures"] = experimentalFeatures.joined(separator: ",")
        }
        if !flags.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            literals["unsafeFlags"] = String(decoding: try encoder.encode(flags), as: UTF8.self)
                .replacingOccurrences(of: "'", with: "\\u0027")
        }
        return literals
    }
}
