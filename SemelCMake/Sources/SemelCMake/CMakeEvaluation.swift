//
//  CMakeEvaluation.swift
//  SemelCMake
//
//  The declarative subset of CMake, read into a `CMakeProject`: variables and `set`, the
//  project and its targets, what each target declares about itself, the directory-level
//  defaults a target inherits, `add_subdirectory` and `include` of the project's own
//  files, and `if` where the facts decide it. Everything procedural — a loop, a function,
//  a command that runs something or asks the machine — is refused by name and line and
//  the rest of the project is still read, since the person editing the formula wants
//  what did translate, with the gaps marked, rather than nothing.
//
//  A block whose condition the facts do not decide is skipped whole, both branches:
//  reading one would be a guess, and the report says what was not read.
//
//  No file system here: a file `add_subdirectory` names comes through the reader, by its
//  path relative to the root, and the facts are a value. That is what keeps evaluation a
//  function of its inputs, which a node can be and a tool can test without a disk.
//

public enum CMakeEvaluation {

    /// Reads a file of the project by its path relative to the root, nil when there is
    /// none. Throws for a file that is there and cannot be read.
    public typealias FileReader = (String) throws -> String?

    /// The project the root file and the files it reaches declare. A syntax error in any
    /// of them is thrown: a file that does not parse is not a project with a gap, it is
    /// not read at all.
    public static func evaluate(root: CMakeFile, facts: CMakeFacts, fileReader: @escaping FileReader) throws -> CMakeProject {
        var evaluator = Evaluator(facts: facts, fileReader: fileReader)
        try evaluator.run(file: root, folder: "")
        return evaluator.finish()
    }
}

// MARK: - Evaluator

private struct Evaluator {

    /// A directory's state: its variables, which a subdirectory starts with a copy of,
    /// and the defaults `include_directories` and its kin give every target declared
    /// after them in the directory and below.
    struct Scope {
        var variables: [String: String]
        var folder: String
        var includeDirectories: [String] = []
        var compileDefinitions: [String] = []
        var compileOptions: [String] = []
        var linkLibraries: [String] = []
    }

    /// A link item as named, resolved once every file is read, since a target may be
    /// declared after the one that links it.
    struct PendingLink {
        var target: String
        var items: [CMakeScoped<String>]
        var location: CMakeLocation
    }

    let facts: CMakeFacts
    let fileReader: CMakeEvaluation.FileReader
    var project = CMakeProject()
    var scopes: [Scope]
    var aliases: [String: String] = [:]
    var pendingLinks: [PendingLink] = []
    var sawProject = false

    init(facts: CMakeFacts, fileReader: @escaping CMakeEvaluation.FileReader) {
        self.facts      = facts
        self.fileReader = fileReader
        var variables = facts.variables
        variables["CMAKE_SOURCE_DIR"] = facts.sourceDirectory
        scopes = [Scope(variables: variables, folder: "")]
    }

    var scope: Scope {
        get { scopes[scopes.count - 1] }
        set { scopes[scopes.count - 1] = newValue }
    }

    // MARK: Variables

    /// The variables CMake sets per directory and per file, which a `set` cannot usefully
    /// replace and the subset does not let it.
    private func sourceDirectory(of folder: String) -> String {
        folder.isEmpty ? facts.sourceDirectory : facts.sourceDirectory + "/" + folder
    }

    private mutating func enterFile(_ file: CMakeFile, folder: String) {
        scope.folder = folder
        scope.variables["CMAKE_CURRENT_SOURCE_DIR"] = sourceDirectory(of: folder)
        scope.variables["CMAKE_CURRENT_LIST_DIR"]   = sourceDirectory(of: CMakePaths.folder(of: file.path))
        scope.variables["CMAKE_CURRENT_LIST_FILE"]  = facts.sourceDirectory + "/" + file.path
    }

    /// Variables whose value is the build tree's or the machine's: a translation that is a
    /// function of the sources cannot know them, so a command reading one is refused.
    private static let unsupportedVariables: Set<String> = [
        "CMAKE_BINARY_DIR", "CMAKE_CURRENT_BINARY_DIR", "PROJECT_BINARY_DIR", "CMAKE_COMMAND",
        "CMAKE_ROOT", "CMAKE_C_COMPILER", "CMAKE_CXX_COMPILER", "CMAKE_INSTALL_PREFIX",
        "CMAKE_CFG_INTDIR", "CMAKE_MODULE_PATH",
    ]

    // MARK: Running

    mutating func run(file: CMakeFile, folder: String) throws {
        enterFile(file, folder: folder)
        try run(commands: file.commands[...])
    }

    private mutating func run(commands: ArraySlice<CMakeCommand>) throws {
        var index = commands.startIndex
        while index < commands.endIndex {
            let command = commands[index]
            switch command.name {
            case "if":
                index = try runIfBlock(in: commands, from: index)
            case "foreach", "while", "function", "macro", "block":
                let end = Self.blockEnd(in: commands, from: index, opening: command.name, closing: "end" + command.name)
                refuse(command, .controlFlow)
                index = end + 1
            case "elseif", "else", "endif", "endforeach", "endwhile", "endfunction", "endmacro", "endblock":
                // A close without its open: the file is malformed, and CMake would say so.
                // Read on, since nothing here depends on it.
                index += 1
            default:
                try run(command)
                index += 1
            }
        }
    }

    /// The index of the command closing the block opened at `start`, or the slice's end
    /// when none closes it.
    private static func blockEnd(in commands: ArraySlice<CMakeCommand>, from start: Int, opening: String, closing: String) -> Int {
        var depth = 0
        var index = start
        while index < commands.endIndex {
            if commands[index].name == opening {
                depth += 1
            }
            if commands[index].name == closing {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index += 1
        }
        return commands.endIndex - 1
    }

    /// `if` … `elseif` … `else` … `endif`: the branches found at depth 0, the first whose
    /// condition holds run, and the index after `endif`. A condition the facts do not
    /// decide refuses the whole block.
    private mutating func runIfBlock(in commands: ArraySlice<CMakeCommand>, from start: Int) throws -> Int {
        let end = Self.blockEnd(in: commands, from: start, opening: "if", closing: "endif")
        // Branch heads: the `if` and every `elseif` and `else` at this depth.
        var heads: [Int] = [start]
        var depth = 0
        var index = start + 1
        while index < end {
            let name = commands[index].name
            if name == "if" {
                depth += 1
            }
            if name == "endif" {
                depth -= 1
            }
            if depth == 0, name == "elseif" || name == "else" {
                heads.append(index)
            }
            index += 1
        }
        for (position, head) in heads.enumerated() {
            let command = commands[head]
            let bodyEnd = position + 1 < heads.count ? heads[position + 1] : end
            let holds: Bool
            if command.name == "else" {
                holds = true
            } else {
                guard let tokens = expandCondition(of: command) else {
                    return end + 1
                }
                do {
                    holds = try CMakeCondition.evaluate(tokens, variables: scope.variables)
                } catch CMakeConditionError.undecidable(let test) {
                    refuse(commands[start], .undecidableCondition("\(CMakeCondition.text(of: tokens)) (\(test))"))
                    return end + 1
                } catch {
                    refuse(commands[start], .undecidableCondition(CMakeCondition.text(of: tokens)))
                    return end + 1
                }
            }
            if holds {
                try run(commands: commands[(head + 1)..<bodyEnd])
                return end + 1
            }
        }
        return end + 1
    }

    // MARK: Expansion

    /// Every reference replaced by its value, an unquoted argument split on `;` and an
    /// empty one dropped, as CMake hands a command its arguments. Nil when the command
    /// reads something the subset refuses, which has then been reported.
    private mutating func expand(_ command: CMakeCommand) -> [String]? {
        var values: [String] = []
        for argument in command.arguments {
            guard let text = expand(argument.parts, in: command) else {
                return nil
            }
            switch argument.form {
            case .quoted, .bracket:
                values.append(text)
            case .unquoted:
                values.append(contentsOf: text.split(separator: ";", omittingEmptySubsequences: true).map(String.init))
            }
        }
        return values
    }

    private mutating func expand(_ parts: [CMakeArgumentPart], in command: CMakeCommand) -> String? {
        var text = ""
        for part in parts {
            switch part {
            case .literal(let piece):
                text += piece
            case .variable(let nameParts):
                guard let name = expand(nameParts, in: command) else {
                    return nil
                }
                if Self.unsupportedVariables.contains(name) {
                    refuse(command, .unsupportedVariable(name))
                    return nil
                }
                text += scope.variables[name] ?? ""
            case .environment(let name):
                refuse(command, .environmentVariable(name))
                return nil
            case .generatorExpression(let expression):
                refuse(command, .generatorExpression(expression))
                return nil
            }
        }
        return text
    }

    /// A condition's arguments with their form kept: a quoted one names no variable.
    private mutating func expandCondition(of command: CMakeCommand) -> [CMakeConditionToken]? {
        var tokens: [CMakeConditionToken] = []
        for argument in command.arguments {
            guard let text = expand(argument.parts, in: command) else {
                return nil
            }
            switch argument.form {
            case .quoted, .bracket:
                tokens.append(CMakeConditionToken(text: text, quoted: true))
            case .unquoted:
                for piece in text.split(separator: ";", omittingEmptySubsequences: true) {
                    tokens.append(CMakeConditionToken(text: String(piece), quoted: false))
                }
            }
        }
        return tokens
    }

    // MARK: Refusals

    /// The commands whose first argument names the target they change.
    private static let targetCommands: Set<String> = [
        "target_sources", "target_include_directories", "target_compile_definitions", "target_compile_options",
        "target_compile_features", "target_link_libraries", "target_link_options", "target_link_directories",
        "target_precompile_headers", "set_target_properties",
    ]

    private mutating func refuse(_ command: CMakeCommand, _ reason: CMakeUntranslated.Reason, target: String? = nil) {
        var affected = target
        if affected == nil, Self.targetCommands.contains(command.name) {
            affected = command.arguments.first?.literalText
        }
        project.untranslated.append(CMakeUntranslated(location: command.location, command: command.name,
                                                      reason: reason, affectedTarget: affected))
    }

    // MARK: Commands

    /// Commands that change nothing a formula states: what to install, what to test, what
    /// to print, and the policy settings. Dropped without a word.
    private static let ignoredCommands: Set<String> = [
        "cmake_minimum_required", "cmake_policy", "message", "install", "add_test", "enable_testing",
        "include_guard", "mark_as_advanced", "export", "set_tests_properties", "source_group",
        "set_directory_properties", "define_property",
        // An ordering between targets, which the wires between them already give.
        "add_dependencies",
    ]

    private mutating func run(_ command: CMakeCommand) throws {
        if Self.ignoredCommands.contains(command.name) {
            return
        }
        guard let arguments = expand(command) else {
            return
        }
        switch command.name {
        case "project":                     runProject(command, arguments)
        case "enable_language":             addLanguages(arguments, command)
        case "set":                         runSet(command, arguments)
        case "unset":                       runUnset(arguments)
        case "option":                      runOption(arguments)
        case "list":                        runList(command, arguments)
        case "string":                      runString(command, arguments)
        case "file":                        runFile(command, arguments)
        case "aux_source_directory":        runAuxSourceDirectory(arguments)
        case "add_executable":              runAddExecutable(command, arguments)
        case "add_library":                 runAddLibrary(command, arguments)
        case "target_sources":              runTargetSources(command, arguments)
        case "target_include_directories":  runTargetIncludeDirectories(command, arguments)
        case "target_compile_definitions":  runTargetScoped(command, arguments, \.compileDefinitions, Self.strippedDefinition)
        case "target_compile_options":      runTargetScoped(command, arguments, \.compileOptions) { $0 }
        case "target_link_options":         runTargetScoped(command, arguments, \.linkOptions) { $0 }
        case "target_compile_features":     runTargetCompileFeatures(command, arguments)
        case "target_link_libraries":       runTargetLinkLibraries(command, arguments)
        case "set_target_properties":       runSetTargetProperties(command, arguments)
        case "include_directories":         runIncludeDirectories(command, arguments)
        case "add_definitions":             runAddDefinitions(arguments)
        case "add_compile_definitions":     scope.compileDefinitions += arguments.map(Self.strippedDefinition)
        case "add_compile_options":         scope.compileOptions += arguments
        case "link_libraries":              scope.linkLibraries += arguments
        case "add_subdirectory":            try runAddSubdirectory(command, arguments)
        case "include":                     try runInclude(command, arguments)
        default:                            refuse(command, .unsupportedCommand)
        }
    }

    private static func strippedDefinition(_ definition: String) -> String {
        definition.hasPrefix("-D") ? String(definition.dropFirst(2)) : definition
    }

    private mutating func runProject(_ command: CMakeCommand, _ arguments: [String]) {
        guard let name = arguments.first else {
            return
        }
        var languages: [String] = []
        var version: String?
        var index = 1
        var sawLanguagesKeyword = false
        while index < arguments.count {
            switch arguments[index] {
            case "VERSION":
                index += 1
                if index < arguments.count {
                    version = arguments[index]
                }
            case "DESCRIPTION", "HOMEPAGE_URL":
                index += 1
            case "LANGUAGES":
                sawLanguagesKeyword = true
                index += 1
                while index < arguments.count, !["VERSION", "DESCRIPTION", "HOMEPAGE_URL"].contains(arguments[index]) {
                    languages.append(arguments[index])
                    index += 1
                }
                continue
            default:
                // The old signature: the languages follow the name.
                if !sawLanguagesKeyword {
                    languages.append(arguments[index])
                }
            }
            index += 1
        }
        if !sawProject {
            sawProject = true
            project.name = name
            scope.variables["CMAKE_PROJECT_NAME"] = name
            if languages.isEmpty {
                project.languages = [.c, .cxx]
            }
        }
        scope.variables["PROJECT_NAME"]       = name
        scope.variables["PROJECT_SOURCE_DIR"] = sourceDirectory(of: scope.folder)
        scope.variables["\(name)_SOURCE_DIR"] = sourceDirectory(of: scope.folder)
        if let version {
            scope.variables["PROJECT_VERSION"]   = version
            scope.variables["\(name)_VERSION"]   = version
        }
        if !languages.isEmpty {
            addLanguages(languages, command)
        }
    }

    private mutating func addLanguages(_ names: [String], _ command: CMakeCommand) {
        for name in names where name != "NONE" {
            guard let language = CMakeLanguage(rawValue: name) else {
                refuse(command, .unsupportedArgument("LANGUAGES \(name)"))
                continue
            }
            if !project.languages.contains(language) {
                project.languages.append(language)
            }
        }
        project.languages.sort()
    }

    private mutating func runSet(_ command: CMakeCommand, _ arguments: [String]) {
        guard let name = arguments.first else {
            return
        }
        var values = Array(arguments.dropFirst())
        if values.last == "PARENT_SCOPE" {
            refuse(command, .unsupportedArgument("PARENT_SCOPE"))
            return
        }
        if name.hasPrefix("ENV{") {
            refuse(command, .environmentVariable(String(name.dropFirst(4).dropLast())))
            return
        }
        // `set(VAR value CACHE TYPE "doc" [FORCE])`: a default, unless already set or forced.
        if let cache = values.firstIndex(of: "CACHE") {
            let forced = values.contains("FORCE")
            values = Array(values[..<cache])
            if !forced, scope.variables[name] != nil {
                return
            }
        }
        if values.isEmpty {
            scope.variables[name] = nil
        } else {
            scope.variables[name] = values.joined(separator: ";")
        }
    }

    private mutating func runUnset(_ arguments: [String]) {
        if let name = arguments.first {
            scope.variables[name] = nil
        }
    }

    private mutating func runOption(_ arguments: [String]) {
        guard let name = arguments.first, scope.variables[name] == nil else {
            return
        }
        scope.variables[name] = arguments.count > 2 ? arguments[2] : "OFF"
    }

    private mutating func runList(_ command: CMakeCommand, _ arguments: [String]) {
        guard arguments.count >= 2 else {
            return
        }
        let name = arguments[1]
        var items = (scope.variables[name] ?? "").split(separator: ";").map(String.init)
        let rest = Array(arguments.dropFirst(2))
        switch arguments[0] {
        case "APPEND":            items += rest
        case "PREPEND":           items = rest + items
        case "REMOVE_ITEM":       items.removeAll { rest.contains($0) }
        case "REMOVE_DUPLICATES":
            var seen: Set<String> = []
            items = items.filter { seen.insert($0).inserted }
        default:
            refuse(command, .unsupportedArgument(arguments[0]))
            return
        }
        scope.variables[name] = items.isEmpty ? nil : items.joined(separator: ";")
    }

    private mutating func runString(_ command: CMakeCommand, _ arguments: [String]) {
        guard arguments.count >= 2 else {
            return
        }
        switch arguments[0] {
        case "APPEND":
            scope.variables[arguments[1]] = (scope.variables[arguments[1]] ?? "") + arguments.dropFirst(2).joined()
        case "CONCAT":
            scope.variables[arguments[1]] = arguments.dropFirst(2).joined()
        case "TOUPPER" where arguments.count >= 3:
            scope.variables[arguments[2]] = arguments[1].uppercased()
        case "TOLOWER" where arguments.count >= 3:
            scope.variables[arguments[2]] = arguments[1].lowercased()
        default:
            refuse(command, .unsupportedArgument(arguments[0]))
        }
    }

    /// `file(GLOB VAR patterns…)`: the patterns themselves, which the formula states as
    /// its own, rather than their expansion, which only a listing could give. A
    /// `GLOB_RECURSE` is the pattern at any depth below its folder.
    private mutating func runFile(_ command: CMakeCommand, _ arguments: [String]) {
        guard let subcommand = arguments.first else {
            return
        }
        guard subcommand == "GLOB" || subcommand == "GLOB_RECURSE", arguments.count >= 2 else {
            refuse(command, .unsupportedArgument(subcommand))
            return
        }
        let name = arguments[1]
        var patterns: [String] = []
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "RELATIVE":
                // Relative to the current folder is where a pattern resolves anyway; any
                // other base would change what the paths mean.
                index += 1
                let base = index < arguments.count ? arguments[index] : ""
                let folder = CMakePaths.resolve(base, inFolder: scope.folder, sourceDirectory: facts.sourceDirectory)
                if folder != scope.folder {
                    refuse(command, .unsupportedArgument("RELATIVE \(base)"))
                    return
                }
            case "CONFIGURE_DEPENDS", "LIST_DIRECTORIES", "true", "false":
                break
            default:
                var pattern = CMakePaths.resolve(arguments[index], inFolder: scope.folder, sourceDirectory: facts.sourceDirectory)
                if subcommand == "GLOB_RECURSE" {
                    let folder = CMakePaths.folder(of: pattern)
                    let last   = pattern.split(separator: "/").last.map(String.init) ?? pattern
                    pattern = CMakePaths.join(CMakePaths.join(folder, "**"), last)
                }
                patterns.append(facts.sourceDirectory + "/" + pattern)
            }
            index += 1
        }
        scope.variables[name] = patterns.isEmpty ? nil : patterns.joined(separator: ";")
    }

    /// `aux_source_directory(dir VAR)`: every source in the folder, which is the patterns
    /// of the languages' extensions there.
    private mutating func runAuxSourceDirectory(_ arguments: [String]) {
        guard arguments.count == 2 else {
            return
        }
        let folder = CMakePaths.resolve(arguments[0], inFolder: scope.folder, sourceDirectory: facts.sourceDirectory)
        let patterns = ["*.c", "*.cc", "*.cpp", "*.cxx", "*.m", "*.mm"].map {
            facts.sourceDirectory + "/" + CMakePaths.join(folder, $0)
        }
        scope.variables[arguments[1]] = patterns.joined(separator: ";")
    }

    // MARK: Targets

    private mutating func declare(_ target: CMakeTarget, sources: [String]) {
        var target = target
        target.sources            = sources.map(resolvePath)
        target.includeDirectories = scope.includeDirectories.map { CMakeScoped($0, .private) }
        target.compileDefinitions = scope.compileDefinitions.map { CMakeScoped($0, .private) }
        target.compileOptions     = scope.compileOptions.map { CMakeScoped($0, .private) }
        if !scope.linkLibraries.isEmpty {
            pendingLinks.append(PendingLink(target: target.name,
                                            items: scope.linkLibraries.map { CMakeScoped($0, .private) },
                                            location: target.declaredAt))
        }
        project.targets.append(target)
    }

    private func resolvePath(_ path: String) -> String {
        CMakePaths.resolve(path, inFolder: scope.folder, sourceDirectory: facts.sourceDirectory)
    }

    private mutating func runAddExecutable(_ command: CMakeCommand, _ arguments: [String]) {
        guard let name = arguments.first else {
            return
        }
        let rest = Array(arguments.dropFirst())
        if rest.first == "ALIAS", rest.count == 2 {
            aliases[name] = rest[1]
            return
        }
        if rest.contains("IMPORTED") {
            refuse(command, .unsupportedArgument("IMPORTED"), target: name)
            return
        }
        var sources: [String] = []
        for argument in rest {
            switch argument {
            case "WIN32", "EXCLUDE_FROM_ALL":
                continue
            case "MACOSX_BUNDLE":
                // Built as a plain executable; the bundle around it is not translated.
                refuse(command, .unsupportedArgument("MACOSX_BUNDLE"), target: name)
            default:
                sources.append(argument)
            }
        }
        declare(CMakeTarget(name: name, kind: .executable, folder: scope.folder, declaredAt: command.location),
                sources: sources)
    }

    private mutating func runAddLibrary(_ command: CMakeCommand, _ arguments: [String]) {
        guard let name = arguments.first else {
            return
        }
        let rest = Array(arguments.dropFirst())
        if rest.first == "ALIAS", rest.count == 2 {
            aliases[name] = rest[1]
            return
        }
        for unsupported in ["IMPORTED", "MODULE", "OBJECT", "UNKNOWN"] where rest.contains(unsupported) {
            refuse(command, .unsupportedArgument(unsupported), target: name)
            return
        }
        var kind: CMakeTarget.Kind = Self.isTrue(scope.variables["BUILD_SHARED_LIBS"]) ? .sharedLibrary : .staticLibrary
        var sources: [String] = []
        for argument in rest {
            switch argument {
            case "STATIC":           kind = .staticLibrary
            case "SHARED":           kind = .sharedLibrary
            case "INTERFACE":        kind = .interfaceLibrary
            case "EXCLUDE_FROM_ALL": continue
            default:                 sources.append(argument)
            }
        }
        declare(CMakeTarget(name: name, kind: kind, folder: scope.folder, declaredAt: command.location),
                sources: sources)
    }

    private static func isTrue(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        return !["", "0", "OFF", "NO", "FALSE", "N", "IGNORE", "NOTFOUND"].contains(value.uppercased())
    }

    /// The index of the named target, resolved through its aliases; a refusal when none.
    private mutating func targetIndex(_ name: String, for command: CMakeCommand) -> Int? {
        let resolved = aliases[name] ?? name
        guard let index = project.targets.firstIndex(where: { $0.name == resolved }) else {
            refuse(command, .unknownTarget(name), target: name)
            return nil
        }
        return index
    }

    /// `(PUBLIC|PRIVATE|INTERFACE) items…` groups, as every `target_*` command takes them.
    /// The default is for a command that allows the keyword to be left out.
    private mutating func scopedItems(_ arguments: ArraySlice<String>, default defaultVisibility: CMakeVisibility?,
                                      for command: CMakeCommand) -> [CMakeScoped<String>]? {
        var visibility = defaultVisibility
        var items: [CMakeScoped<String>] = []
        for argument in arguments {
            if let keyword = CMakeVisibility(rawValue: argument) {
                visibility = keyword
                continue
            }
            guard let visibility else {
                refuse(command, .unsupportedArgument("\(argument) before PUBLIC, PRIVATE or INTERFACE"))
                return nil
            }
            items.append(CMakeScoped(argument, visibility))
        }
        return items
    }

    private mutating func runTargetSources(_ command: CMakeCommand, _ arguments: [String]) {
        guard let name = arguments.first, let index = targetIndex(name, for: command),
              let items = scopedItems(arguments.dropFirst(), default: .private, for: command) else {
            return
        }
        for item in items {
            guard item.visibility != .interface else {
                refuse(command, .unsupportedArgument("INTERFACE sources"))
                continue
            }
            project.targets[index].sources.append(resolvePath(item.value))
        }
    }

    private mutating func runTargetIncludeDirectories(_ command: CMakeCommand, _ arguments: [String]) {
        guard let name = arguments.first, let index = targetIndex(name, for: command) else {
            return
        }
        var rest = Array(arguments.dropFirst())
        if rest.contains("BEFORE") {
            refuse(command, .unsupportedArgument("BEFORE"))
            return
        }
        rest.removeAll { $0 == "SYSTEM" || $0 == "AFTER" }
        guard let items = scopedItems(rest[...], default: nil, for: command) else {
            return
        }
        project.targets[index].includeDirectories += items.map { CMakeScoped(resolvePath($0.value), $0.visibility) }
    }

    private mutating func runTargetScoped(_ command: CMakeCommand, _ arguments: [String],
                                          _ keyPath: WritableKeyPath<CMakeTarget, [CMakeScoped<String>]>,
                                          _ transform: (String) -> String) {
        guard let name = arguments.first, let index = targetIndex(name, for: command) else {
            return
        }
        var rest = Array(arguments.dropFirst())
        if rest.first == "BEFORE" {
            refuse(command, .unsupportedArgument("BEFORE"))
            return
        }
        rest.removeAll { $0 == "SHELL:" }
        guard let items = scopedItems(rest[...], default: nil, for: command) else {
            return
        }
        project.targets[index][keyPath: keyPath] += items.map { CMakeScoped(transform($0.value), $0.visibility) }
    }

    /// `c_std_99` and `cxx_std_17` set the target's standard; a finer feature, `cxx_auto_type`,
    /// says nothing a standard does not, and is dropped.
    private mutating func runTargetCompileFeatures(_ command: CMakeCommand, _ arguments: [String]) {
        guard let name = arguments.first, let index = targetIndex(name, for: command),
              let items = scopedItems(arguments.dropFirst(), default: nil, for: command) else {
            return
        }
        for item in items {
            if item.value.hasPrefix("c_std_") {
                project.targets[index].cStandard = String(item.value.dropFirst("c_std_".count))
            }
            if item.value.hasPrefix("cxx_std_") {
                project.targets[index].cxxStandard = String(item.value.dropFirst("cxx_std_".count))
            }
        }
    }

    private mutating func runTargetLinkLibraries(_ command: CMakeCommand, _ arguments: [String]) {
        guard let name = arguments.first, targetIndex(name, for: command) != nil else {
            return
        }
        var rest = Array(arguments.dropFirst())
        if rest.contains("LINK_INTERFACE_LIBRARIES") {
            refuse(command, .unsupportedArgument("LINK_INTERFACE_LIBRARIES"))
            return
        }
        rest = rest.map { $0 == "LINK_PUBLIC" ? "PUBLIC" : ($0 == "LINK_PRIVATE" ? "PRIVATE" : $0) }
        // The plain signature, with no keyword, is the public one.
        guard let items = scopedItems(rest[...], default: .public, for: command) else {
            return
        }
        pendingLinks.append(PendingLink(target: aliases[name] ?? name, items: items, location: command.location))
    }

    private mutating func runSetTargetProperties(_ command: CMakeCommand, _ arguments: [String]) {
        guard let keyword = arguments.firstIndex(of: "PROPERTIES") else {
            return
        }
        let names = Array(arguments[..<keyword])
        let pairs = Array(arguments[(keyword + 1)...])
        var indices: [Int] = []
        for name in names {
            if let index = targetIndex(name, for: command) {
                indices.append(index)
            }
        }
        var position = 0
        while position + 1 < pairs.count {
            let property = pairs[position]
            let value    = pairs[position + 1]
            position += 2
            for index in indices {
                switch property {
                case "OUTPUT_NAME":    project.targets[index].outputName    = value
                case "C_STANDARD":     project.targets[index].cStandard     = value
                case "CXX_STANDARD":   project.targets[index].cxxStandard   = value
                case "C_EXTENSIONS":   project.targets[index].cExtensions   = Self.isTrue(value)
                case "CXX_EXTENSIONS": project.targets[index].cxxExtensions = Self.isTrue(value)
                case "POSITION_INDEPENDENT_CODE", "C_STANDARD_REQUIRED", "CXX_STANDARD_REQUIRED", "FOLDER":
                    break
                default:
                    refuse(command, .unsupportedArgument("the property \(property)"), target: project.targets[index].name)
                }
            }
        }
    }

    private mutating func runIncludeDirectories(_ command: CMakeCommand, _ arguments: [String]) {
        if arguments.contains("BEFORE") {
            refuse(command, .unsupportedArgument("BEFORE"))
            return
        }
        scope.includeDirectories += arguments.filter { $0 != "SYSTEM" && $0 != "AFTER" }.map(resolvePath)
    }

    /// `-D` flags are definitions; anything else is a flag for the compiler, as CMake
    /// takes it.
    private mutating func runAddDefinitions(_ arguments: [String]) {
        for argument in arguments {
            if argument.hasPrefix("-D") {
                scope.compileDefinitions.append(String(argument.dropFirst(2)))
            } else {
                scope.compileOptions.append(argument)
            }
        }
    }

    // MARK: Files

    private mutating func runAddSubdirectory(_ command: CMakeCommand, _ arguments: [String]) throws {
        guard let directory = arguments.first else {
            return
        }
        let folder = resolvePath(directory)
        guard CMakePaths.isInsideProject(folder) else {
            refuse(command, .unsupportedArgument("a folder outside the project, \(directory)"))
            return
        }
        let path = CMakePaths.join(folder, "CMakeLists.txt")
        guard let text = try fileReader(path) else {
            refuse(command, .fileNotFound(path))
            return
        }
        let file = try CMakeFile.parse(text, path: path)
        // A subdirectory starts with a copy of its parent's variables and defaults, and
        // what it sets stays its own.
        scopes.append(scope)
        try run(file: file, folder: folder)
        scopes.removeLast()
    }

    /// `include(file.cmake)`: read into the current scope, as CMake reads it. A name with
    /// no path and no extension is one of CMake's own modules, which the subset does not
    /// carry.
    private mutating func runInclude(_ command: CMakeCommand, _ arguments: [String]) throws {
        guard let named = arguments.first else {
            return
        }
        let optional = arguments.contains("OPTIONAL")
        guard named.contains("/") || named.hasSuffix(".cmake") else {
            refuse(command, .cmakeModule(named))
            return
        }
        let path = resolvePath(named)
        guard CMakePaths.isInsideProject(path) else {
            refuse(command, .unsupportedArgument("a file outside the project, \(named)"))
            return
        }
        guard let text = try fileReader(path) else {
            if !optional {
                refuse(command, .fileNotFound(path))
            }
            return
        }
        let file = try CMakeFile.parse(text, path: path)
        let folder = scope.folder
        let listDirectory = scope.variables["CMAKE_CURRENT_LIST_DIR"]
        let listFile      = scope.variables["CMAKE_CURRENT_LIST_FILE"]
        try run(file: file, folder: folder)
        scope.variables["CMAKE_CURRENT_LIST_DIR"]  = listDirectory
        scope.variables["CMAKE_CURRENT_LIST_FILE"] = listFile
    }

    // MARK: Finishing

    /// The root's settings read, and every link item resolved now that every target is
    /// declared.
    mutating func finish() -> CMakeProject {
        let root = scopes[0].variables
        project.cStandard        = root["CMAKE_C_STANDARD"]
        project.cxxStandard      = root["CMAKE_CXX_STANDARD"]
        project.cExtensions      = root["CMAKE_C_EXTENSIONS"].map(Self.isTrue)
        project.cxxExtensions    = root["CMAKE_CXX_EXTENSIONS"].map(Self.isTrue)
        project.deploymentTarget = root["CMAKE_OSX_DEPLOYMENT_TARGET"]
        for pending in pendingLinks {
            guard let index = project.targets.firstIndex(where: { $0.name == pending.target }) else {
                continue
            }
            project.targets[index].linkItems += resolveLinkItems(pending)
        }
        return project
    }

    private mutating func resolveLinkItems(_ pending: PendingLink) -> [CMakeScoped<CMakeLinkItem>] {
        var resolved: [CMakeScoped<CMakeLinkItem>] = []
        var index = 0
        let items = pending.items
        let debugBuild = scopes[0].variables["CMAKE_BUILD_TYPE"]?.lowercased() == "debug"
        while index < items.count {
            let item = items[index]
            let text = item.value
            index += 1
            switch text {
            case "general":
                continue
            case "debug", "optimized":
                // The old signature's per-configuration item: the one for this build type
                // is kept, the other dropped with its item.
                if (text == "debug") != debugBuild {
                    index += 1
                }
                continue
            case "-framework":
                if index < items.count {
                    resolved.append(CMakeScoped(.framework(items[index].value), item.visibility))
                    index += 1
                }
                continue
            default:
                break
            }
            let name = aliases[text] ?? text
            if project.targets.contains(where: { $0.name == name }) {
                resolved.append(CMakeScoped(.target(name), item.visibility))
            } else if text.hasPrefix("-framework ") {
                resolved.append(CMakeScoped(.framework(String(text.dropFirst("-framework ".count))), item.visibility))
            } else if text.hasPrefix("-l") {
                resolved.append(CMakeScoped(.library(String(text.dropFirst(2))), item.visibility))
            } else if text.hasPrefix("-") {
                resolved.append(CMakeScoped(.flag(text), item.visibility))
            } else if text.contains("::") {
                project.untranslated.append(CMakeUntranslated(location: pending.location, command: "target_link_libraries",
                                                              reason: .unknownTarget(text), affectedTarget: pending.target))
            } else if text.contains("/") {
                resolved.append(CMakeScoped(.path(CMakePaths.resolve(text, inFolder: "", sourceDirectory: facts.sourceDirectory)),
                                            item.visibility))
            } else {
                resolved.append(CMakeScoped(.library(text), item.visibility))
            }
        }
        return resolved
    }
}
