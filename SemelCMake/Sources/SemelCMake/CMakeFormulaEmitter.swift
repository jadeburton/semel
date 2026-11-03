//
//  CMakeFormulaEmitter.swift
//  SemelCMake
//
//  From the model to the two files a C project carries: the formula, in the funcs a
//  hand-written one uses — `include 'clang'`, one chain per target, the chain the prelude
//  gives where a target adds nothing to it — and `semel.config`, the project's half of the
//  settings. Pure text in, text out, and nothing else: what the files say about a target
//  is the evaluator's, and where they go is the tool's.
//
//  What CMake propagates, this applies here: a target compiles with its own `PRIVATE` and
//  `PUBLIC` requirements and the `PUBLIC` and `INTERFACE` ones of every target it links,
//  through those targets' own public links; and what a static library links, its
//  consumers link, because an archive carries no link line of its own.
//

import SemelNodeKit

public struct CMakeFormulaEmitter {

    /// What the files are written for: the target triple every clang namespace is
    /// configured with, and where the machine file is, relative to the formula.
    public struct Build: Equatable {
        public var target: String
        public var machineConfigPath: String

        public init(target: String, machineConfigPath: String) {
            self.target            = target
            self.machineConfigPath = machineConfigPath
        }
    }

    public static let formulaFileName = "semel.fmla"
    public static let configFileName  = "semel.config"

    /// The clang nodes a target is built through, named as a formula names a node type:
    /// this package does not depend on SemelClang, as the Swift converter does not.
    static let preprocessorNamespace = derivedSettingNamespace(forTypeName: "ClangPreprocessor")
    static let compilerNamespace     = derivedSettingNamespace(forTypeName: "ClangCompiler")
    static let linkerNamespace       = derivedSettingNamespace(forTypeName: "ClangLinker")
    static let archiverNamespace     = derivedSettingNamespace(forTypeName: "ClangArchiver")

    /// Clang's own standards where the project states none: what `-std` is without one.
    static let defaultCStandard   = "gnu17"
    static let defaultCxxStandard = "gnu++17"

    private let project: CMakeProject
    private let build: Build
    /// The func name of each target, by target name.
    private let identifiers: [String: String]

    public init(project: CMakeProject, build: Build) {
        self.project = project
        self.build   = build
        identifiers  = Self.identifiers(for: project.targets.map(\.name))
    }

    // MARK: - The formula

    public func formula() -> String {
        var lines: [String] = []
        let named = project.name.map { " the project `\($0)`" } ?? " the project"
        lines.append("// Written by semel-cmake from CMakeLists.txt:\(named), as its files declare it, in")
        lines.append("// the funcs a hand-written C formula uses. semel-cmake never overwrites this file: edit")
        lines.append("// it, and run semel-cmake again only to start over.")
        if !project.untranslated.isEmpty {
            lines.append("//")
            lines.append("// Not translated, the rest is:")
            for refusal in project.untranslated {
                lines.append("//   \(refusal.description)")
            }
        }
        lines.append("")
        lines.append("include 'clang'")
        lines.append("")
        lines.append("func settings() = clang.settings(project: <\(Self.configFileName)>, machine: <\(build.machineConfigPath)>)")
        for target in project.targets {
            lines.append("")
            lines.append(contentsOf: block(for: target))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Every line of one target: a comment naming it, its chain and its product.
    private func block(for target: CMakeTarget) -> [String] {
        let identifier = identifiers[target.name] ?? target.name
        var lines = ["// \(target.name): \(Self.kindDescription(target.kind)), \(target.declaredAt.description)"]
        guard target.kind != .interfaceLibrary else {
            lines.append("// A header-only library: what it declares reaches the targets that link it, and it builds nothing.")
            return lines
        }
        let compile = compileRequirements(of: target)
        let sources = Self.compiledSources(of: target)
        for outside in target.sources.filter({ !CMakePaths.isInsideProject($0) }) {
            lines.append("// Not placed, outside the project: \(outside)")
        }
        for outside in compile.headerFolders.filter({ !CMakePaths.isInsideProject($0) }) {
            lines.append("// Not placed, outside the project: \(outside)")
        }
        guard !sources.isEmpty else {
            lines.append("// Nothing to compile: no source a compiler takes.")
            return lines
        }

        // The chain: the prelude's where the target adds nothing, else its own funcs with
        // the target's literals laid over each tool's slice.
        let preprocessorLiterals = Self.rendered(compile.preprocessorLiterals)
        let compilerLiterals     = Self.rendered(compile.compilerLiterals)
        let headerFolders        = compile.headerFolders.filter(CMakePaths.isInsideProject)
        let compiledFunc: String
        if preprocessorLiterals.isEmpty, compilerLiterals.isEmpty, headerFolders.isEmpty {
            compiledFunc = "clang.compiled(file: file, settings: settings())"
        } else {
            compiledFunc = "compiled_\(identifier)(file: file)"
            lines.append("func preprocessed_\(identifier)(file) = ClangPreprocessor(")
            lines.append("  configuration: [\(Self.configuration(namespace: Self.preprocessorNamespace, literals: preprocessorLiterals))],")
            lines.append("  input: [file: StaticFile(path: file)]" + (headerFolders.isEmpty ? "" : ","))
            if !headerFolders.isEmpty {
                // Keyed with a number first: the preprocessor orders its `-I`s by wire key,
                // and the order the project gave them is kept this way.
                let wires = headerFolders.enumerated().map { index, folder in
                    "'\(index < 10 ? "0" : "")\(index) \(folder)': Folder(path: <\(folder)>).manifest"
                }
                lines.append("  headerFolders: [" + wires.joined(separator: ", ") + "]")
            }
            lines.append(")")
            lines.append("")
            lines.append("func compiled_\(identifier)(file) = ClangCompiler(")
            lines.append("  configuration: [\(Self.configuration(namespace: Self.compilerNamespace, literals: compilerLiterals))],")
            lines.append("  input: [\"%%file%%.p\": preprocessed_\(identifier)(file: file)]")
            lines.append(")")
            lines.append("")
        }

        let items = sources.map { "<\($0)>" }.joined(separator: ", ")
        let objects = "objectFiles: [{file: \(items)} \"%%file%%.o\": \(compiledFunc)]"
        let product = Self.productName(of: target)
        switch target.kind {
        case .staticLibrary:
            lines.append("func \(identifier)() = ClangArchiver(")
            lines.append("  configuration: [clang.selected(settings: settings(), prefix: '\(Self.archiverNamespace)')],")
            lines.append("  \(objects)")
            lines.append(")")
        case .executable, .sharedLibrary:
            let link = linkRequirements(of: target)
            var literals = link.literals
            literals["dynamicLibrary"] = target.kind == .sharedLibrary ? "true" : "false"
            lines.append("func \(identifier)() = ClangLinker(")
            lines.append("  configuration: [\(Self.configuration(namespace: Self.linkerNamespace, literals: Self.rendered(literals)))],")
            lines.append("  \(objects)" + (link.libraryWires.isEmpty ? "" : ","))
            if !link.libraryWires.isEmpty {
                lines.append("  libraries: [" + link.libraryWires.joined(separator: ", ") + "]")
            }
            lines.append(")")
        case .interfaceLibrary:
            break
        }
        lines.append("")
        lines.append("product \(Self.quoted(product)) = \(identifier)()")
        return lines
    }

    /// The selector for a namespace with the target's literals laid over it, or the
    /// selector alone. The literals win over the file: they say what the target is.
    private static func configuration(namespace: String, literals: String) -> String {
        let selector = "clang.selected(settings: settings(), prefix: '\(namespace)')"
        guard !literals.isEmpty else {
            return selector
        }
        return "ConfigMerger(base: [\(selector)], override: [SettingsLiteral(\(literals))])"
    }

    /// `key: 'value'` pairs, sorted: a formula's text becomes a node's identity, and a
    /// dictionary's order is seeded per process.
    private static func rendered(_ literals: [String: String]) -> String {
        literals.sorted { $0.key < $1.key }.map { "\($0.key): \(quoted($0.value))" }.joined(separator: ", ")
    }

    /// A formula string takes whichever quote the value does not hold.
    /// ISSUE: a value holding both quotes cannot be written; it takes the single one and
    /// ends early, as the Swift converter's would.
    static func quoted(_ value: String) -> String {
        value.contains("'") ? "\"\(value)\"" : "'\(value)'"
    }

    private static func kindDescription(_ kind: CMakeTarget.Kind) -> String {
        switch kind {
        case .executable:       return "an executable"
        case .staticLibrary:    return "a static library"
        case .sharedLibrary:    return "a shared library"
        case .interfaceLibrary: return "a header-only library"
        }
    }

    /// The file the target becomes: the executable by its name, a library as `lib<name>.a`
    /// or `lib<name>.dylib`, under `OUTPUT_NAME` where the project sets one.
    public static func productName(of target: CMakeTarget) -> String {
        let output = target.outputName ?? target.name
        switch target.kind {
        case .executable:       return output
        case .staticLibrary:    return "lib\(output).a"
        case .sharedLibrary:    return "lib\(output).dylib"
        case .interfaceLibrary: return output
        }
    }

    /// The sources a compiler takes, inside the project, each once.
    private static func compiledSources(of target: CMakeTarget) -> [String] {
        var seen: Set<String> = []
        return target.sources.filter { CMakePaths.isInsideProject($0) && CMakeLanguage.isCompiled($0) && seen.insert($0).inserted }
    }

    // MARK: - Func names

    /// A func name from a target name: letters, digits and `_`, never starting with a
    /// digit, never the formula's own `settings`, and no two targets sharing one.
    static func identifiers(for names: [String]) -> [String: String] {
        var taken: Set<String> = ["settings"]
        var identifiers: [String: String] = [:]
        for name in names {
            var identifier = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
            if let first = identifier.first, first.isNumber {
                identifier = "_" + identifier
            }
            if identifier.isEmpty {
                identifier = "_"
            }
            var candidate = identifier
            var counter = 2
            while taken.contains(candidate) {
                candidate = "\(identifier)_\(counter)"
                counter += 1
            }
            taken.insert(candidate)
            identifiers[name] = candidate
        }
        return identifiers
    }

    // MARK: - Requirements

    struct CompileRequirements {
        var headerFolders: [String] = []
        var preprocessorLiterals: [String: String] = [:]
        var compilerLiterals: [String: String] = [:]
    }

    struct LinkRequirementsText {
        var literals: [String: String] = [:]
        var libraryWires: [String] = []
    }

    /// The targets whose usage requirements reach `target`: what it links, and what those
    /// link publicly, to the end; each once, in the order met.
    private func reachedTargets(from target: CMakeTarget, followingPrivateLinksOfStaticLibraries: Bool) -> [CMakeTarget] {
        var reached: [CMakeTarget] = []
        var names: Set<String> = [target.name]
        var queue: [(CMakeTarget, Bool)] = [(target, true)]
        while !queue.isEmpty {
            let (current, isRoot) = queue.removeFirst()
            for item in current.linkItems {
                guard case .target(let name) = item.value, !names.contains(name),
                      let linked = project.target(named: name) else {
                    continue
                }
                let followed = isRoot || item.visibility.appliesToConsumers
                    || (followingPrivateLinksOfStaticLibraries && current.kind == .staticLibrary)
                guard followed else {
                    continue
                }
                names.insert(name)
                reached.append(linked)
                queue.append((linked, false))
            }
        }
        return reached
    }

    private func compileRequirements(of target: CMakeTarget) -> CompileRequirements {
        var includes: [String] = target.includeDirectories.filter { $0.visibility.appliesToSelf }.map(\.value)
        var defines:  [String] = target.compileDefinitions.filter { $0.visibility.appliesToSelf }.map(\.value)
        var options:  [String] = target.compileOptions.filter { $0.visibility.appliesToSelf }.map(\.value)
        for reached in reachedTargets(from: target, followingPrivateLinksOfStaticLibraries: false) {
            includes += reached.includeDirectories.filter { $0.visibility.appliesToConsumers }.map(\.value)
            defines  += reached.compileDefinitions.filter { $0.visibility.appliesToConsumers }.map(\.value)
            options  += reached.compileOptions.filter { $0.visibility.appliesToConsumers }.map(\.value)
        }

        var requirements = CompileRequirements()
        var preprocessorArguments: [String] = []
        var compilerArguments: [String] = []
        var cStandard   = target.cStandard.map { Self.standard(c: $0, extensions: target.cExtensions ?? project.cExtensions ?? true) }
        var cxxStandard = target.cxxStandard.map { Self.standard(cxx: $0, extensions: target.cxxExtensions ?? project.cxxExtensions ?? true) }
        var index = 0
        while index < options.count {
            let option = options[index]
            index += 1
            if option.hasPrefix("-std=") {
                let value = String(option.dropFirst("-std=".count))
                if value.contains("++") {
                    cxxStandard = value
                } else {
                    cStandard = value
                }
                continue
            }
            if option.hasPrefix("-D"), option.count > 2 {
                defines.append(String(option.dropFirst(2)))
                continue
            }
            if option.hasPrefix("-I"), option.count > 2 {
                let path = String(option.dropFirst(2))
                includes.append(path.hasPrefix("/") ? path : CMakePaths.normalized(CMakePaths.join(target.folder, path)))
                continue
            }
            if ["-I", "-isystem", "-iquote", "-include", "-imacros", "-idirafter"].contains(option), index < options.count {
                preprocessorArguments += [option, options[index]]
                index += 1
                continue
            }
            if option.hasPrefix("-U") || option.hasPrefix("-isystem") || option.hasPrefix("-iquote") || option.hasPrefix("-include")
                || option.hasPrefix("-imacros") || option.hasPrefix("-F") {
                preprocessorArguments.append(option)
                continue
            }
            compilerArguments.append(option)
        }
        requirements.headerFolders = Self.unique(includes)
        let uniqueDefines = Self.unique(defines)
        if !uniqueDefines.isEmpty {
            requirements.preprocessorLiterals["defines"] = uniqueDefines.joined(separator: ",")
        }
        if !preprocessorArguments.isEmpty {
            requirements.preprocessorLiterals["arguments"] = preprocessorArguments.joined(separator: ",")
        }
        if !compilerArguments.isEmpty {
            requirements.compilerLiterals["arguments"] = compilerArguments.joined(separator: ",")
        }
        for (key, value) in [("cStandard", cStandard), ("cxxStandard", cxxStandard)] {
            guard let value else {
                continue
            }
            requirements.preprocessorLiterals[key] = value
            requirements.compilerLiterals[key]     = value
        }
        return requirements
    }

    private func linkRequirements(of target: CMakeTarget) -> LinkRequirementsText {
        var items: [CMakeLinkItem] = target.linkItems.map(\.value)
        var options: [String] = target.linkOptions.filter { $0.visibility.appliesToSelf }.map(\.value)
        for reached in reachedTargets(from: target, followingPrivateLinksOfStaticLibraries: true) {
            let carried = reached.kind == .staticLibrary
            items   += reached.linkItems.filter { carried || $0.visibility.appliesToConsumers }.map(\.value)
            options += reached.linkOptions.filter { carried || $0.visibility.appliesToConsumers }.map(\.value)
        }

        var requirements = LinkRequirementsText()
        var libraries: [String] = []
        var frameworks: [String] = []
        var arguments: [String] = options
        var wires: [String] = []
        var reachedNames: Set<String> = []
        // The in-tree libraries, in the order reached: a dependent before what it depends
        // on, which is the order an archive wants.
        for reached in reachedTargets(from: target, followingPrivateLinksOfStaticLibraries: true)
        where reached.kind == .staticLibrary || reached.kind == .sharedLibrary {
            let file = Self.productName(of: reached)
            if reachedNames.insert(reached.name).inserted {
                wires.append("\(Self.quoted(file)): \(identifiers[reached.name] ?? reached.name)()")
            }
        }
        for item in items {
            switch item {
            case .target:
                continue
            case .library(let name):
                libraries.append(name)
            case .framework(let name):
                frameworks.append(name)
            case .flag(let flag):
                arguments.append(flag)
            case .path(let path):
                if CMakePaths.isInsideProject(path) {
                    let name = path.split(separator: "/").last.map(String.init) ?? path
                    wires.append("\(Self.quoted(name)): StaticFile(path: <\(path)>)")
                } else {
                    arguments.append(path)
                }
            }
        }
        if !libraries.isEmpty {
            requirements.literals["libraries"] = Self.unique(libraries).joined(separator: ",")
        }
        if !frameworks.isEmpty {
            requirements.literals["frameworks"] = Self.unique(frameworks).joined(separator: ",")
        }
        if !arguments.isEmpty {
            requirements.literals["arguments"] = arguments.joined(separator: ",")
        }
        requirements.libraryWires = Self.unique(wires)
        return requirements
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// CMake's `11` with extensions on is clang's `gnu11`, off `c11`; `17` is `gnu++17`.
    static func standard(c version: String, extensions: Bool) -> String {
        (extensions ? "gnu" : "c") + version
    }

    static func standard(cxx version: String, extensions: Bool) -> String {
        (extensions ? "gnu++" : "c++") + version
    }

    // MARK: - The config

    /// This project's half of the settings: the target for every clang namespace, and the
    /// standards for the languages the sources are in, the project's where it states one
    /// and clang's own where it does not.
    public func config() -> String {
        let languages = Set(project.targets.flatMap(\.sources).compactMap(CMakeLanguage.init(sourcePath:)))
        let usesC   = languages.contains(.c) || languages.contains(.objc)
            || (languages.isEmpty && project.languages.contains(.c))
        let usesCxx = languages.contains(.cxx) || languages.contains(.objcxx)
            || (languages.isEmpty && project.languages.contains(.cxx))
        let cStandard   = project.cStandard.map { Self.standard(c: $0, extensions: project.cExtensions ?? true) }
            ?? Self.defaultCStandard
        let cxxStandard = project.cxxStandard.map { Self.standard(cxx: $0, extensions: project.cxxExtensions ?? true) }
            ?? Self.defaultCxxStandard

        var lines = [
            "// Written by semel-cmake from CMakeLists.txt: this project's choices, laid over the",
            "// machine's \(build.machineConfigPath) by the formula — the target, and the standards the",
            "// project states or clang's own where it states none. Spelled out per tool because a",
            "// tool's settings are complete where they are written. semel-cmake never overwrites",
            "// this file.",
            "//",
            "// Values are literal: everything after the first `=` is the value, quotes included.",
            "",
        ]
        for namespace in [Self.preprocessorNamespace, Self.compilerNamespace] {
            lines.append("\(namespace).target=\(build.target)")
            if usesC {
                lines.append("\(namespace).cStandard=\(cStandard)")
            }
            if usesCxx {
                lines.append("\(namespace).cxxStandard=\(cxxStandard)")
            }
            lines.append("")
        }
        lines.append("\(Self.linkerNamespace).target=\(build.target)")
        if usesCxx {
            lines.append("\(Self.linkerNamespace).cxxStandard=\(cxxStandard)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
