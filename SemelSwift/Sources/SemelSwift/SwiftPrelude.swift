// SwiftPrelude.swift
// SemelSwift
//
// The funcs a formula gets from `include 'swift'` (B-108): a Swift target outside a
// package — an app's executable is the case — as a folder of sources, a module name and a
// settings file. A `Package.swift` does not need these: `include SwiftFormulaConverter(…)`
// already turns a package into its formula, and a func cannot contain an `include`.

import SemelNodeKit

extension SemelSwift {

    static let includeProvider = FixedFormulaInclude(pluginName: "SemelSwift",
                                                     name:       "swift",
                                                     namespace:  "swift",
                                                     text:       prelude)

    /// A target that imports a package's product is its own func — `executableUsing` — rather
    /// than an optional parameter the formula language does not have. `package` names the
    /// product, and `modules` and `objects` are the trees its converter's formula provides:
    /// `modules_<P>().files`, `objects_<P>().files`.
    ///
    /// The settings wiring is the converter's own — a `ConfigFilter` per tool over the
    /// settings node, merged under a `Configuration` carrying what the formula states — so
    /// a target built here reads its settings as a package target does. The node is what
    /// `settings(project:machine:)` builds, the project's file over the machine's (B-109),
    /// or a stack the formula lays itself.
    static let prelude = """
        func settings(project, machine) = ConfigMerger(base: ['machine': StaticFile(path: machine).output], override: ['project': StaticFile(path: project).output]).output

        func selected(settings, prefix) = ConfigFilter(prefix: prefix, input: ['config': settings]).output

        func compilerSettings(name, settings) = Configuration(moduleName: name, base: ['settings': selected(settings: settings, prefix: '\(SwiftCompilerConfiguration.settingNamespace)')]).output

        func linkerSettings(name, linkage, settings) = Configuration(linkage: linkage, outputName: name, base: ['settings': selected(settings: settings, prefix: '\(SwiftLinkerConfiguration.settingNamespace)')]).output

        func module(sources, name, settings) = SwiftCompiler(
            configuration: ['config': compilerSettings(name: name, settings: settings)],
            inputFolder: ['folder0': Folder(path: sources).manifest]
        )

        func moduleUsing(sources, name, settings, package, modules) = SwiftCompiler(
            configuration: ['config': compilerSettings(name: name, settings: settings)],
            inputFolder: ['folder0': Folder(path: sources).manifest],
            moduleTrees: [package: modules]
        )

        func executable(sources, name, settings) = SwiftLinker(
            configuration: ['config': linkerSettings(name: name, linkage: 'executable', settings: settings)],
            input: ['%%name%%.o': module(sources: sources, name: name, settings: settings).object]
        ).output

        func executableUsing(sources, name, settings, package, modules, objects) = SwiftLinker(
            configuration: ['config': linkerSettings(name: name, linkage: 'executable', settings: settings)],
            input: ['%%name%%.o': moduleUsing(sources: sources, name: name, settings: settings, package: package, modules: modules).object],
            objectTrees: [package: objects]
        ).output

        func staticLibrary(sources, name, settings) = SwiftLinker(
            configuration: ['config': linkerSettings(name: name, linkage: 'staticArchive', settings: settings)],
            input: ['%%name%%.o': module(sources: sources, name: name, settings: settings).object]
        ).output
        """
}
