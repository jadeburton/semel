//
//  CMakeProject.swift
//  SemelCMake
//
//  A CMake project as its files declare it, once evaluated: the targets and what each says
//  about itself, in CMake's own vocabulary, with nothing left of how the files said it —
//  no variables, no conditions, no order of evaluation. `CMakeEvaluation` produces one from
//  the files and `CMakeFormulaEmitter` writes the formula from it; the model is the seam
//  between them, and the one thing a test of either side has to agree on.
//
//  Two things are deliberately not here. Usage requirements are kept as declared, with
//  their visibility, and not propagated: what a consumer inherits from `PUBLIC` is a rule
//  of CMake's that the emitter applies where it builds a target's command line, as the
//  Swift converter walks a target's dependencies where it emits them. And the facts a
//  condition was decided on — the platform, an option's default — are an input to
//  evaluation, not a record in its result.
//

/// Where a declaration is in the project's files: the file's path relative to the project
/// root and the line the command starts on, which is what a refusal names.
public struct CMakeLocation: Equatable, Hashable {
    public var file: String
    public var line: Int

    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }

    public var description: String { "\(file):\(line)" }
}

/// `PRIVATE`, `PUBLIC` or `INTERFACE`: whether a requirement is the target's own, its
/// consumers', or both.
public enum CMakeVisibility: String, Equatable {
    case `private`  = "PRIVATE"
    case `public`   = "PUBLIC"
    case interface  = "INTERFACE"

    /// Whether the target the requirement is declared on compiles with it.
    public var appliesToSelf: Bool { self != .interface }

    /// Whether a target linking the one it is declared on compiles with it.
    public var appliesToConsumers: Bool { self != .private }
}

/// A requirement with the visibility it was declared under.
public struct CMakeScoped<Value: Equatable>: Equatable {
    public var value: Value
    public var visibility: CMakeVisibility

    public init(_ value: Value, _ visibility: CMakeVisibility) {
        self.value      = value
        self.visibility = visibility
    }
}

/// What a target links beyond its own objects, as `target_link_libraries` names it.
public enum CMakeLinkItem: Equatable {
    /// Another target of this project, by its name — an alias already resolved.
    case target(String)
    /// A library by name, `-l<name>`: a bare name that is no target, or `-lfoo`.
    case library(String)
    /// `-framework <name>`.
    case framework(String)
    /// A path to a library file: anything with a `/` in it.
    case path(String)
    /// Any other flag the linker is handed as it is.
    case flag(String)
}

public struct CMakeTarget: Equatable {
    public enum Kind: Equatable {
        case executable
        case staticLibrary
        case sharedLibrary
        /// A header-only library: usage requirements and nothing to build.
        case interfaceLibrary
    }

    public var name: String
    public var kind: Kind
    /// `OUTPUT_NAME`, when the file is not named after the target.
    public var outputName: String?
    /// The folder of the `CMakeLists.txt` that declared the target, relative to the
    /// project root; empty for the root itself.
    public var folder: String
    public var declaredAt: CMakeLocation
    /// Relative to the project root, in declaration order. An entry holding `*` or `?` is a
    /// pattern from `file(GLOB)`, which the formula states as one; an absolute path is one
    /// outside the project, which it cannot.
    public var sources: [String]
    /// Relative to the project root where under it, else as given.
    public var includeDirectories: [CMakeScoped<String>]
    /// Without any leading `-D`, as CMake stores them.
    public var compileDefinitions: [CMakeScoped<String>]
    public var compileOptions: [CMakeScoped<String>]
    public var linkItems: [CMakeScoped<CMakeLinkItem>]
    public var linkOptions: [CMakeScoped<String>]
    /// `C_STANDARD` and `CXX_STANDARD` as CMake spells them, `11`, `17`; nil takes the
    /// project's. `C_EXTENSIONS` and `CXX_EXTENSIONS` likewise.
    public var cStandard: String?
    public var cxxStandard: String?
    public var cExtensions: Bool?
    public var cxxExtensions: Bool?

    public init(name: String, kind: Kind, folder: String, declaredAt: CMakeLocation) {
        self.name       = name
        self.kind       = kind
        self.folder     = folder
        self.declaredAt = declaredAt
        outputName         = nil
        sources            = []
        includeDirectories = []
        compileDefinitions = []
        compileOptions     = []
        linkItems          = []
        linkOptions        = []
        cStandard          = nil
        cxxStandard        = nil
        cExtensions        = nil
        cxxExtensions      = nil
    }
}

/// A command, or part of one, that evaluation did not translate, and why. Data rather than
/// an error: the rest of the project is still translated, the tool prints these, and a
/// node would publish them.
public struct CMakeUntranslated: Equatable {
    public enum Reason: Equatable {
        /// A command the declarative subset does not include: `find_package`,
        /// `add_custom_command`, `execute_process`, a function the file defined …
        case unsupportedCommand
        /// A block whose condition the facts do not decide, skipped whole: neither branch
        /// was evaluated, so whatever either declared is missing.
        case undecidableCondition(String)
        /// Control flow: `foreach`, `while`, `function`, `macro`, skipped to its end.
        case controlFlow
        /// An argument the command takes that this subset does not: `PARENT_SCOPE`,
        /// `IMPORTED`, `MODULE`, a `file()` subcommand, a property.
        case unsupportedArgument(String)
        /// `$ENV{…}`: a value from outside the project.
        case environmentVariable(String)
        /// A variable whose value is the build tree's or the machine's, which a function of
        /// the sources cannot know: `CMAKE_BINARY_DIR`, `CMAKE_C_COMPILER` …
        case unsupportedVariable(String)
        /// A generator expression, `$<…>`, which only a generator evaluates.
        case generatorExpression(String)
        /// A link item naming a target the project does not declare — an imported one from
        /// a `find_package` that was not run, `Threads::Threads`.
        case unknownTarget(String)
        /// A file `add_subdirectory` or `include` named that the reader did not have.
        case fileNotFound(String)
        /// `include(<Module>)`: a module of CMake's own, not a file of the project.
        case cmakeModule(String)
    }

    public var location: CMakeLocation
    public var command: String
    public var reason: Reason
    /// The target the command would have changed, when it named one.
    public var affectedTarget: String?

    public init(location: CMakeLocation, command: String, reason: Reason, affectedTarget: String? = nil) {
        self.location       = location
        self.command        = command
        self.reason         = reason
        self.affectedTarget = affectedTarget
    }

    /// One line for a report or a formula comment.
    public var description: String {
        let what: String
        switch reason {
        case .unsupportedCommand:                 what = "is not in the declarative subset"
        case .undecidableCondition(let text):     what = "has a condition the facts do not decide: \(text); neither branch was read"
        case .controlFlow:                        what = "is control flow; the block was skipped"
        case .unsupportedArgument(let argument):  what = "takes \(argument), which is not supported"
        case .environmentVariable(let name):      what = "reads the environment, $ENV{\(name)}"
        case .unsupportedVariable(let name):      what = "reads \(name), a fact of the build tree or the machine"
        case .generatorExpression(let text):      what = "holds a generator expression, \(text)"
        case .unknownTarget(let name):            what = "links \(name), which no CMakeLists.txt here declares"
        case .fileNotFound(let path):             what = "names \(path), which is not there"
        case .cmakeModule(let name):              what = "includes CMake's own module \(name)"
        }
        let target = affectedTarget.map { " (target \($0))" } ?? ""
        return "\(location.description): \(command) \(what)\(target)"
    }
}

/// The languages a target's sources are in, as CMake names them.
public enum CMakeLanguage: String, Equatable, Comparable {
    case c         = "C"
    case cxx       = "CXX"
    case objc      = "OBJC"
    case objcxx    = "OBJCXX"
    case assembly  = "ASM"

    public static func < (lhs: CMakeLanguage, rhs: CMakeLanguage) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The language of a source by its extension, nil for a header or anything else a
    /// target lists but no compiler takes.
    public init?(sourcePath: String) {
        let name = sourcePath.split(separator: "/").last.map(String.init) ?? sourcePath
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return nil
        }
        let suffix = String(name[name.index(after: dot)...])
        switch suffix {
        case "c":                                       self = .c
        case "cc", "cpp", "cxx", "c++", "C", "CPP":     self = .cxx
        case "m":                                       self = .objc
        case "mm", "M":                                 self = .objcxx
        case "s", "S", "asm":                           self = .assembly
        default:                                        return nil
        }
    }

    /// Whether a compiler takes the file: the formula compiles these and leaves the rest,
    /// headers among them, to the include finder.
    public static func isCompiled(_ sourcePath: String) -> Bool {
        CMakeLanguage(sourcePath: sourcePath) != nil
    }
}

public struct CMakeProject: Equatable {
    /// From `project()`; nil when no file called it.
    public var name: String?
    /// What `project()` and `enable_language()` enabled; `C` and `CXX` when neither said.
    public var languages: [CMakeLanguage]
    /// `CMAKE_C_STANDARD` and the rest at the root, the targets' defaults.
    public var cStandard: String?
    public var cxxStandard: String?
    public var cExtensions: Bool?
    public var cxxExtensions: Bool?
    /// `CMAKE_OSX_DEPLOYMENT_TARGET`, when the project states one.
    public var deploymentTarget: String?
    /// In declaration order, across every file read.
    public var targets: [CMakeTarget]
    public var untranslated: [CMakeUntranslated]

    public init() {
        name             = nil
        languages        = []
        cStandard        = nil
        cxxStandard      = nil
        cExtensions      = nil
        cxxExtensions    = nil
        deploymentTarget = nil
        targets          = []
        untranslated     = []
    }

    public func target(named name: String) -> CMakeTarget? {
        targets.first { $0.name == name }
    }
}
