// ClangPrelude.swift
// SemelClang
//
// The funcs a formula gets from `include 'clang'` (B-108): a C or C++ project as a folder
// of sources and a settings file, without the preprocessor → compiler → linker chain.
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

    /// Every func takes the settings file whole and selects each tool's slice by the
    /// namespace its node type reads, which is the wiring every hand-written formula
    /// repeated. `sources` is a folder: the prelude, not the formula, says which files in it
    /// a compiler takes — `*.c`, `*.cpp` — one level deep, as folder patterns match.
    static let prelude = """
        func selected(settings, prefix) = ConfigFilter(prefix: prefix, input: [StaticFile(path: settings)])

        func preprocessed(file, settings) = ClangPreprocessor(
          configuration: [selected(settings: settings, prefix: '\(ClangPreprocessorConfiguration.settingNamespace)')],
          input: [file: StaticFile(path: file)]
        )

        func linked(sources, settings, dynamicLibrary) = ClangLinker(
          configuration: [Configuration(inherit: [selected(settings: settings, prefix: '\(ClangLinkerConfiguration.settingNamespace)')], dynamicLibrary: dynamicLibrary)],
          objectFiles: [{file: '%%sources%%/*.c', '%%sources%%/*.cpp'} "%%file%%.o": ClangCompiler(
            configuration: [selected(settings: settings, prefix: '\(ClangCompilerConfiguration.settingNamespace)')],
            input: ["%%file%%.p": preprocessed(file: file, settings: settings)]
          )]
        )

        func executable(sources, settings) = linked(sources: sources, settings: settings, dynamicLibrary: 'false')

        func dynamicLibrary(sources, settings) = linked(sources: sources, settings: settings, dynamicLibrary: 'true')
        """
}
