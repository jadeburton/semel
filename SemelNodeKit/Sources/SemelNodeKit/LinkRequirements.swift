//
//  LinkRequirements.swift
//  SemelNodeKit
//
//  What a product's objects need from the linker beyond the objects themselves (B-55):
//  the frameworks and libraries their targets' `linkerSettings` name, and whether any of
//  them was compiled from C++. Here rather than in either toolchain because both linkers
//  read it — `SwiftLinker` from a package's formula, `ClangLinker` from a hand-written
//  one — and the package converter writes it.
//

/// Frameworks, libraries and the C++ runtime a link needs, as settings: `frameworks` and
/// `libraries` comma-joined like every list in a setting, `cxxRuntime` as `true`.
///
/// Keys of their own rather than flags in `arguments`, for the reason the preprocessor's
/// `defines` is one: a formula's literal replaces the key it names in the settings under
/// it, so requirements carried as `arguments` would drop a project's own
/// `swift.linker.arguments` for every product that has any.
public struct LinkRequirements: Equatable {
    /// `-framework <name>` each, sorted and each once: a product's list is the union of
    /// its targets', and the union has to come out the same whichever target is met first.
    public let frameworks: [String]
    /// `-l<name>` each, sorted and each once, for the same reason.
    public let libraries: [String]
    /// Some object was compiled from C++ or Objective-C++, so the link needs the C++
    /// standard library: `___gxx_personality_v0`, `___cxa_guard_acquire` and the rest.
    /// Said rather than read off the objects' names, which a tree of objects from
    /// another formula does not promise to keep.
    public let cxxRuntime: Bool

    public static let frameworksKey = "frameworks"
    public static let librariesKey  = "libraries"
    public static let cxxRuntimeKey = "cxxRuntime"

    public init<Frameworks: Sequence, Libraries: Sequence>(frameworks: Frameworks, libraries: Libraries, cxxRuntime: Bool)
    where Frameworks.Element == String, Libraries.Element == String {
        self.frameworks = Set(frameworks).filter { !$0.isEmpty }.sorted()
        self.libraries  = Set(libraries).filter { !$0.isEmpty }.sorted()
        self.cxxRuntime = cxxRuntime
    }

    /// None of anything.
    public static let none = LinkRequirements(frameworks: [String](), libraries: [String](), cxxRuntime: false)

    /// The requirements a node's settings state; keys that are absent state none.
    public init(properties: [String: String]) {
        func list(_ key: String) -> [String] {
            (properties[key] ?? "").split(separator: ",").map(String.init)
        }
        self.init(frameworks: list(Self.frameworksKey),
                  libraries:  list(Self.librariesKey),
                  cxxRuntime: properties[Self.cxxRuntimeKey] == "true")
    }

    /// The settings stating these requirements, for a `SettingsLiteral`: a key only when it
    /// says something, so no requirements are no settings.
    public var properties: [String: String] {
        var properties: [String: String] = [:]
        if !frameworks.isEmpty {
            properties[Self.frameworksKey] = frameworks.joined(separator: ",")
        }
        if !libraries.isEmpty {
            properties[Self.librariesKey] = libraries.joined(separator: ",")
        }
        if cxxRuntime {
            properties[Self.cxxRuntimeKey] = "true"
        }
        return properties
    }

    public var isEmpty: Bool { self == .none }

    /// What both need: a link of two products' objects needs every framework and library
    /// either names, and the C++ runtime if either has C++.
    public func union(_ other: LinkRequirements) -> LinkRequirements {
        LinkRequirements(frameworks: frameworks + other.frameworks,
                         libraries:  libraries + other.libraries,
                         cxxRuntime: cxxRuntime || other.cxxRuntime)
    }

    /// `-framework Foundation -lz`, in that order: every framework, then every library.
    /// The C++ runtime is the linker's own to add, since which library it is and whether
    /// the driver adds it already differ between the two.
    public var frameworkAndLibraryArguments: [String] {
        frameworks.flatMap { ["-framework", $0] } + libraries.map { "-l\($0)" }
    }
}
