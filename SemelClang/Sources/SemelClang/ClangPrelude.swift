// ClangPrelude.swift
// SemelClang
//
// The funcs a formula gets from `include 'clang'` (B-108): a C or C++ project as a folder
// of sources and a settings file, without the preprocessor → compiler → linker (or
// archiver) chain.
//
// The text expands to the graph a hand-written formula builds — one preprocessor and one
// compiler per source file, the wires named as the fixtures name them — so a formula that
// moves to `clang.executable(…)` keeps its nodes and its cache.

import SemelNodeKit

extension SemelClang {

    static let includeProvider = FixedFormulaInclude(pluginName: "SemelClang",
                                                     name:       "clang",
                                                     namespace:  "clang",
                                                     text:       prelude)

    /// Every func takes the settings as a node — `settings(project:machine:)` lays the
    /// project's file over the machine's (B-109), and a formula with a stack of its own
    /// builds that node itself — and selects each tool's slice by the namespace its node
    /// type reads, which is the wiring every hand-written formula repeated. `sources` is a
    /// folder: the prelude, not the formula, says which files in it a compiler takes —
    /// `*.c`, `*.cpp` — at any depth (`**/`), so `src/lib/*.c` is compiled with `src/*.c`
    /// and a hidden folder is not entered. Each object is named by its source's full path,
    /// which is what keeps `src/a.c` and `src/lib/a.c` two objects rather than one.
    ///
    /// `compiled(file:settings:)` is a func of its own, and not only the body of `linked`,
    /// because a project whose sources are not one folder's worth — Lua's flat root holds
    /// the library, the interpreter's `main` and a file that includes every other (B-79) —
    /// names its files itself and still wants the chain per file.
    static let prelude = """
        func settings(project, machine) = ConfigMerger(base: [StaticFile(path: machine)], override: [StaticFile(path: project)])

        func selected(settings, prefix) = ConfigFilter(prefix: prefix, input: [settings])

        func preprocessed(file, settings) = ClangPreprocessor(
          configuration: [selected(settings: settings, prefix: '\(ClangPreprocessorConfiguration.settingNamespace)')],
          input: [file: StaticFile(path: file)]
        )

        func compiled(file, settings) = ClangCompiler(
          configuration: [selected(settings: settings, prefix: '\(ClangCompilerConfiguration.settingNamespace)')],
          input: ["%%file%%.p": preprocessed(file: file, settings: settings)]
        )

        func linked(sources, settings, dynamicLibrary) = ClangLinker(
          configuration: [ConfigMerger(base: [selected(settings: settings, prefix: '\(ClangLinkerConfiguration.settingNamespace)')], override: [SettingsLiteral(dynamicLibrary: dynamicLibrary)])],
          objectFiles: [{file: '%%sources%%/**/*.c', '%%sources%%/**/*.cpp'} "%%file%%.o": compiled(file: file, settings: settings)]
        )

        func executable(sources, settings) = linked(sources: sources, settings: settings, dynamicLibrary: 'false')

        func dynamicLibrary(sources, settings) = linked(sources: sources, settings: settings, dynamicLibrary: 'true')

        func staticLibrary(sources, settings) = ClangArchiver(
          configuration: [selected(settings: settings, prefix: '\(ClangArchiverConfiguration.settingNamespace)')],
          objectFiles: [{file: '%%sources%%/**/*.c', '%%sources%%/**/*.cpp'} "%%file%%.o": compiled(file: file, settings: settings)]
        )
        """
}
