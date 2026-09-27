//
//  XcodeFormulaEmitter.swift
//  SemelApple
//
//  From a project, a target's evaluated settings and what its folders hold, the formula
//  text that builds the target's bundle: the same nodes a hand-written formula names,
//  arranged the way Xcode would arrange its build. Pure text in, text out; the node that
//  owns the wires is `XcodeProjectConverter`.

import Foundation
import SemelNodeKit

struct XcodeFormulaEmitter {

    /// What a synchronized folder holds, as the converter has walked it: every file and
    /// every folder, relative to it.
    struct FolderListing {
        var files: [String] = []
        var folders: [String] = []
    }

    /// The build the formula is for.
    struct Build {
        /// `input:/repo`: where `semel.config` and `Dependencies/` live.
        let root: String
        /// `input:/repo`: the folder holding the `.xcodeproj`, which target folders are
        /// relative to.
        let projectFolder: String
        let configuration: String
        /// `iphonesimulator`, `iphoneos`, `macosx`.
        let sdk: String
    }

    let project: XcodeProject
    let build: Build

    /// Where the parts of a bundle go, by platform (B-77). An iOS bundle is flat: the
    /// executable, the Info.plist and every resource at its root, extensions under
    /// `PlugIns/`. A macOS bundle has a `Contents/` with `MacOS/` for the executable,
    /// `Resources/` for everything copied or compiled, `PlugIns/` for extensions, and the
    /// Info.plist directly in it.
    struct BundleLayout {
        let isShallow: Bool

        init(sdk: String) {
            isShallow = !sdk.hasPrefix("macosx")
        }

        func executable(in bundle: String, named name: String) -> String {
            isShallow ? "\(bundle)/\(name)" : "\(bundle)/Contents/MacOS/\(name)"
        }

        func infoPlist(in bundle: String) -> String {
            isShallow ? "\(bundle)/Info.plist" : "\(bundle)/Contents/Info.plist"
        }

        func resource(in bundle: String, at path: String) -> String {
            isShallow ? "\(bundle)/\(path)" : "\(bundle)/Contents/Resources/\(path)"
        }

        /// The tree product the compiled resources are merged into, with its trailing slash.
        func resourcesTree(in bundle: String) -> String {
            isShallow ? "\(bundle)/" : "\(bundle)/Contents/Resources/"
        }

        func plugIn(in bundle: String, named name: String) -> String {
            isShallow ? "\(bundle)/PlugIns/\(name)" : "\(bundle)/Contents/PlugIns/\(name)"
        }
    }

    var layout: BundleLayout { BundleLayout(sdk: build.sdk) }

    /// The Swift nodes a target is built through. Named rather than imported: this
    /// package does not depend on SemelSwift, and a formula names a node by type name.
    static let swiftCompilerNamespace = derivedSettingNamespace(forTypeName: "SwiftCompiler")
    static let swiftLinkerNamespace   = derivedSettingNamespace(forTypeName: "SwiftLinker")

    // MARK: - Whole project

    /// The formula for the application target: its bundle, with every package it and its
    /// extensions link included, and each extension the app embeds as a bundle of its
    /// own under the app's `PlugIns/`.
    func formula(settings: (XcodeProject.Target) throws -> XcodeBuildSettings,
                 listing: (String) -> FolderListing?) throws -> String {
        guard let application = project.targets.first(where: \.isApplication) else {
            throw XcodeProjectError.noSuchTarget("an application")
        }
        let extensions = application.embeddedExtensions.compactMap { name in
            project.targets.first { $0.productFileName == name && $0.isExtension }
        }
        var blocks: [String] = ["// Written by XcodeProjectConverter: \(application.name) and \(extensions.count) embedded extension(s)."]
        blocks += includes(for: [application] + extensions)
        let applicationBundle = try TargetIdentity(target: application, settings: try settings(application), sdk: build.sdk).bundleName
        blocks += try bundle(for: application, at: applicationBundle, settings: try settings(application), listing: listing)
        for anExtension in extensions {
            blocks += try bundle(for: anExtension, at: layout.plugIn(in: applicationBundle, named: anExtension.productFileName),
                                 settings: try settings(anExtension), listing: listing)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Packages

    /// One include per package the target links: the package's formula brings the
    /// `modules_P()` / `objects_P()` funcs the target compiles and links against. Local
    /// packages are the project's wrappers; a remote one is where the vendoring rule puts
    /// it, `Dependencies/<repository name>`.
    func includes(for targets: [XcodeProject.Target]) -> [String] {
        var folders: [String] = project.localPackagePaths.map { "\(build.projectFolder)/\($0)" }
        for case .remote(_, let url) in targets.flatMap(\.packageProducts) {
            if let name = Self.repositoryName(forURL: url) {
                folders.append("\(build.root)/Dependencies/\(name)")
            }
        }
        return Array(Set(folders)).sorted().map {
            "include funcs SwiftFormulaConverter(path: '\($0)', root: '\(build.root)').formula"
        }
    }

    /// "https://github.com/evgenyneu/keychain-swift" -> "keychain-swift", the checkout
    /// name SwiftPM and `semel-swift prepare` use.
    static func repositoryName(forURL urlString: String) -> String? {
        var name = urlString
        while name.hasSuffix("/") { name.removeLast() }
        if let lastSeparator = name.lastIndex(where: { $0 == "/" || $0 == ":" }) {
            name = String(name[name.index(after: lastSeparator)...])
        }
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.isEmpty ? nil : name
    }

    // MARK: - One target's bundle

    /// One target's bundle at `bundlePath` — `Ice Cubes.app`, or
    /// `Ice Cubes.app/PlugIns/Share.appex` for an extension the app embeds.
    func bundle(for target: XcodeProject.Target,
                at bundlePath: String,
                settings: XcodeBuildSettings,
                listing: (String) -> FolderListing?) throws -> [String] {
        let identity = try TargetIdentity(target: target, settings: settings, sdk: build.sdk)
        let name = FormulaIdentifier.sanitized(target.name)
        var blocks: [String] = []
        var bundleTrees: [String] = []
        var products: [String] = []

        // ── sources ──────────────────────────────────────────────────────────
        // Every synchronized folder of the target is a source root: the compiler takes
        // them all on its folder port and walks each. Exceptions are relative to their
        // own folder, which is how the compiler reads an excluded path too. A target with
        // no folder of its own compiles what it borrows, and nothing else.
        // A target lists its files through groups (B-77) or owns synchronized folders;
        // either way it has to have a Swift source somewhere. A listed file that is not
        // Swift is a build this converter cannot write yet, said rather than dropped.
        let listedSources = target.sourcePaths(forSDK: build.sdk).filter { $0.hasSuffix(".swift") }
        let listedOther   = target.sourcePaths(forSDK: build.sdk).filter { !$0.hasSuffix(".swift") }
        guard listedOther.isEmpty else {
            throw XcodeProjectError.unsupportedSources(target: target.name, files: listedOther)
        }
        guard !target.synchronizedFolders.isEmpty || !listedSources.isEmpty
                || target.borrowedFiles.contains(where: { $0.hasSuffix(".swift") }) else {
            throw XcodeProjectError.noSuchTarget("\(target.name): no synchronized folder, no listed sources and no borrowed sources")
        }
        let sourceFolders = target.synchronizedFolders.map { ($0, "\(build.projectFolder)/\($0.path)") }
        let folderWires = sourceFolders.enumerated().map { index, folder in
            "        'folder\(index)': Folder(path: '\(folder.1)').manifest"
        }
        let exceptions = sourceFolders.flatMap { $0.0.exceptions }.sorted()
        let moduleTrees = target.packageProducts.map(\.product).sorted().map {
            "        '\($0)': \(FormulaIdentifier.modulesFunc(forProduct: $0))().files"
        }
        let objectTrees = target.packageProducts.map(\.product).sorted().map {
            "        '\($0)': \(FormulaIdentifier.objectsFunc(forProduct: $0))().files"
        }
        var compilerLiterals = ["moduleName": identity.moduleName,
                                "target": identity.target]
        if !exceptions.isEmpty {
            compilerLiterals["excludedPaths"] = exceptions.joined(separator: ",")
        }
        if let languageMode = identity.languageMode {
            compilerLiterals["languageMode"] = languageMode
        }
        var compilerArguments: [String] = []
        for condition in (settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "").split(separator: " ") {
            compilerArguments += ["-D", String(condition)]
        }
        if target.isExtension {
            compilerArguments.append("-application-extension")
        }
        if !compilerArguments.isEmpty {
            compilerLiterals["arguments"] = compilerArguments.joined(separator: ",")
        }
        // What the target takes from another target's folder: sources one by one on the
        // compiler, resources with the target's own. A listed file goes the same way,
        // keyed by its whole path: two groups may each hold a `View.swift`, and the key
        // is where the compiler puts the file.
        let borrowedSources = target.borrowedFiles.filter { $0.hasSuffix(".swift") }.map {
            "        \(Self.quoted(($0 as NSString).lastPathComponent)): StaticFile(path: \(Self.quoted("\(build.projectFolder)/\($0)"))).output"
        } + listedSources.map {
            "        \(Self.quoted($0)): StaticFile(path: \(Self.quoted("\(build.projectFolder)/\($0)"))).output"
        }
        blocks.append(
            "func compiler_\(name)() =\n" +
            "    SwiftCompiler(\n" +
            "        configuration: ['config': \(configuration(namespace: Self.swiftCompilerNamespace, literals: compilerLiterals))]" +
            (folderWires.isEmpty ? "" : ",\n        inputFolder: [\n" + folderWires.joined(separator: ",\n") + "\n        ]") +
            (borrowedSources.isEmpty ? "" : ",\n        extraSourceFiles: [\n" + borrowedSources.joined(separator: ",\n") + "\n        ]") +
            (moduleTrees.isEmpty ? "" : ",\n        moduleTrees: [\n" + moduleTrees.joined(separator: ",\n") + "\n        ]") +
            "\n    )")

        // ── the executable ───────────────────────────────────────────────────
        var linkerArguments: [String] = target.frameworks.sorted().flatMap { ["-framework", $0] }
        if target.isExtension {
            // What ld needs for an app extension, through the swiftc driver: its entry
            // point, and the flag that marks it safe for one.
            linkerArguments += ["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"]
        }
        var linkerLiterals = ["linkage": "executable", "outputName": identity.productName, "target": identity.target]
        if !linkerArguments.isEmpty {
            linkerLiterals["arguments"] = linkerArguments.joined(separator: ",")
        }
        products.append(
            "product '\(layout.executable(in: bundlePath, named: identity.productName))' =\n" +
            "    SwiftLinker(\n" +
            "        configuration: ['config': \(configuration(namespace: Self.swiftLinkerNamespace, literals: linkerLiterals))],\n" +
            "        input: ['\(identity.moduleName).o': compiler_\(name)().object]" +
            (objectTrees.isEmpty ? "" : ",\n        objectTrees: [\n" + objectTrees.joined(separator: ",\n") + "\n        ]") +
            "\n    ).output")

        // ── resources ────────────────────────────────────────────────────────
        // Each folder's listing, with the paths of what it holds, less its exceptions.
        // `bundlePath` is where the file lands in the bundle: flat, as Xcode flattens a
        // folder's files, except a localized file, which keeps its `<lang>.lproj/`.
        struct ResourceFile { let folderPath: String; let relativePath: String; let bundlePath: String }
        var catalogs: [String] = []
        var stringCatalogs: [ResourceFile] = []
        var plainResources: [ResourceFile] = []
        for (folder, folderPath) in sourceFolders {
            let contents = listing(folderPath) ?? FolderListing()
            let excluded = Set(folder.exceptions)
            catalogs += contents.folders.filter { ($0.hasSuffix(".xcassets") || $0.hasSuffix(".icon")) && !excluded.contains($0) }
                .map { "\(folderPath)/\($0)" }
            for file in contents.files.sorted() where !excluded.contains(file) {
                if file.hasSuffix(".xcstrings") && !Self.isInsideCatalog(file) {
                    stringCatalogs.append(ResourceFile(folderPath: folderPath, relativePath: file,
                                                       bundlePath: (file as NSString).lastPathComponent))
                } else if Self.isPlainResource(file) {
                    plainResources.append(ResourceFile(folderPath: folderPath, relativePath: file,
                                                       bundlePath: (file as NSString).lastPathComponent))
                }
            }
        }
        // The resources phase's own files: catalogs from a folder-owning target too, and
        // for a target that lists its files (B-77) everything else it copies.
        let resourcePaths = target.resourcePaths(forSDK: build.sdk)
        catalogs += resourcePaths.filter { $0.hasSuffix(".icon") || $0.hasSuffix(".xcassets") }
            .map { "\(build.projectFolder)/\($0)" }
        let listedResources = target.sourceFiles.isEmpty ? [] : resourcePaths
        for file in listedResources + target.borrowedFiles where !file.hasSuffix(".swift") {
            if let localized = Self.localizedBundlePath(file) {
                plainResources.append(ResourceFile(folderPath: build.projectFolder, relativePath: file, bundlePath: localized))
            } else if file.hasSuffix(".xcstrings") {
                stringCatalogs.append(ResourceFile(folderPath: build.projectFolder, relativePath: file,
                                                   bundlePath: (file as NSString).lastPathComponent))
            } else if Self.isPlainResource(file) {
                plainResources.append(ResourceFile(folderPath: build.projectFolder, relativePath: file,
                                                   bundlePath: (file as NSString).lastPathComponent))
            }
        }
        var partials: [String] = []
        if !catalogs.isEmpty {
            var assetLiterals = ["platform": build.sdk,
                                 "minimumDeploymentTarget": identity.deploymentTarget,
                                 "targetDevices": identity.targetDevices]
            if let appIcon = settings["ASSETCATALOG_COMPILER_APPICON_NAME"] {
                assetLiterals["appIcon"] = appIcon
            }
            let catalogWires = Array(Set(catalogs)).sorted().map { "        '\(($0 as NSString).lastPathComponent)': Folder(path: '\($0)').manifest" }
            blocks.append(
                "func assets_\(name)() =\n" +
                "    AssetCatalogCompiler(\n" +
                "        configuration: ['config': \(configuration(namespace: AssetCatalogCompilerConfiguration.settingNamespace, literals: assetLiterals))],\n" +
                "        catalogs: [\n" + catalogWires.joined(separator: ",\n") + "\n        ]\n" +
                "    )")
            bundleTrees.append("'assets': assets_\(name)().files")
            partials.append("'assets': assets_\(name)().partialInfoPlist")
        }

        for (index, catalog) in stringCatalogs.enumerated() {
            let fileName = (catalog.relativePath as NSString).lastPathComponent
            blocks.append(
                "func strings_\(name)_\(index)() =\n" +
                "    StringCatalogCompiler(\n" +
                "        configuration: ['config': \(configuration(namespace: StringCatalogCompilerConfiguration.settingNamespace, literals: [:]))],\n" +
                "        catalog: ['\(fileName)': StaticFile(path: '\(catalog.folderPath)/\(catalog.relativePath)').output]\n" +
                "    )")
            bundleTrees.append("'strings\(index)': strings_\(name)_\(index)().files")
        }

        // Plain resources: what is neither source nor compiled, flattened into the bundle
        // root as Xcode flattens a synchronized folder's files — a localized one under
        // its `.lproj`.
        for file in plainResources {
            products.append("product '\(layout.resource(in: bundlePath, at: file.bundlePath))' = "
                          + "StaticFile(path: \(Self.quoted("\(file.folderPath)/\(file.relativePath)"))).output")
        }

        // ── Info.plist ───────────────────────────────────────────────────────
        // The generated keys travel as one JSON dictionary: a plist key such as
        // `UISupportedInterfaceOrientations~ipad` is no formula identifier, and JSON
        // carries the arrays, dictionaries and booleans a plist has. The build settings a
        // `$(VAR)` may name are ordinary properties beside it.
        let keysJSON = try Self.json(identity.generatedInfoPlistKeys(settings: settings))
        let variables = ["PRODUCT_NAME": identity.productName,
                         "PRODUCT_BUNDLE_IDENTIFIER": identity.bundleIdentifier,
                         "PRODUCT_MODULE_NAME": identity.moduleName,
                         "TARGET_NAME": target.name]
        let base: String
        if let infoPlist = settings["INFOPLIST_FILE"], !infoPlist.isEmpty {
            base = "        base: ['base': StaticFile(path: \(Self.quoted("\(build.projectFolder)/\(infoPlist)"))).output],\n"
        } else {
            base = ""
        }
        let variableText = variables.sorted { $0.key < $1.key }
            .map { "\($0.key): \(Self.quoted($0.value))" }.joined(separator: ",\n        ")
        products.append(
            "product '\(layout.infoPlist(in: bundlePath))' =\n" +
            "    InfoPlistBuilder(\n" +
            "        keys: '\(keysJSON)',\n" +
            "        \(variableText),\n" +
            base +
            "        partials: [\(partials.joined(separator: ", "))]\n" +
            "    ).plist")

        // The resource bundles of the packages the target links, each under its own
        // `<Package>_<Target>.bundle/` (B-77): the package's formula carries them as one
        // tree per product, empty when no target has resources, so every product is named.
        for product in target.packageProducts.map(\.product).sorted() {
            bundleTrees.append("'\(FormulaIdentifier.bundlesFunc(forProduct: product))': \(FormulaIdentifier.bundlesFunc(forProduct: product))().files")
        }

        if !bundleTrees.isEmpty {
            products.append("product '\(layout.resourcesTree(in: bundlePath))' = TreeMerger(input: [\(bundleTrees.joined(separator: ", "))]).files")
        }

        return blocks + products
    }

    // MARK: - Helpers

    /// `Configuration(<literals>, base: ['settings': ConfigFilter(...)]).output`: the
    /// namespace's block of the project's `semel.config` laid over the machine's
    /// `semel.machine.config`, both beside the root (B-109), with the target's own values
    /// laid over that — the same shape the Swift converter emits.
    func configuration(namespace: String, literals: [String: String]) -> String {
        let rendered = literals.sorted { $0.key < $1.key }
            .map { "\($0.key): \(Self.quoted($0.value))" }
            .joined(separator: ", ")
        let settings = "ConfigMerger(base: ['machine': StaticFile(path: '\(build.root)/semel.machine.config').output], "
                     + "override: ['project': StaticFile(path: '\(build.root)/semel.config').output]).output"
        let selector = "ConfigFilter(prefix: '\(namespace)', input: ['config': \(settings)]).output"
        return "Configuration(\(rendered.isEmpty ? "" : rendered + ", ")base: ['settings': \(selector)]).output"
    }

    /// A formula string literal is delimited by either quote and has no escapes, so a
    /// value takes whichever quote it does not contain. One with both loses its
    /// apostrophes to the typographic kind — the one case the language cannot spell.
    static func quoted(_ value: String) -> String {
        if !value.contains("'") {
            return "'\(value)'"
        }
        if !value.contains("\"") {
            return "\"\(value)\""
        }
        return "'\(value.replacingOccurrences(of: "'", with: "\u{2019}"))'"
    }

    /// A JSON dictionary fit for a single-quoted literal: sorted, so the formula is the
    /// same on every run, and with every apostrophe written as `'`, which JSON
    /// allows and the formula lexer never sees as a quote.
    static func json(_ dictionary: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "\\u0027")
    }

    static func isInsideCatalog(_ relativePath: String) -> Bool {
        relativePath.contains(".xcassets/") || relativePath.contains(".icon/") || relativePath.contains(".lproj/")
    }

    /// Where a localized file lands in the bundle: `App/ar.lproj/Localizable.strings` is
    /// `ar.lproj/Localizable.strings`, the language folder kept and everything above it
    /// dropped, which is how a bundle finds its localizations. Nil for a file in no
    /// `.lproj`. A `.strings` file is copied as the text it is: a property list in either
    /// form is one to `Bundle`, and the text form is what the repository holds.
    static func localizedBundlePath(_ relativePath: String) -> String? {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let languageIndex = components.dropLast().lastIndex(where: { $0.hasSuffix(".lproj") }) else {
            return nil
        }
        return components[languageIndex...].joined(separator: "/")
    }

    /// A file Xcode copies into the bundle as it is. Sources, catalogs, plists that are
    /// inputs, and files inside compiled folders are not.
    static func isPlainResource(_ relativePath: String) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        guard !name.hasPrefix("."), !isInsideCatalog(relativePath) else {
            return false
        }
        let notResources: Set<String> = ["swift", "m", "mm", "c", "cpp", "h", "xcstrings", "xcassets", "icon",
                                         "entitlements", "xcconfig", "md", "plist", "intentdefinition", "xcdatamodeld"]
        let ext = (name as NSString).pathExtension.lowercased()
        return !notResources.contains(ext) && name != "Info.plist"
    }
}

/// A target's identity for one build: the values every part of its bundle agrees on.
struct TargetIdentity {
    let productName: String
    let moduleName: String
    let bundleIdentifier: String
    let bundleName: String
    let deploymentTarget: String
    /// The triple the compiler and linker build for.
    let target: String
    let targetDevices: String
    let languageMode: String?
    let packageType: String
    let sdk: String

    init(target: XcodeProject.Target, settings: XcodeBuildSettings, sdk: String) throws {
        productName = settings["PRODUCT_NAME"] ?? target.name
        moduleName = settings["PRODUCT_MODULE_NAME"] ?? FormulaIdentifier.sanitized(productName)
        bundleIdentifier = settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? "$(PRODUCT_BUNDLE_IDENTIFIER)"
        bundleName = target.productFileName
        self.sdk = sdk
        packageType = target.isExtension ? "XPC!" : "APPL"

        let deploymentKey = sdk.hasPrefix("macosx") ? "MACOSX_DEPLOYMENT_TARGET" : "IPHONEOS_DEPLOYMENT_TARGET"
        let deployment = settings[deploymentKey] ?? "17.0"
        deploymentTarget = deployment
        switch sdk {
        case "iphonesimulator": self.target = "arm64-apple-ios\(deployment)-simulator"
        case "iphoneos":        self.target = "arm64-apple-ios\(deployment)"
        default:                self.target = "arm64-apple-macosx\(deployment)"
        }

        // A macOS build is for the Mac whatever the device family says: a multiplatform
        // target keeps `1,2` for its iOS side, and actool for `macosx` takes only `mac`.
        let families = (settings["TARGETED_DEVICE_FAMILY"] ?? "1,2").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let devices = families.compactMap { family -> String? in
            switch family {
            case "1": return "iphone"
            case "2": return "ipad"
            case "6": return "mac"
            default: return nil
            }
        }
        if sdk.hasPrefix("macosx") {
            targetDevices = "mac"
        } else {
            targetDevices = devices.isEmpty ? "iphone,ipad" : devices.joined(separator: ",")
        }

        // `6.0` → `6`: the compiler takes the major mode; nothing declared is nothing.
        languageMode = settings["SWIFT_VERSION"].flatMap { $0.split(separator: ".").first.map(String.init) }
    }

    /// The plist Xcode generates when `GENERATE_INFOPLIST_FILE` is set — the keys a bundle
    /// cannot install without, and every `INFOPLIST_KEY_*` with its prefix stripped —
    /// typed as a plist types them, for the emitter to write as JSON.
    func generatedInfoPlistKeys(settings: XcodeBuildSettings) -> [String: Any] {
        var keys: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": productName,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": productName,
            "CFBundlePackageType": packageType,
            "CFBundleShortVersionString": settings["MARKETING_VERSION"] ?? "1.0",
            "CFBundleVersion": settings["CURRENT_PROJECT_VERSION"] ?? "1",
            "DTPlatformName": sdk,
        ]
        // The deployment target under the key each platform reads, and the device
        // families only where there are any: a Mac bundle has neither `UIDeviceFamily`
        // nor `MinimumOSVersion`, and a stray one is what LaunchServices refuses.
        switch sdk {
        case "iphonesimulator":
            keys["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
            keys["LSRequiresIPhoneOS"] = true
            keys["MinimumOSVersion"] = deploymentTarget
        case "iphoneos":
            keys["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
            keys["LSRequiresIPhoneOS"] = true
            keys["MinimumOSVersion"] = deploymentTarget
        default:
            keys["CFBundleSupportedPlatforms"] = ["MacOSX"]
            keys["LSMinimumSystemVersion"] = deploymentTarget
        }
        let families = targetDevices.split(separator: ",").compactMap { $0 == "iphone" ? 1 : $0 == "ipad" ? 2 : nil }
        if !families.isEmpty {
            keys["UIDeviceFamily"] = families
        }

        // Sorted: two settings can name one plist key — `UILaunchScreen_Generation` and a
        // literal `UILaunchScreen`, `UISupportedInterfaceOrientations_iPad` and
        // `UISupportedInterfaceOrientations~ipad` — and the last one written wins. A
        // Dictionary's iteration order is seeded per process, so an unsorted walk would
        // put a different value in the emitted formula from one run to the next (B-04).
        for (setting, value) in settings.values.sorted(by: { $0.key < $1.key })
        where setting.hasPrefix("INFOPLIST_KEY_") {
            let key = String(setting.dropFirst("INFOPLIST_KEY_".count))
            if key.hasSuffix("_Generation") {
                // `UILaunchScreen_Generation = YES` stands for an empty `UILaunchScreen`
                // dictionary; the scene manifest for its one required key.
                guard value == "YES" else { continue }
                let generated = String(key.dropLast("_Generation".count))
                keys[generated] = generated == "UIApplicationSceneManifest" ? ["UIApplicationSupportsMultipleScenes": true] : [:]
            } else if key.hasSuffix("_iPad") {
                let plistKey = String(key.dropLast("_iPad".count)) + "~ipad"
                keys[plistKey] = Self.typedValue(value, forKey: plistKey)
            } else {
                keys[key] = Self.typedValue(value, forKey: key)
            }
        }
        return keys
    }

    /// The keys whose setting is a space-separated list and whose plist value is an array.
    private static let arrayKeys: Set<String> = [
        "UISupportedInterfaceOrientations", "UISupportedInterfaceOrientations~ipad",
        "UIBackgroundModes", "UIRequiredDeviceCapabilities", "LSApplicationQueriesSchemes",
    ]

    /// `YES`/`NO` are booleans and a list key's words are an array; everything else is
    /// the string it is.
    private static func typedValue(_ value: String, forKey key: String) -> Any {
        if arrayKeys.contains(key) {
            return value.split(separator: " ").map(String.init)
        }
        if value == "YES" { return true }
        if value == "NO" { return false }
        return value
    }
}
