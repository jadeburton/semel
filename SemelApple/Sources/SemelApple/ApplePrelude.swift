// ApplePrelude.swift
// SemelApple
//
// The funcs a formula gets from `include 'apple'` (B-108): an app bundle's compiled
// resources and its Info.plist. The executable comes from `include 'swift'`, and the
// bundle stays a set of products under one folder name: a tree entry is written with the
// default file mode, so an executable put into the bundle's tree would lose the bit that
// lets it launch.

import SemelNodeKit

extension SemelApple {

    static let includeProvider = FixedFormulaInclude(pluginName: "SemelApple",
                                                     name:       "apple",
                                                     namespace:  "apple",
                                                     text:       prelude)

    /// `catalog` is the asset catalog folder, and `strings` the folder holding the string
    /// catalogs — every `*.xcstrings` in it, each compiled to the table its file names.
    /// `infoPlist` takes the catalog rather than the compiled assets because a func cannot
    /// pick a port off a value it was handed; building the compiler again from the same
    /// arguments names the same node, so nothing is compiled twice.
    static let prelude = """
        func selected(settings, prefix) = ConfigFilter(prefix: prefix, input: ['config': StaticFile(path: settings).output]).output

        func assets(catalog, appIcon, settings) = AssetCatalogCompiler(
            configuration: ['config': Configuration(appIcon: appIcon, inherit: ['settings': selected(settings: settings, prefix: '\(AssetCatalogCompilerConfiguration.settingNamespace)')]).output],
            catalogs: ['assets': Folder(path: catalog).manifest]
        )

        func resources(catalog, appIcon, strings, settings) = TreeMerger(input: [
            'assets': assets(catalog: catalog, appIcon: appIcon, settings: settings).files,
            {file: '%%strings%%/*.xcstrings'} "%%file.0%%": StringCatalogCompiler(
                configuration: ['config': Configuration(inherit: ['settings': selected(settings: settings, prefix: '\(StringCatalogCompilerConfiguration.settingNamespace)')]).output],
                catalog: ["%%file.0%%.xcstrings": StaticFile(path: file).output]
            ).files
        ]).files

        func infoPlist(base, catalog, appIcon, settings) = InfoPlistBuilder(
            base: ['base': StaticFile(path: base).output],
            partials: ['assets': assets(catalog: catalog, appIcon: appIcon, settings: settings).partialInfoPlist]
        ).plist
        """
}
