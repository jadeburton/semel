//
//  XcodeFrameworkEmitter.swift
//  SemelApple
//
//  A framework target another project of the workspace builds, which an application
//  links and embeds through a reference proxy (B-77 item 4): Sequel Ace's `SPMySQL` and
//  `QueryKit`, each the one framework target of a project under `Frameworks/`. The
//  framework is built the way the application's own sources are — Swift by one compile,
//  each C-family source by its preprocessor and compiler, with the framework project's
//  header map — linked as a dynamic library, and laid out as Xcode lays out a Mac
//  framework: versioned, with `Versions/Current` and the links at its top.

import Foundation
import SemelNodeKit

extension XcodeFormulaEmitter {

    /// A framework target of a referenced project, with what its build needs: the
    /// emitter over its own project, its settings, and the product the application names.
    struct BuiltFramework {
        let product: XcodeProject.BuiltProduct
        /// An emitter over the framework's project, whose folder its paths are relative to.
        let emitter: XcodeFormulaEmitter
        let target: XcodeProject.Target
        let settings: XcodeBuildSettings

        /// `builtFramework_SPMySQL`: the func whose tree is `SPMySQL.framework/…`.
        var function: String {
            XcodeFormulaEmitter.frameworkFunction(for: product.fileName)
        }
    }

    /// The funcs that build `framework`, the last of them `<function>() = TreeBuilder(…)`,
    /// whose tree is the framework under its own name, links and all: what the application
    /// compiles and links against and embeds.
    ///
    /// ISSUE: no Swift interface (`BUILD_LIBRARY_FOR_DISTRIBUTION`), no `SWIFT_INCLUDE_PATHS`,
    /// and the framework's Swift is compiled without its own Objective-C as the underlying
    /// module (`-import-underlying-module`), which a framework whose Swift uses its
    /// Objective-C needs. SPMySQL's Swift imports Foundation and Darwin alone.
    func frameworkBlocks(for framework: BuiltFramework) throws -> [String] {
        let target = framework.target
        let settings = framework.settings
        let identity = try TargetIdentity(target: target, settings: settings, sdk: build.sdk)
        let product = (framework.product.fileName as NSString).deletingPathExtension
        // Named for the framework, not the target, so a framework project's target that
        // shares a name with one of the application's funcs keeps its own.
        let name = FormulaIdentifier.sanitized(product) + "_framework"
        let executable = settings["EXECUTABLE_NAME"] ?? identity.productName
        let version = settings["FRAMEWORK_VERSION"].flatMap { $0.isEmpty ? nil : $0 } ?? "A"
        let root = "\(framework.product.fileName)/Versions/\(version)"
        var blocks: [String] = []
        var files: [(key: String, expression: String)] = []

        let everyListedSource = target.sourcePaths(forSDK: build.sdk).filter { !Self.isDocumentationOnly($0) }
        let listedSwift   = everyListedSource.filter { $0.hasSuffix(".swift") }
        let listedCFamily = everyListedSource.filter(Self.isCFamilySource)
        let listedOther   = everyListedSource.filter { !$0.hasSuffix(".swift") && !Self.isCFamilySource($0) }
        guard listedOther.isEmpty else {
            throw XcodeProjectError.unsupportedSources(target: target.name, files: listedOther)
        }
        let objectiveC = objectiveCSources(of: target, identity: identity, in: [], settings: settings,
                                           listing: { _ in nil }, listed: listedCFamily)
        // The framework project's headers, by their paths in it: its sources' header map, and
        // what a Swift module map of the project names.
        let headerTree = objectiveC.headers
        if !headerTree.isEmpty {
            blocks.append(Self.treeBuilder(named: "headers_\(name)", files: headerTree))
        }

        // ── Swift ────────────────────────────────────────────────────────────
        var objectEntries: [String] = []
        let objectiveCHeaderName = settings["SWIFT_OBJC_INTERFACE_HEADER_NAME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(identity.moduleName)-Swift.h"
        let compilesSwift = !listedSwift.isEmpty
        if compilesSwift {
            var literals = ["moduleName": identity.moduleName, "target": identity.target, "objectiveCHeaderName": objectiveCHeaderName]
            if let languageMode = identity.languageMode {
                literals["languageMode"] = languageMode
            }
            literals.merge(try XcodeSwiftSettings(settings: settings, languageMode: identity.languageMode).literals()) { _, swift in swift }
            let sources = listedSwift.map {
                "        \(Self.quoted($0)): StaticFile(path: \(Self.quoted("\(build.projectFolder)/\($0)"))).output"
            }
            // `SWIFT_INCLUDE_PATHS`: each folder of the project is placed where it is and is
            // an `-I`, with the project's headers laid where a module map there names them
            // relative to itself.
            let includeFolders = XcodeSearchPaths(settings: settings).swiftIncludePaths.map {
                $0.path.isEmpty ? build.projectFolder : "\(build.projectFolder)/\($0.path)"
            }.map { "            \(Self.quoted($0)): Folder(path: \(Self.quoted($0))).manifest" }
            let includeTrees = includeFolders.isEmpty || headerTree.isEmpty ? []
                : ["            \(Self.quoted(build.projectFolder)): headers_\(name)().files"]
            // A framework whose Swift sits beside Objective-C imports that Objective-C as its
            // underlying module, from the framework's headers and module map laid out as the
            // framework will hold them — the module is a framework module, found by `-F` —
            // before the framework exists, as Xcode does it from its build folder.
            var underlyingModule: [String] = []
            let moduleMap = settings["MODULEMAP_FILE"].map(Self.projectRelativePath).flatMap { $0.isEmpty ? nil : $0 }
            if !listedCFamily.isEmpty, let moduleMap {
                literals["importsUnderlyingModule"] = "true"
                let headerEntries = target.publicHeaders.map { (key: "\(framework.product.fileName)/Headers/\(($0 as NSString).lastPathComponent)",
                                                                path: "\(build.projectFolder)/\($0)") }
                    + target.privateHeaders.map { (key: "\(framework.product.fileName)/PrivateHeaders/\(($0 as NSString).lastPathComponent)",
                                                   path: "\(build.projectFolder)/\($0)") }
                    + [(key: "\(framework.product.fileName)/Modules/module.modulemap", path: "\(build.projectFolder)/\(moduleMap)")]
                blocks.append(Self.treeBuilder(named: "moduleHeaders_\(name)", files: headerEntries))
                underlyingModule.append("            \(Self.quoted(product)): moduleHeaders_\(name)().files")
            }
            blocks.append(
                "func compiler_\(name)() =\n" +
                "    SwiftCompiler(\n" +
                "        configuration: ['config': \(configuration(namespace: Self.swiftCompilerNamespace, literals: literals))]" +
                Self.wires("extraSourceFiles", sources) +
                Self.wires("inputModuleMapFolders", includeFolders) +
                Self.wires("includeTrees", includeTrees) +
                Self.wires("frameworkTrees", underlyingModule) +
                "\n    )")
            objectEntries.append("'\(identity.moduleName).o': compiler_\(name)().object")
            files.append((key: "\(root)/Modules/\(identity.moduleName).swiftmodule/\(Self.swiftModuleFileName(triple: identity.target)).swiftmodule",
                          expression: "compiler_\(name)().swiftmodule"))
            if settings["SWIFT_INSTALL_OBJC_HEADER"] != "NO" {
                files.append((key: "\(root)/Headers/\(objectiveCHeaderName)", expression: "compiler_\(name)().objectiveCHeader"))
            }
        }

        // ── Objective-C, C, C++ ──────────────────────────────────────────────
        if !objectiveC.sources.isEmpty {
            var headerWires = ""
            if !headerTree.isEmpty {
                headerWires += ",\n        quoteHeaderTrees: [\(Self.quoted(build.projectFolder)): headers_\(name)().files]"
            }
            if compilesSwift {
                headerWires += ",\n        headerTrees: [" + Self.generatedHeaders(objectiveCHeaderName, product: product,
                                                                               compiler: "compiler_\(name)") + "]"
            }
            if let prefixHeader = objectiveC.prefixHeader {
                headerWires += ",\n        prefixHeader: [\(Self.quoted(prefixHeader)): StaticFile(path: \(Self.quoted(prefixHeader))).output]"
            }
            func preprocessor(named function: String, literals: [String: String]) -> String {
                "func \(function)(path) =\n" +
                "    ClangPreprocessor(\n" +
                "        configuration: ['config': \(configuration(namespace: Self.clangPreprocessorNamespace, literals: literals))],\n" +
                "        input: [path: StaticFile(path: path)]" +
                headerWires +
                "\n    )"
            }
            blocks.append(preprocessor(named: "preprocess_\(name)", literals: objectiveC.preprocessorLiterals))
            let compilerConfiguration = configuration(namespace: Self.clangCompilerNamespace, literals: objectiveC.compilerLiterals)
            var flaggedIndex = 0
            for source in objectiveC.sources {
                var preprocessorFunction = "preprocess_\(name)"
                var sourceCompilerConfiguration = compilerConfiguration
                if let fileFlags = objectiveC.fileFlags[source] {
                    preprocessorFunction = "preprocess_\(name)_\(flaggedIndex)"
                    flaggedIndex += 1
                    blocks.append(preprocessor(named: preprocessorFunction, literals: objectiveC.preprocessorLiterals(adding: fileFlags)))
                    sourceCompilerConfiguration = configuration(namespace: Self.clangCompilerNamespace,
                                                                literals: objectiveC.compilerLiterals(adding: fileFlags))
                }
                objectEntries.append("\(Self.quoted(source + ".o")): ClangCompiler(configuration: ['config': \(sourceCompilerConfiguration)], "
                                     + "input: [\(Self.quoted(source + ".p")): \(preprocessorFunction)(path: \(Self.quoted(source)))]).output")
            }
        }

        // ── the library ──────────────────────────────────────────────────────
        // A dynamic library whose install name is where the framework is loaded from:
        // `LD_DYLIB_INSTALL_NAME`, else `$(INSTALL_PATH)/<framework>/Versions/<version>/<executable>`
        // as Xcode composes it — SPMySQL's `@executable_path/../Frameworks/SPMySQL.framework/…`.
        let installName = settings["LD_DYLIB_INSTALL_NAME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(settings["DYLIB_INSTALL_NAME_BASE"] ?? settings["INSTALL_PATH"] ?? "@rpath")/\(root)/\(executable)"
        var linkerArguments = target.frameworks.sorted().flatMap { ["-framework", $0] }
        linkerArguments += target.linkedFiles.sdkLibraries.map { "-l\($0)" }
        linkerArguments += ["-Xlinker", "-install_name", "-Xlinker", installName]
        if let compatibility = settings["DYLIB_COMPATIBILITY_VERSION"], !compatibility.isEmpty {
            linkerArguments += ["-Xlinker", "-compatibility_version", "-Xlinker", compatibility]
        }
        if let current = settings["DYLIB_CURRENT_VERSION"], !current.isEmpty {
            linkerArguments += ["-Xlinker", "-current_version", "-Xlinker", current]
        }
        for library in target.linkedFiles.libraries {
            objectEntries.append("\(Self.quoted(library)): StaticFile(path: \(Self.quoted("\(build.projectFolder)/\(library)"))).output")
        }
        var linkRequirements: [String] = []
        if objectiveC.compilesCxx {
            linkRequirements.append("        \(Self.quoted("\(target.name) C++")): SettingsLiteral(\(LinkRequirements.cxxRuntimeKey): 'true').output")
        }
        let linkerLiterals = ["linkage": "dynamicLibrary", "outputName": executable, "target": identity.target,
                              "arguments": linkerArguments.joined(separator: ",")]
        blocks.append(
            "func library_\(name)() =\n" +
            "    SwiftLinker(\n" +
            "        configuration: ['config': \(configuration(namespace: Self.swiftLinkerNamespace, literals: linkerLiterals))],\n" +
            "        input: [\n" + objectEntries.map { "            \($0)" }.joined(separator: ",\n") + "\n        ]" +
            Self.wires("linkRequirements", linkRequirements) +
            "\n    )")
        files.append((key: "\(root)/\(executable)", expression: "library_\(name)().output"))

        // ── headers, module map, resources ───────────────────────────────────
        for header in target.publicHeaders {
            files.append((key: "\(root)/Headers/\((header as NSString).lastPathComponent)",
                          expression: "StaticFile(path: \(Self.quoted("\(build.projectFolder)/\(header)"))).output"))
        }
        for header in target.privateHeaders {
            files.append((key: "\(root)/PrivateHeaders/\((header as NSString).lastPathComponent)",
                          expression: "StaticFile(path: \(Self.quoted("\(build.projectFolder)/\(header)"))).output"))
        }
        if let moduleMap = settings["MODULEMAP_FILE"].map(Self.projectRelativePath), !moduleMap.isEmpty {
            files.append((key: "\(root)/Modules/module.modulemap",
                          expression: "StaticFile(path: \(Self.quoted("\(build.projectFolder)/\(moduleMap)"))).output"))
        } else if settings["DEFINES_MODULE"] == "YES" {
            blocks.append("// ISSUE: \(target.name) defines a module and names no module map; the one Xcode writes is not written (B-77 item 4).")
        }
        let plistProperties = try Self.infoPlistProperties(identity: identity, settings: settings, targetName: target.name)
        var plist = "InfoPlistBuilder(keys: '\(plistProperties[InfoPlistBuilder.keysProperty] ?? "{}")', "
                  + "\(InfoPlistBuilder.buildSettingsProperty): '\(plistProperties[InfoPlistBuilder.buildSettingsProperty] ?? "{}")'"
        if let infoPlist = settings["INFOPLIST_FILE"].map(Self.projectRelativePath), !infoPlist.isEmpty {
            plist += ", base: ['base': StaticFile(path: \(Self.quoted("\(build.projectFolder)/\(infoPlist)"))).output]"
        }
        blocks.append("func infoPlist_\(name)() =\n    \(plist), partials: [])")
        files.append((key: "\(root)/Resources/Info.plist", expression: "infoPlist_\(name)().\(InfoPlistBuilder.output)"))
        // ISSUE: a framework's resources are copied as they are; one a compiler takes — a
        // catalog, a xib, a string catalog — is not built.
        let ownInfoPlist = settings["INFOPLIST_FILE"].map(Self.projectRelativePath)
        for resource in target.resourcePaths(forSDK: build.sdk) where Self.isPlainResource(resource) && resource != ownInfoPlist {
            files.append((key: "\(root)/Resources/\((resource as NSString).lastPathComponent)",
                          expression: "StaticFile(path: \(Self.quoted("\(build.projectFolder)/\(resource)"))).output"))
        }
        // What a copy-files phase puts beside the executable: SPMySQL's MySQL client and
        // the OpenSSL it loads, each by `@loader_path`.
        for copied in target.executableCopies {
            files.append((key: "\(root)/\((copied as NSString).lastPathComponent)",
                          expression: "StaticFile(path: \(Self.quoted("\(build.projectFolder)/\(copied)"))).output"))
        }

        // ── the framework, laid out ──────────────────────────────────────────
        let bundleName = framework.product.fileName
        var links = ["\(bundleName)/Versions/Current": version]
        for top in ([executable] + ["Headers", "PrivateHeaders", "Modules", "Resources"]).sorted()
        where files.contains(where: { $0.key == "\(root)/\(top)" || $0.key.hasPrefix("\(root)/\(top)/") }) {
            links["\(bundleName)/\(top)"] = "Versions/Current/\(top)"
        }
        var seen = Set<String>()
        let entries = files.filter { seen.insert($0.key).inserted }.sorted { $0.key < $1.key }
        blocks.append(
            "func \(Self.frameworkFunction(for: bundleName))() =\n" +
            "    TreeBuilder(links: '\(try Self.json(links))', input: [\n" +
            entries.map { "        \(Self.quoted($0.key)): \($0.expression)" }.joined(separator: ",\n") +
            "\n    ]).files")
        return blocks
    }

    /// `builtFramework_SPMySQL` for `SPMySQL.framework`.
    static func frameworkFunction(for fileName: String) -> String {
        "builtFramework_\(FormulaIdentifier.sanitized((fileName as NSString).deletingPathExtension))"
    }

    /// `arm64-apple-macos` for `arm64-apple-macosx13.5`: the name a module takes inside a
    /// framework's `<Module>.swiftmodule` folder, the triple without its version.
    static func swiftModuleFileName(triple: String) -> String {
        let components = triple.split(separator: "-").map(String.init)
        guard components.count >= 3 else {
            return triple
        }
        var system = String(components[2].prefix { $0.isLetter })
        if system == "macosx" {
            system = "macos"
        }
        return ([components[0], components[1], system] + components.dropFirst(3)).joined(separator: "-")
    }
}
