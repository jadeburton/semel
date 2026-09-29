// ApplePrelude.swift
// SemelApple
//
// The funcs a formula gets from `include 'apple'` (B-108): an app bundle's compiled
// resources, its Info.plist, and the bundle itself as one tree. The executable comes from
// `include 'swift'`; a tree entry carries the mode of the file it was made from, so the
// executable keeps the bit that lets it launch.

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
    ///
    /// The `…WithIcon` funcs are the same for an app whose icon is an Icon Composer `.icon`
    /// beside the catalog, as Xcode 26 lays out a new app: `icon` is that folder, compiled
    /// with the catalog. A variant is its own func, since a func has no optional parameters.
    ///
    /// `bundle` is a flat bundle, an iOS one: the executable under `name`, `Info.plist`
    /// and `PkgInfo` at the root, and the resources tree merged beside them. `pkgInfo` is
    /// a path, as `base` is to `infoPlist`; the others are what the funcs above return.
    static let prelude = """
        func settings(project, machine) = ConfigMerger(base: ['machine': StaticFile(path: machine).output], override: ['project': StaticFile(path: project).output]).output

        func selected(settings, prefix) = ConfigFilter(prefix: prefix, input: ['config': settings]).output

        func assets(catalog, appIcon, settings) = AssetCatalogCompiler(
            configuration: ['config': ConfigMerger(base: ['settings': selected(settings: settings, prefix: '\(AssetCatalogCompilerConfiguration.settingNamespace)')], override: ['literals': SettingsLiteral(appIcon: appIcon).output]).output],
            catalogs: ['assets': Folder(path: catalog).manifest]
        )

        func assetsWithIcon(catalog, icon, appIcon, settings) = AssetCatalogCompiler(
            configuration: ['config': ConfigMerger(base: ['settings': selected(settings: settings, prefix: '\(AssetCatalogCompilerConfiguration.settingNamespace)')], override: ['literals': SettingsLiteral(appIcon: appIcon).output]).output],
            catalogs: ['assets': Folder(path: catalog).manifest, 'icon': Folder(path: icon).manifest]
        )

        func resources(catalog, appIcon, strings, settings) = TreeMerger(input: [
            'assets': assets(catalog: catalog, appIcon: appIcon, settings: settings).files,
            {file: '%%strings%%/*.xcstrings'} "%%file.0%%": StringCatalogCompiler(
                configuration: ['config': selected(settings: settings, prefix: '\(StringCatalogCompilerConfiguration.settingNamespace)')],
                catalog: ["%%file.0%%.xcstrings": StaticFile(path: file).output]
            ).files
        ]).files

        func resourcesWithIcon(catalog, icon, appIcon, strings, settings) = TreeMerger(input: [
            'assets': assetsWithIcon(catalog: catalog, icon: icon, appIcon: appIcon, settings: settings).files,
            {file: '%%strings%%/*.xcstrings'} "%%file.0%%": StringCatalogCompiler(
                configuration: ['config': selected(settings: settings, prefix: '\(StringCatalogCompilerConfiguration.settingNamespace)')],
                catalog: ["%%file.0%%.xcstrings": StaticFile(path: file).output]
            ).files
        ]).files

        func infoPlist(base, catalog, appIcon, settings) = InfoPlistBuilder(
            base: ['base': StaticFile(path: base).output],
            partials: ['assets': assets(catalog: catalog, appIcon: appIcon, settings: settings).partialInfoPlist]
        ).plist

        func infoPlistWithIcon(base, catalog, icon, appIcon, settings) = InfoPlistBuilder(
            base: ['base': StaticFile(path: base).output],
            partials: ['assets': assetsWithIcon(catalog: catalog, icon: icon, appIcon: appIcon, settings: settings).partialInfoPlist]
        ).plist

        func bundle(executable, name, infoPlist, pkgInfo, resources) = TreeMerger(input: [
            'files': TreeBuilder(input: [
                '%%name%%': executable,
                'Info.plist': infoPlist,
                'PkgInfo': StaticFile(path: pkgInfo).output
            ]).files,
            'resources': resources
        ]).files
        """
}
