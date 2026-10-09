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
    /// Every local package of the project, relative to its folder: those it declares and
    /// those found in its synchronized folders (`LocalPackageSearch`).
    let localPackagePaths: [String]

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

        // Each place relative to the bundle, then under a bundle's own path.

        func executablePath(named name: String) -> String {
            isShallow ? name : "Contents/MacOS/\(name)"
        }

        var infoPlistPath: String {
            isShallow ? "Info.plist" : "Contents/Info.plist"
        }

        /// Beside the Info.plist, as Xcode writes it.
        var pkgInfoPath: String {
            isShallow ? "PkgInfo" : "Contents/PkgInfo"
        }

        /// The folder of the bundle a copy-files phase copies to, with the phase's own
        /// folder under it — Xcode's `dstSubfolderSpec` as the bundle lays it out — or nil
        /// for a destination outside the bundle: the products folder (16) but for a path
        /// naming a folder of the bundle by its setting, an absolute path (0), and the
        /// rest Xcode no longer offers.
        func folder(forCopyDestination destination: XcodeProject.CopyDestination) -> String? {
            let contents = isShallow ? "" : "Contents/"
            let base: String
            var path = destination.path
            switch destination.subfolderSpec {
            case 1:  base = ""
            case 6:  base = isShallow ? "" : "Contents/MacOS"
            case 7:  base = resourcesFolder
            case 10: base = frameworksFolder
            case 11: base = "\(contents)SharedFrameworks"
            case 12: base = "\(contents)SharedSupport"
            case 13: base = "\(contents)PlugIns"
            case 16:
                // The products folder, which is outside the bundle unless the path names one
                // of the bundle's own folders by its setting: CodeEdit's ExtensionKit
                // extension point goes to `$(EXTENSIONS_FOLDER_PATH)`, `Contents/Extensions`.
                guard let (variable, folder) = bundleFolderVariables(contents: contents).first(where: {
                    path == "$(\($0.0))" || path.hasPrefix("$(\($0.0))/")
                }) else {
                    return nil
                }
                base = folder
                path = String(path.dropFirst("$(\(variable))".count))
            default: return nil
            }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.isEmpty {
                return base
            }
            return base.isEmpty ? path : "\(base)/\(path)"
        }

        /// The settings Xcode names a bundle's folders by, relative to the products folder
        /// (`EXTENSIONS_FOLDER_PATH` is `CodeEdit.app/Contents/Extensions`), each with its
        /// folder in the bundle; the longer names first, as none is a prefix of another.
        func bundleFolderVariables(contents: String) -> [(String, String)] {
            [("UNLOCALIZED_RESOURCES_FOLDER_PATH", resourcesFolder),
             ("SHARED_FRAMEWORKS_FOLDER_PATH", "\(contents)SharedFrameworks"),
             ("SHARED_SUPPORT_FOLDER_PATH", "\(contents)SharedSupport"),
             ("EXECUTABLE_FOLDER_PATH", isShallow ? "" : "Contents/MacOS"),
             ("EXTENSIONS_FOLDER_PATH", "\(contents)Extensions"),
             ("FRAMEWORKS_FOLDER_PATH", frameworksFolder),
             ("CONTENTS_FOLDER_PATH", isShallow ? "" : "Contents"),
             ("PLUGINS_FOLDER_PATH", "\(contents)PlugIns")]
        }

        func resourcePath(at path: String) -> String {
            isShallow ? path : "Contents/Resources/\(path)"
        }

        /// Where the compiled resources are merged: the bundle's root for iOS.
        var resourcesFolder: String {
            isShallow ? "" : "Contents/Resources"
        }

        func plugInPath(named name: String) -> String {
            isShallow ? "PlugIns/\(name)" : "Contents/PlugIns/\(name)"
        }

        /// Where a binary target's frameworks are embedded (B-77).
        var frameworksFolder: String {
            isShallow ? "Frameworks" : "Contents/Frameworks"
        }

        func executable(in bundle: String, named name: String) -> String {
            "\(bundle)/\(executablePath(named: name))"
        }

        func infoPlist(in bundle: String) -> String {
            "\(bundle)/\(infoPlistPath)"
        }

        func resource(in bundle: String, at path: String) -> String {
            "\(bundle)/\(resourcePath(at: path))"
        }

        /// The tree product the compiled resources are merged into, with its trailing slash.
        func resourcesTree(in bundle: String) -> String {
            Self.treeProduct(in: bundle, folder: resourcesFolder)
        }

        func plugIn(in bundle: String, named name: String) -> String {
            "\(bundle)/\(plugInPath(named: name))"
        }

        /// The tree product a binary target's frameworks are embedded under, with its
        /// trailing slash (B-77).
        func frameworksTree(in bundle: String) -> String {
            Self.treeProduct(in: bundle, folder: frameworksFolder)
        }

        /// `Hello.app/` for the root, `Hello.app/Frameworks/` for a folder in it.
        static func treeProduct(in bundle: String, folder: String) -> String {
            folder.isEmpty ? "\(bundle)/" : "\(bundle)/\(folder)/"
        }

        /// A Mac bundle is assembled as one tree and signed (B-77); an iOS one is left as
        /// the products it is made of, unsigned — the simulator runs an unsigned bundle,
        /// and a device build would want a real identity, which Semel does not sign with.
        var isSigned: Bool {
            !isShallow
        }

        /// Where the executable finds those frameworks at run time: the folder above,
        /// relative to itself, as Xcode's app templates set `LD_RUNPATH_SEARCH_PATHS`.
        var frameworksRunpath: String {
            isShallow ? "@executable_path/Frameworks" : "@executable_path/../Frameworks"
        }
    }

    var layout: BundleLayout { BundleLayout(sdk: build.sdk) }

    /// The Swift nodes a target is built through. Named rather than imported: this
    /// package does not depend on SemelSwift, and a formula names a node by type name.
    static let swiftCompilerNamespace = derivedSettingNamespace(forTypeName: "SwiftCompiler")
    static let swiftLinkerNamespace   = derivedSettingNamespace(forTypeName: "SwiftLinker")

    // MARK: - Whole project

    /// The formula for `application`, the one the build's platform picked: its bundle, with
    /// every package it and its extensions link included, and each extension the app
    /// embeds as a bundle of its own under the app's `PlugIns/`.
    func formula(for application: XcodeProject.Target,
                 settings: (XcodeProject.Target) throws -> XcodeBuildSettings,
                 listing: (String) -> FolderListing?) throws -> String {
        let extensions = Array(project.bundleTargets(of: application).dropFirst())
        var blocks: [String] = ["// Written by XcodeProjectConverter: \(application.name) and \(extensions.count) embedded extension(s)."]
        blocks += includes(for: [application] + extensions)
        let applicationSettings = try settings(application)
        let applicationBundle = try TargetIdentity(target: application, settings: applicationSettings, sdk: build.sdk).bundleName

        guard layout.isSigned else {
            blocks += try bundle(for: application, settings: applicationSettings, listing: listing).products(in: applicationBundle)
            for anExtension in extensions {
                blocks += try bundle(for: anExtension, settings: try settings(anExtension), listing: listing)
                    .products(in: layout.plugIn(in: applicationBundle, named: anExtension.productFileName))
            }
            return blocks.joined(separator: "\n\n") + "\n"
        }

        // A Mac bundle is one tree, signed once it is whole: each extension is assembled
        // and signed with its own entitlements, then embedded under the app's `PlugIns/`,
        // and the app is signed over all of it, as Xcode signs what it has embedded.
        var plugIns: [BundleParts.Part] = []
        for anExtension in extensions {
            let extensionSettings = try settings(anExtension)
            let parts = try bundle(for: anExtension, settings: extensionSettings, listing: listing)
            let signed = try signedBundle(parts, for: anExtension, settings: extensionSettings)
            blocks += signed.blocks
            plugIns.append(.tree(folder: layout.plugInPath(named: anExtension.productFileName),
                                 inputs: "\(Self.quoted(anExtension.productFileName)): \(signed.expression)"))
        }
        var parts = try bundle(for: application, settings: applicationSettings, listing: listing)
        parts.parts += plugIns
        let signed = try signedBundle(parts, for: application, settings: applicationSettings)
        blocks += signed.blocks
        blocks.append("product \(Self.quoted(applicationBundle + "/")) = \(signed.expression)")
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Signing (B-77)

    /// The node a Mac bundle is signed by. Named rather than referenced, as the formula
    /// names every node.
    static let codeSignerNamespace = CodeSignerConfiguration.settingNamespace

    /// A bundle's parts as one tree, `bundle_<Target>()`, and that tree signed,
    /// `signed_<Target>()` — ad-hoc, with the entitlements `CODE_SIGN_ENTITLEMENTS` names,
    /// their `$(VAR)`s resolved over the target's settings as Xcode resolves them. The
    /// expression is what the bundle is once signed: the signer's tree, or the bundle's
    /// own when the target sets `CODE_SIGNING_ALLOWED = NO`.
    ///
    /// `ENABLE_HARDENED_RUNTIME = YES` signs with the hardened runtime, `-o runtime`, as
    /// Xcode does: NetNewsWire's Release app, and both its Mac extensions in either
    /// configuration.
    ///
    /// `CODE_SIGN_IDENTITY` is read and, when it names a certificate (`Apple Development`,
    /// NetNewsWire's `Mac Developer`), said in the formula and signed ad-hoc anyway: Semel
    /// signs with no certificate, and an ad-hoc signature is what lets the app run here.
    /// The setting a real identity would take is the signer's `identity`.
    ///
    /// The entitlements are the file's and, laid over them, what the target's sandbox and
    /// hardened-runtime settings stand for (`entitlements(fromSettings:)`).
    func signedBundle(_ parts: BundleParts, for target: XcodeProject.Target,
                      settings: XcodeBuildSettings) throws -> (blocks: [String], expression: String) {
        let name = FormulaIdentifier.sanitized(target.name)
        var blocks = parts.blocks
        blocks.append(parts.tree(named: "bundle_\(name)"))
        guard settings["CODE_SIGNING_ALLOWED"] != "NO" else {
            return (blocks, "bundle_\(name)().files")
        }

        var signer = ""
        let identity = settings["CODE_SIGN_IDENTITY"] ?? ""
        if !identity.isEmpty, identity != CodeSignerConfiguration.adHocIdentity {
            signer += "// CODE_SIGN_IDENTITY is \(Self.quoted(identity)): signed ad-hoc, as Semel signs with no certificate (B-77).\n"
        }
        // The hardened runtime is a fact about the bundle, as its entitlements are: a
        // literal, which a config file cannot turn off.
        var signerLiterals = ["identity": CodeSignerConfiguration.adHocIdentity]
        if settings["ENABLE_HARDENED_RUNTIME"] == "YES" {
            signerLiterals[CodeSignerConfiguration.hardenedRuntimeKey] = "true"
        }
        let signerConfiguration = configuration(namespace: Self.codeSignerNamespace, literals: signerLiterals)
        signer += "func signed_\(name)() =\n" +
                  "    CodeSigner(\n" +
                  "        configuration: ['config': \(signerConfiguration)],\n" +
                  "        bundle: [\(Self.quoted(target.productFileName)): bundle_\(name)().files]"
        let entitlementsFile = settings["CODE_SIGN_ENTITLEMENTS"].map(Self.projectRelativePath).flatMap { $0.isEmpty ? nil : $0 }
        let entitlementsFromSettings = Self.entitlements(fromSettings: settings)
        if entitlementsFile != nil || !entitlementsFromSettings.isEmpty {
            signer += ",\n        entitlements: ['entitlements': InfoPlistBuilder(\n"
            if !entitlementsFromSettings.isEmpty {
                signer += "            \(InfoPlistBuilder.keysProperty): '\(try Self.json(entitlementsFromSettings))',\n"
            }
            signer += "            \(InfoPlistBuilder.buildSettingsProperty): '\(parts.buildSettingsJSON)'"
            if let entitlementsFile {
                signer += ",\n            base: ['base': StaticFile(path: \(Self.quoted("\(build.projectFolder)/\(entitlementsFile)"))).output]"
            }
            signer += "\n        ).plist]"
        }
        signer += "\n    )"
        blocks.append(signer)
        return (blocks, "signed_\(name)().files")
    }

    /// The Boolean settings Xcode's Signing & Capabilities editor writes for the sandbox
    /// and the hardened runtime (`CoreBuildSystem.xcspec`, "App Sandbox & Hardened
    /// Runtime"), each with the entitlement Xcode signs with when it is `YES`.
    static let entitlementFlags: [String: String] = [
        "ENABLE_APP_SANDBOX": "com.apple.security.app-sandbox",
        "AUTOMATION_APPLE_EVENTS": "com.apple.security.automation.apple-events",
        "RUNTIME_EXCEPTION_ALLOW_DYLD_ENVIRONMENT_VARIABLES": "com.apple.security.cs.allow-dyld-environment-variables",
        "RUNTIME_EXCEPTION_ALLOW_JIT": "com.apple.security.cs.allow-jit",
        "RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY": "com.apple.security.cs.allow-unsigned-executable-memory",
        "RUNTIME_EXCEPTION_DEBUGGING_TOOL": "com.apple.security.cs.debugger",
        "RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION": "com.apple.security.cs.disable-executable-page-protection",
        "RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION": "com.apple.security.cs.disable-library-validation",
        "ENABLE_INCOMING_NETWORK_CONNECTIONS": "com.apple.security.network.server",
        "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "com.apple.security.network.client",
        "ENABLE_RESOURCE_ACCESS_CAMERA": "com.apple.security.device.camera",
        "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT": "com.apple.security.device.audio-input",
        "ENABLE_RESOURCE_ACCESS_USB": "com.apple.security.device.usb",
        "ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY": "com.apple.security.personal-information.photos-library",
        "ENABLE_RESOURCE_ACCESS_PRINTING": "com.apple.security.print",
        "ENABLE_RESOURCE_ACCESS_BLUETOOTH": "com.apple.security.device.bluetooth",
        "ENABLE_RESOURCE_ACCESS_CONTACTS": "com.apple.security.personal-information.addressbook",
        "ENABLE_RESOURCE_ACCESS_LOCATION": "com.apple.security.personal-information.location",
        "ENABLE_RESOURCE_ACCESS_CALENDARS": "com.apple.security.personal-information.calendars",
    ]

    /// The ones that take `readonly` or `readwrite`, each the entitlement's stem, which the
    /// value completes: `ENABLE_USER_SELECTED_FILES = readwrite` is
    /// `com.apple.security.files.user-selected.read-write`.
    static let entitlementAccessLevels: [String: String] = [
        "ENABLE_USER_SELECTED_FILES": "com.apple.security.files.user-selected",
        "ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER": "com.apple.security.files.downloads",
        "ENABLE_FILE_ACCESS_PICTURE_FOLDER": "com.apple.security.assets.pictures",
        "ENABLE_FILE_ACCESS_MUSIC_FOLDER": "com.apple.security.assets.music",
        "ENABLE_FILE_ACCESS_MOVIES_FOLDER": "com.apple.security.assets.movies",
    ]

    /// What a target's sandbox and hardened-runtime settings add to its entitlements, as
    /// Xcode adds them when it signs: CodeEdit's `RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION
    /// = YES` is the entitlement that lets its app, signed with the hardened runtime, load
    /// Sparkle, whose signature is not its own (B-77). Without it the process is killed at
    /// launch: `Library not loaded … different Team IDs`.
    static func entitlements(fromSettings settings: XcodeBuildSettings) -> [String: Any] {
        var entitlements: [String: Any] = [:]
        for (setting, entitlement) in entitlementFlags.sorted(by: { $0.key < $1.key }) where settings[setting] == "YES" {
            entitlements[entitlement] = true
        }
        for (setting, stem) in entitlementAccessLevels.sorted(by: { $0.key < $1.key }) {
            switch settings[setting] {
            case "readonly":  entitlements["\(stem).read-only"] = true
            case "readwrite": entitlements["\(stem).read-write"] = true
            default:          break
            }
        }
        return entitlements
    }

    // MARK: - Packages

    /// One include per package the target links: the package's formula brings the
    /// `modules_P()` / `objects_P()` funcs the target compiles and links against. Every
    /// local package is included, as Xcode puts every one in the workspace: a product
    /// dependency names no package, and its product is found by name among the funcs the
    /// included formulas define — `RSCoreResources` in the `RSCore` package's. A remote
    /// package is where the vendoring rule puts it, `Dependencies/<repository name>`.
    func includes(for targets: [XcodeProject.Target]) -> [String] {
        var folders: [String] = localPackagePaths.compactMap {
            XcodeProjectConverter.inputPath(of: $0, in: build.projectFolder)
        }
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
        DependencyLock.folderName(forRepositoryURL: urlString)
    }

    // MARK: - One target's bundle

    /// What one target's bundle is made of: the funcs its parts are built through, and
    /// each part at its place in the bundle. Where the bundle is does not enter into it —
    /// `products(in:)` names the parts as products under a path, `tree(named:)` assembles
    /// them into one tree to be signed.
    struct BundleParts {
        enum Part {
            /// A file at its path in the bundle, and what gives it, as written after a
            /// product's `=`: on the same line (` StaticFile(…).output`) or on the next.
            case file(path: String, expression: String)
            /// Trees merged under a folder of the bundle — `""` for its root — as the
            /// text of the merger's `input:` list.
            case tree(folder: String, inputs: String)
        }

        var blocks: [String] = []
        var parts: [Part] = []
        /// The target's evaluated settings as JSON, the variables its Info.plist and its
        /// entitlements may name.
        var buildSettingsJSON = "{}"

        /// The parts with every tree for one folder merged into the first: a folder a
        /// copy-files phase copies into `Contents/Resources` joins the resources' tree, where
        /// two trees under one folder would be two products of one name.
        static func mergingTrees(_ parts: [Part]) -> [Part] {
            var merged: [Part] = []
            for part in parts {
                guard case .tree(let folder, let inputs) = part,
                      let index = merged.firstIndex(where: { if case .tree(folder, _) = $0 { return true } else { return false } }),
                      case .tree(_, let earlier) = merged[index] else {
                    merged.append(part)
                    continue
                }
                merged[index] = .tree(folder: folder, inputs: earlier + ", " + inputs)
            }
            return merged
        }

        /// The funcs, then each part a product of its own under `bundle`: the bundle as
        /// it is exported, unsigned.
        func products(in bundle: String) -> [String] {
            blocks + parts.map { part in
                switch part {
                case .file(let path, let expression):
                    return "product \(XcodeFormulaEmitter.quoted("\(bundle)/\(path)")) =\(expression)"
                case .tree(let folder, let inputs):
                    return "product \(XcodeFormulaEmitter.quoted(BundleLayout.treeProduct(in: bundle, folder: folder))) = "
                         + "TreeMerger(input: [\(inputs)]).files"
                }
            }
        }

        /// The parts as one tree, `func <name>() = TreeMerger(…).files`: the files in a
        /// `TreeBuilder`, each keeping the mode its source gives it, and each tree merged
        /// under its folder.
        func tree(named name: String) -> String {
            var files: [String] = []
            var trees: [String] = []
            for part in parts {
                switch part {
                case .file(let path, let expression):
                    let expression = expression.drop { $0 == " " || $0 == "\n" }.replacingOccurrences(of: "\n", with: "\n    ")
                    files.append("        \(XcodeFormulaEmitter.quoted(path)): \(expression)")
                case .tree(let folder, let inputs):
                    let under = folder.isEmpty ? "" : "under: \(XcodeFormulaEmitter.quoted(folder)), "
                    trees.append("    \(XcodeFormulaEmitter.quoted(folder.isEmpty ? "root" : folder)): TreeMerger(\(under)input: [\(inputs)]).files")
                }
            }
            let fileTree = files.isEmpty ? [] : ["    'files': TreeBuilder(input: [\n" + files.joined(separator: ",\n") + "\n    ]).files"]
            return "func \(name)() = TreeMerger(input: [\n" + (fileTree + trees).joined(separator: ",\n") + "\n]).files"
        }
    }

    /// One target's bundle: `Ice Cubes.app`, or `Share.appex`, which the app embeds under
    /// its `PlugIns/`.
    func bundle(for target: XcodeProject.Target,
                settings: XcodeBuildSettings,
                listing: (String) -> FolderListing?) throws -> BundleParts {
        let identity = try TargetIdentity(target: target, settings: settings, sdk: build.sdk)
        let name = FormulaIdentifier.sanitized(target.name)
        var blocks: [String] = []
        var bundleTrees: [String] = []
        var products: [BundleParts.Part] = []

        // ── sources ──────────────────────────────────────────────────────────
        // Every synchronized folder of the target is a source root: the compiler takes
        // them all on its folder port and walks each. Exceptions are relative to their
        // own folder, which is how the compiler reads an excluded path too. A target with
        // no folder of its own compiles what it borrows, and nothing else.
        // A target lists its files through groups (B-77) or owns synchronized folders;
        // either way it has to have a Swift source somewhere. A listed C-family source is
        // compiled through clang beside it; a documentation catalog gives nothing a build
        // uses and is passed over; any other listed file that is not Swift is a build this
        // converter cannot write yet, said rather than dropped.
        let everyListedSource = target.sourcePaths(forSDK: build.sdk).filter { !Self.isDocumentationOnly($0) }
        let listedSources  = everyListedSource.filter { $0.hasSuffix(".swift") }
        let listedCFamily  = everyListedSource.filter(Self.isCFamilySource)
        let listedOther    = everyListedSource.filter { !$0.hasSuffix(".swift") && !Self.isCFamilySource($0) }
        guard listedOther.isEmpty else {
            throw XcodeProjectError.unsupportedSources(target: target.name, files: listedOther)
        }
        // A target that runs plugins and has no source of its own — none in its folders that
        // its exceptions keep, none listed, none borrowed — would compile only what they
        // generate, and no plugin is run (B-77): said with the plugins, rather than handing
        // the compiler nothing.
        if !target.plugins.isEmpty {
            let isSource = { (path: String) in path.hasSuffix(".swift") || Self.isCFamilySource(path) }
            let hasFolderSource = target.synchronizedFolders.contains { folder in
                (listing("\(build.projectFolder)/\(folder.path)") ?? FolderListing()).files.contains { file in
                    !folder.excludes(file) && isSource(file)
                }
            }
            guard hasFolderSource || !listedSources.isEmpty || !listedCFamily.isEmpty
                    || target.borrowedFiles.contains(where: isSource) else {
                throw XcodeProjectError.sourcesOnlyFromPlugins(target: target.name, plugins: target.plugins)
            }
        }
        guard !target.synchronizedFolders.isEmpty || !listedSources.isEmpty
                || target.borrowedFiles.contains(where: { $0.hasSuffix(".swift") }) else {
            throw XcodeProjectError.targetHasNoSources(target.name)
        }
        let sourceFolders = target.synchronizedFolders.map { ($0, "\(build.projectFolder)/\($0.path)") }
        let folderWires = sourceFolders.enumerated().map { index, folder in
            "        'folder\(index)': Folder(path: '\(folder.1)').manifest"
        }
        let exceptions = sourceFolders.flatMap { folder, folderPath in
            folder.excludedPaths(folders: (listing(folderPath) ?? FolderListing()).folders)
        }.sorted()
        let moduleTrees = target.packageProducts.map(\.product).sorted().map {
            "        '\($0)': \(FormulaIdentifier.modulesFunc(forProduct: $0))().files"
        }
        let objectTrees = target.packageProducts.map(\.product).sorted().map {
            "        '\($0)': \(FormulaIdentifier.objectsFunc(forProduct: $0))().files"
        }
        // What each product's objects need from the linker — its targets' frameworks and
        // libraries, the C++ runtime — which the linker takes the union of (B-55).
        var linkRequirements = target.packageProducts.map(\.product).sorted().map {
            "        '\($0)': \(FormulaIdentifier.linkRequirementsFunc(forProduct: $0))().output"
        }
        // Each product's binary targets' frameworks, which the target compiles and links
        // against (B-77), and the dynamic ones among them, which the bundle embeds — a static
        // framework is linked in and loaded from nowhere (B-77 item 12); both empty for a
        // product that reaches none.
        let frameworkTrees = target.packageProducts.map(\.product).sorted().map {
            "        '\($0)': \(FormulaIdentifier.frameworksFunc(forProduct: $0))().files"
        }
        let embeddedFrameworkTrees = target.packageProducts.map(\.product).sorted().map {
            "        '\($0)': \(FormulaIdentifier.embeddedFrameworksFunc(forProduct: $0))().files"
        }
        var compilerLiterals = ["moduleName": identity.moduleName,
                                "target": identity.target]
        if !exceptions.isEmpty {
            compilerLiterals["excludedPaths"] = exceptions.joined(separator: ",")
        }
        if let languageMode = identity.languageMode {
            compilerLiterals["languageMode"] = languageMode
        }
        // The target's own Swift settings — its conditions, the features and checking its
        // language settings choose, warnings as errors, `OTHER_SWIFT_FLAGS` — as the
        // literals a package target's `swiftSettings` become: facts about the target a
        // config file must not change.
        compilerLiterals.merge(try XcodeSwiftSettings(settings: settings, languageMode: identity.languageMode).literals()) { _, swift in swift }
        var compilerArguments: [String] = []
        if target.isExtension {
            compilerArguments.append("-application-extension")
        }
        let objectiveC = objectiveCSources(of: target, identity: identity, in: sourceFolders, settings: settings,
                                           listing: listing, listed: listedCFamily)
        // The importer parses the bridging header as the target's C-family sources are
        // preprocessed, so it is told the same macros, as Xcode tells it.
        if objectiveC.bridgingHeader != nil {
            for definition in objectiveC.defines {
                compilerArguments += ["-Xcc", "-D\(definition)"]
            }
        }
        if !compilerArguments.isEmpty {
            compilerLiterals["arguments"] = compilerArguments.joined(separator: ",")
        }
        // What the target takes from another target's folder: sources one by one on the
        // compiler, resources with the target's own. A listed file goes the same way,
        // keyed by its whole path: two groups may each hold a `View.swift`, and the key
        // is where the compiler puts the file.
        var borrowedSources = target.borrowedFiles.filter { $0.hasSuffix(".swift") }.map {
            "        \(Self.quoted(($0 as NSString).lastPathComponent)): StaticFile(path: \(Self.quoted("\(build.projectFolder)/\($0)"))).output"
        } + listedSources.map {
            "        \(Self.quoted($0)): StaticFile(path: \(Self.quoted("\(build.projectFolder)/\($0)"))).output"
        }
        // The bridging header by itself, and the target's headers as the tree it imports
        // from — the shape a package's C target hands a Swift importer, `headers<Target>()`.
        var bridgingWires = ""
        if let bridgingHeader = objectiveC.bridgingHeader {
            bridgingWires += ",\n        bridgingHeader: [\(Self.quoted(bridgingHeader)): "
                           + "StaticFile(path: \(Self.quoted("\(build.projectFolder)/\(bridgingHeader)"))).output]"
            let headers = objectiveC.headers.filter { $0.key != bridgingHeader }
            if !headers.isEmpty {
                blocks.append(
                    "func headers_\(name)() =\n" +
                    "    TreeBuilder(input: [\n" +
                    headers.map { "        \(Self.quoted($0.key)): StaticFile(path: \(Self.quoted($0.path))).output" }.joined(separator: ",\n") +
                    "\n    ]).files")
                bridgingWires += ",\n        headerTrees: [\(Self.quoted(target.name)): headers_\(name)().files]"
            }
        }

        // ── resources ────────────────────────────────────────────────────────
        // Each folder's listing, with the paths of what it holds, less its exceptions,
        // each file placed by `resource(at:)`: flat, as Xcode flattens a folder's files,
        // except a localized file, which keeps its `<lang>.lproj/`, and a string catalog,
        // which its compiler places. A folder Xcode takes as one item is copied whole and
        // its files are not walked for; a catalog is compiled. The target's own Info.plist
        // is the plist's base, not a resource: Xcode copies it too when no exception
        // leaves it out, with a warning on the Mac ("The Copy Bundle Resources build phase
        // contains this target's Info.plist file") and, on iOS, failing on the two files at
        // one place ("Multiple commands produce …/Info.plist").
        struct ResourceFile { let folderPath: String; let relativePath: String; let bundlePath: String }
        var catalogs: [String] = []
        var stringCatalogs: [ResourceFile] = []
        var interfaceDocuments: [ResourceFile] = []
        var plainResources: [ResourceFile] = []
        var wholeFolders: [ResourceFile] = []
        let ownInfoPlist = settings["INFOPLIST_FILE"].map(Self.projectRelativePath)
        func add(_ relativePath: String, in folderPath: String, listedInResourcesPhase: Bool = false) {
            switch Self.resource(at: relativePath, listedInResourcesPhase: listedInResourcesPhase) {
            case .stringCatalog:
                stringCatalogs.append(ResourceFile(folderPath: folderPath, relativePath: relativePath,
                                                   bundlePath: (relativePath as NSString).lastPathComponent))
            case .interfaceBuilder(let bundlePath):
                interfaceDocuments.append(ResourceFile(folderPath: folderPath, relativePath: relativePath, bundlePath: bundlePath))
            case .copied(let bundlePath):
                plainResources.append(ResourceFile(folderPath: folderPath, relativePath: relativePath, bundlePath: bundlePath))
            case .ignored:
                break
            }
        }
        for (folder, folderPath) in sourceFolders {
            let contents = listing(folderPath) ?? FolderListing()
            // Sorted, so a folder comes before what is in it and one taken whole hides
            // everything under it.
            var itemFolders: [String] = []
            for subfolder in contents.folders.sorted() where !folder.excludes(subfolder) {
                guard !itemFolders.contains(where: { subfolder.hasPrefix($0 + "/") }) else {
                    continue
                }
                switch Self.folderRole(at: subfolder, explicitFolders: folder.explicitFolders) {
                case .group:
                    continue
                case .catalog:
                    catalogs.append("\(folderPath)/\(subfolder)")
                case .copiedWhole(let bundlePath):
                    wholeFolders.append(ResourceFile(folderPath: folderPath, relativePath: subfolder, bundlePath: bundlePath))
                case .notBuilt:
                    break
                }
                itemFolders.append(subfolder)
            }
            for file in contents.files.sorted() where !folder.excludes(file) && "\(folder.path)/\(file)" != ownInfoPlist {
                guard !itemFolders.contains(where: { file.hasPrefix($0 + "/") }) else {
                    continue
                }
                add(file, in: folderPath)
            }
        }
        // The resources phase's own files, whatever kind of target lists them: catalogs,
        // folder references copied whole, and every other file. One inside the target's
        // own folders is already among that folder's files.
        let resourceFiles = target.resourceFiles.filter { $0.isBuilt(forSDK: build.sdk) && $0.path != ownInfoPlist }
        catalogs += resourceFiles.map(\.path).filter { Self.folderRole(at: $0) == .catalog }
            .map { "\(build.projectFolder)/\($0)" }
        // A catalog another target's folder lends is compiled for the borrowing target as
        // one of its own would be: NetNewsWire's iOS Share extension borrows the app's
        // `iOS/Resources/Assets.xcassets` (B-77).
        catalogs += target.borrowedFiles.filter { Self.folderRole(at: $0) == .catalog }
            .map { "\(build.projectFolder)/\($0)" }
        let folderReferences = resourceFiles.filter(\.isFolderReference).map(\.path)
        let listedResources = resourceFiles.filter { !$0.isFolderReference }.map(\.path).filter { path in
            !target.synchronizedFolders.contains { path.hasPrefix($0.path + "/") } && Self.folderRole(at: path) == .group
        }
        for file in listedResources {
            add(file, in: build.projectFolder, listedInResourcesPhase: true)
        }
        // What the target borrows from another target's folder follows that folder's rule.
        for file in target.borrowedFiles where file != ownInfoPlist {
            switch Self.folderRole(at: file) {
            case .group:
                add(file, in: build.projectFolder)
            case .copiedWhole(let bundlePath):
                wholeFolders.append(ResourceFile(folderPath: build.projectFolder, relativePath: file, bundlePath: bundlePath))
            case .catalog, .notBuilt:
                break
            }
        }
        // A localized resource borrowed as `/Localized/…` is the files in the lending
        // folder it names, which the lending folder's listing holds.
        for borrowed in target.borrowedLocalizedResources {
            let folderPath = "\(build.projectFolder)/\(borrowed.folder)"
            for file in (listing(folderPath) ?? FolderListing()).files.sorted() where borrowed.exception.matches(file) {
                add(file, in: folderPath)
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
            let symbols = AssetSymbolSettings(settings: settings, bundleIdentifier: identity.bundleIdentifier)
            if let symbols {
                assetLiterals.merge(symbols.literals) { _, symbol in symbol }
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
            // The Swift actool writes for the catalogs' colors and images, compiled with the
            // target's sources as Xcode compiles its `GeneratedAssetSymbols.swift` (B-77
            // item 10): `Color.amber`, `ImageResource.gitHubIcon`.
            if symbols != nil {
                borrowedSources.append("        \(Self.quoted(AssetCatalogCompiler.swiftAssetSymbolsFile)): "
                                       + "assets_\(name)().\(AssetCatalogCompiler.swiftAssetSymbols)")
            }
        }

        blocks.append(
            "func compiler_\(name)() =\n" +
            "    SwiftCompiler(\n" +
            "        configuration: ['config': \(configuration(namespace: Self.swiftCompilerNamespace, literals: compilerLiterals))]" +
            (folderWires.isEmpty ? "" : ",\n        inputFolder: [\n" + folderWires.joined(separator: ",\n") + "\n        ]") +
            (borrowedSources.isEmpty ? "" : ",\n        extraSourceFiles: [\n" + borrowedSources.joined(separator: ",\n") + "\n        ]") +
            (moduleTrees.isEmpty ? "" : ",\n        moduleTrees: [\n" + moduleTrees.joined(separator: ",\n") + "\n        ]") +
            (frameworkTrees.isEmpty ? "" : ",\n        frameworkTrees: [\n" + frameworkTrees.joined(separator: ",\n") + "\n        ]") +
            bridgingWires +
            "\n    )")

        // The target's C-family sources, each preprocessed and compiled by itself as a
        // package's C target's are, over the target's folders as header folders — what
        // Xcode's header map lets a quoted import find — and linked into the executable.
        var objectEntries = ["'\(identity.moduleName).o': compiler_\(name)().object"]
        if !objectiveC.sources.isEmpty {
            let headerFolderWires = objectiveC.headerFolders.map {
                "            \(Self.quoted($0)): Folder(path: \(Self.quoted($0))).manifest"
            }
            func preprocessor(named function: String, literals: [String: String]) -> String {
                "func \(function)(path) =\n" +
                "    ClangPreprocessor(\n" +
                "        configuration: ['config': \(configuration(namespace: Self.clangPreprocessorNamespace, literals: literals))],\n" +
                "        input: [path: StaticFile(path: path)],\n" +
                "        headerFolders: [\n" + headerFolderWires.joined(separator: ",\n") + "\n        ]\n" +
                "    )"
            }
            blocks.append(preprocessor(named: "preprocess_\(name)", literals: objectiveC.preprocessorLiterals))
            let compilerConfiguration = configuration(namespace: Self.clangCompilerNamespace, literals: objectiveC.compilerLiterals)
            // A source with flags of its own (`additionalCompilerFlagsByRelativePath`) is
            // preprocessed and compiled by nodes of its own, the flags after the target's,
            // as Xcode passes them after `OTHER_CFLAGS`.
            var flaggedIndex = 0
            for source in objectiveC.sources {
                var preprocessorFunction = "preprocess_\(name)"
                var sourceCompilerConfiguration = compilerConfiguration
                if let fileFlags = objectiveC.fileFlags[source] {
                    preprocessorFunction = "preprocess_\(name)_\(flaggedIndex)"
                    flaggedIndex += 1
                    blocks.append(preprocessor(named: preprocessorFunction,
                                               literals: objectiveC.preprocessorLiterals(adding: fileFlags)))
                    sourceCompilerConfiguration = configuration(namespace: Self.clangCompilerNamespace,
                                                                literals: objectiveC.compilerLiterals(adding: fileFlags))
                }
                objectEntries.append("\(Self.quoted(source + ".o")): ClangCompiler(configuration: ['config': \(sourceCompilerConfiguration)], "
                                     + "input: [\(Self.quoted(source + ".p")): \(preprocessorFunction)(path: \(Self.quoted(source)))]).output")
            }
        }

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
        // Passed as an `-rpath` only when the frameworks trees hold a framework.
        if !frameworkTrees.isEmpty {
            linkerLiterals["frameworksRunpath"] = layout.frameworksRunpath
        }
        // C++ or Objective-C++ among the target's own sources brings the C++ runtime, as a
        // package's C++ target does (B-55).
        if objectiveC.compilesCxx {
            linkRequirements.append("        \(Self.quoted("\(target.name) C++")): SettingsLiteral(\(LinkRequirements.cxxRuntimeKey): 'true').output")
        }
        let linkerInput = objectEntries.count == 1
            ? "[\(objectEntries[0])]"
            : "[\n" + objectEntries.map { "            \($0)" }.joined(separator: ",\n") + "\n        ]"
        products.append(.file(
            path: layout.executablePath(named: identity.productName),
            expression: "\n" +
            "    SwiftLinker(\n" +
            "        configuration: ['config': \(configuration(namespace: Self.swiftLinkerNamespace, literals: linkerLiterals))],\n" +
            "        input: \(linkerInput)" +
            (objectTrees.isEmpty ? "" : ",\n        objectTrees: [\n" + objectTrees.joined(separator: ",\n") + "\n        ]") +
            (linkRequirements.isEmpty ? "" : ",\n        linkRequirements: [\n" + linkRequirements.joined(separator: ",\n") + "\n        ]") +
            (frameworkTrees.isEmpty ? "" : ",\n        frameworkTrees: [\n" + frameworkTrees.joined(separator: ",\n") + "\n        ]") +
            "\n    ).output"))
        // The dynamic ones embedded where the executable's runpath finds them, and signed
        // with the bundle on the Mac.
        if !embeddedFrameworkTrees.isEmpty {
            products.append(.tree(folder: layout.frameworksFolder, inputs: "\n" + embeddedFrameworkTrees.joined(separator: ",\n") + "\n    "))
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

        // Interface Builder documents, each compiled by ibtool to what the app loads at the
        // place the document has in the bundle: `Base.lproj/MainMenu.xib` becomes
        // `Base.lproj/MainMenu.nib`, a storyboard a `.storyboardc` folder. The wire's key is
        // that place, which the compiler writes its tree under.
        if !interfaceDocuments.isEmpty {
            let interfaceLiterals = ["minimumDeploymentTarget": identity.deploymentTarget,
                                     "targetDevices": identity.targetDevices,
                                     "module": identity.moduleName]
            let interfaceConfiguration = configuration(namespace: IBToolCompilerConfiguration.settingNamespace, literals: interfaceLiterals)
            for (index, document) in interfaceDocuments.enumerated() {
                blocks.append(
                    "func interface_\(name)_\(index)() =\n" +
                    "    IBToolCompiler(\n" +
                    "        configuration: ['config': \(interfaceConfiguration)],\n" +
                    "        document: [\(Self.quoted(document.bundlePath)): "
                    + "StaticFile(path: \(Self.quoted("\(document.folderPath)/\(document.relativePath)"))).output]\n" +
                    "    )")
                bundleTrees.append("'interface\(index)': interface_\(name)_\(index)().files")
            }
        }

        // A folder reference is copied whole, under its own name, wherever it is in the
        // project: its files travel as one tree into the bundle's resources. A folder of a
        // synchronized folder Xcode takes as one item goes the same way, at the place a
        // file there would have.
        let copiedWhole = folderReferences.sorted().map {
            ResourceFile(folderPath: build.projectFolder, relativePath: $0, bundlePath: ($0 as NSString).lastPathComponent)
        } + wholeFolders
        for (index, folder) in copiedWhole.enumerated() {
            bundleTrees.append("'folder\(index)': FolderTreeBuilder(under: \(Self.quoted(folder.bundlePath)), "
                             + "folder: ['folder': Folder(path: \(Self.quoted("\(folder.folderPath)/\(folder.relativePath)"))).manifest]).files")
        }

        // Plain resources: what is neither source nor compiled, flattened into the bundle's
        // resources as Xcode flattens a synchronized folder's files — a localized one under
        // its `.lproj`.
        for file in plainResources {
            products.append(.file(path: layout.resourcePath(at: file.bundlePath),
                                  expression: " StaticFile(path: \(Self.quoted("\(file.folderPath)/\(file.relativePath)"))).output"))
        }

        // ── Info.plist ───────────────────────────────────────────────────────
        // The generated keys travel as one JSON dictionary: a plist key such as
        // `UISupportedInterfaceOrientations~ipad` is no formula identifier, and JSON
        // carries the arrays, dictionaries and booleans a plist has. The build settings a
        // `$(VAR)` may name travel the same way, every one the target evaluated: the
        // project's plist may name any of them, and the formula cannot read the plist.
        let plistProperties = try Self.infoPlistProperties(identity: identity, settings: settings, targetName: target.name)
        let keysJSON        = plistProperties[InfoPlistBuilder.keysProperty] ?? "{}"
        let settingsJSON    = plistProperties[InfoPlistBuilder.buildSettingsProperty] ?? "{}"
        let base: String
        if let infoPlist = settings["INFOPLIST_FILE"], !infoPlist.isEmpty {
            base = "        base: ['base': StaticFile(path: \(Self.quoted("\(build.projectFolder)/\(infoPlist)"))).output],\n"
        } else {
            base = ""
        }
        blocks.append(
            "func infoPlist_\(name)() =\n" +
            "    InfoPlistBuilder(\n" +
            "        keys: '\(keysJSON)',\n" +
            "        \(InfoPlistBuilder.buildSettingsProperty): '\(settingsJSON)',\n" +
            base +
            "        partials: [\(partials.joined(separator: ", "))]\n" +
            "    )")
        products.append(.file(path: layout.infoPlistPath, expression: " infoPlist_\(name)().\(InfoPlistBuilder.output)"))
        // An application's `PkgInfo`, the package type and the creator code from the plist
        // as built (`APPL????`), which Xcode writes beside the plist (B-77).
        if settings["GENERATE_PKGINFO_FILE"] == "YES" {
            products.append(.file(path: layout.pkgInfoPath, expression: " infoPlist_\(name)().\(InfoPlistBuilder.pkgInfo)"))
        }

        // ── copy-files phases (B-77) ─────────────────────────────────────────
        // What a synchronized folder's exception set puts into one of the target's
        // copy-files phases, copied there as well as wherever its own type puts it: a file
        // under its name, a folder whole. A destination outside the bundle — the products
        // folder, an absolute path — is not the bundle's, and said so.
        for (index, copy) in target.phaseCopies.enumerated() {
            let folderPath = "\(build.projectFolder)/\(copy.folder)"
            guard let destination = layout.folder(forCopyDestination: copy.destination) else {
                blocks.append("// \(copy.folder)/\(copy.path) is copied by a phase to dstSubfolderSpec \(copy.destination.subfolderSpec), "
                              + "outside the bundle, which this formula does not write (B-77).")
                continue
            }
            let name = (copy.path as NSString).lastPathComponent
            let isFolder = (listing(folderPath) ?? FolderListing()).folders.contains(copy.path)
            let source = "\(folderPath)/\(copy.path)"
            if isFolder {
                products.append(.tree(folder: destination, inputs: "'copied\(index)': FolderTreeBuilder(under: \(Self.quoted(name)), "
                                      + "folder: ['folder': Folder(path: \(Self.quoted(source))).manifest]).files"))
            } else {
                let path = destination.isEmpty ? name : "\(destination)/\(name)"
                products.append(.file(path: path, expression: " StaticFile(path: \(Self.quoted(source))).output"))
            }
        }

        // The resource bundles of the packages the target links, each under its own
        // `<Package>_<Target>.bundle/` (B-77): the package's formula carries them as one
        // tree per product, empty when no target has resources, so every product is named.
        // A Mac bundle's are laid out as Mac bundles, with `Contents/Resources/` and an
        // Info.plist, as Xcode lays them out.
        for product in target.packageProducts.map(\.product).sorted() {
            let bundles = layout.isShallow ? FormulaIdentifier.bundlesFunc(forProduct: product)
                                           : FormulaIdentifier.macBundlesFunc(forProduct: product)
            bundleTrees.append("'\(bundles)': \(bundles)().files")
        }

        if !bundleTrees.isEmpty {
            products.append(.tree(folder: layout.resourcesFolder, inputs: bundleTrees.joined(separator: ", ")))
        }

        return BundleParts(blocks: blocks, parts: BundleParts.mergingTrees(products), buildSettingsJSON: settingsJSON)
    }

    // MARK: - Helpers

    /// `ConfigMerger(base: ['settings': ConfigFilter(...)], override: ['literals':
    /// SettingsLiteral(<literals>).output]).output`: the namespace's block of the project's
    /// `semel.config` laid over the machine's `semel.machine.config`, both beside the root
    /// (B-109), with the target's own values laid over that (B-120) — the same shape the
    /// Swift converter emits, and the selector alone when there are no values to lay.
    func configuration(namespace: String, literals: [String: String]) -> String {
        let settings = "ConfigMerger(base: ['machine': StaticFile(path: '\(build.root)/semel.machine.config').output], "
                     + "override: ['project': StaticFile(path: '\(build.root)/semel.config').output]).output"
        let selector = "ConfigFilter(prefix: '\(namespace)', input: ['config': \(settings)]).output"
        guard !literals.isEmpty else {
            return selector
        }
        let rendered = literals.sorted { $0.key < $1.key }
            .map { "\($0.key): \(Self.quoted($0.value))" }
            .joined(separator: ", ")
        return "ConfigMerger(base: ['\(SettingsNodes.literalsBaseWire)': \(selector)], "
             + "override: ['\(SettingsNodes.literalsOverrideWire)': SettingsLiteral(\(rendered)).output]).output"
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

    /// What a target's `InfoPlistBuilder` is given besides its base and partials: the keys
    /// Xcode's processing supplies, and every setting a `$(VAR)` in the project's file may
    /// name, each a JSON dictionary.
    static func infoPlistProperties(identity: TargetIdentity, settings: XcodeBuildSettings,
                                    targetName: String) throws -> [String: String] {
        let identityValues = ["PRODUCT_NAME": identity.productName,
                              "PRODUCT_BUNDLE_IDENTIFIER": identity.bundleIdentifier,
                              "PRODUCT_MODULE_NAME": identity.moduleName,
                              "TARGET_NAME": targetName]
        let buildSettings = settings.values.merging(identityValues) { _, identityValue in identityValue }
        return [InfoPlistBuilder.keysProperty:          try json(identity.generatedInfoPlistKeys(settings: settings)),
                InfoPlistBuilder.buildSettingsProperty: try json(buildSettings)]
    }

    static func isInsideCatalog(_ relativePath: String) -> Bool {
        relativePath.contains(".xcassets/") || relativePath.contains(".icon/")
    }

    // MARK: - Xcode's rule for what a synchronized folder puts in the bundle (B-77)
    //
    // Established on Xcode 26.6 by building a project of its own and NetNewsWire's, and
    // written out in FUTURE.md under B-77 item 2, which this follows. In short: every file
    // is a member; what a build rule compiles is compiled, the handful of types Xcode
    // neither compiles nor copies are left, and everything else — a plist, JSON, HTML, CSS,
    // JavaScript, an `.sdef`, a Markdown file, an xcconfig, a file of a type Xcode does not
    // know or with no extension — is copied into the bundle's resources under its own
    // name, whatever subfolder it sits in, except a file in a `.lproj`, which keeps its
    // language folder. A plain subfolder is a group and walked; a folder Xcode takes as one
    // item — a bundle, a folder the group names in `explicitFolders` — is copied whole.

    /// What becomes of a file of a target's resources in its bundle.
    enum Resource: Equatable {
        /// Compiled by the string catalog compiler, whose tables are placed under their
        /// languages' folders: `Localizable.xcstrings` at the folder's root, or
        /// `mul.lproj/MainMenu.xcstrings`, the catalog localizing `Base.lproj/MainMenu.xib`.
        case stringCatalog
        /// Compiled by ibtool, the document at this path under the bundle's resources and
        /// what it compiles to beside it: `Base.lproj/MainMenu.xib`, placed as
        /// `Base.lproj/MainMenu.nib`.
        case interfaceBuilder(bundlePath: String)
        /// Copied as it is to this path under the bundle's resources.
        case copied(bundlePath: String)
        /// Not a resource: a source, a header, an entitlements file, a file inside a catalog.
        case ignored
    }

    /// Where a file of a target's resources goes, by its path relative to the folder that
    /// holds it. A localized one keeps its language folder — `MainMenu/Base.lproj/MainMenu.xib`
    /// lands at `Base.lproj/MainMenu.xib`, compiled — and anything else is flattened:
    /// `Shared/Resources/GlobalKeyboardShortcuts.plist` is `GlobalKeyboardShortcuts.plist`.
    ///
    /// A `.strings` or `.stringsdict` file is copied as the bytes it is, where Xcode writes
    /// it again as UTF-16 (`builtin-copyStrings --outputencoding UTF-16`): a property list
    /// in either encoding is one to `Bundle`. A `.plist` and a `.png` are the same bytes
    /// in Xcode's Mac build too (`CopyPlistFile`, `CopyPNGFile`).
    ///
    /// A file a resources phase lists is copied whatever its type, unless a compiler takes
    /// it: listing it there is what says it is a resource, where a synchronized folder's
    /// file is sorted by its type.
    static func resource(at relativePath: String, listedInResourcesPhase: Bool = false) -> Resource {
        let name = (relativePath as NSString).lastPathComponent
        guard !neverCopiedNames.contains(name), !isInsideCatalog(relativePath) else {
            return .ignored
        }
        let pathExtension = (name as NSString).pathExtension.lowercased()
        if pathExtension == "xcstrings" {
            return .stringCatalog
        }
        let bundlePath = localizedBundlePath(relativePath) ?? name
        if IBToolCompiler.compiledExtensions[pathExtension] != nil {
            return .interfaceBuilder(bundlePath: bundlePath)
        }
        guard listedInResourcesPhase || isPlainResource(relativePath) else {
            return .ignored
        }
        return .copied(bundlePath: bundlePath)
    }

    /// What becomes of a folder inside a synchronized folder.
    enum FolderRole: Equatable {
        /// A group: walked, each file placed by `resource(at:)`. A `.lproj` is one.
        case group
        /// An asset catalog or an icon, compiled whole by actool.
        case catalog
        /// One item, copied whole under this path in the bundle's resources with what it
        /// holds laid out as it is.
        case copiedWhole(bundlePath: String)
        /// Built by a tool Semel does not run — a Core Data model, a documentation catalog —
        /// and so neither walked nor copied.
        case notBuilt
    }

    /// Folders Xcode takes as one item and copies whole, by extension: a bundle, a rich
    /// text document with its attachments. Xcode asks the system whether a folder's type
    /// is a package, so a folder with an extension some installed app declares a package
    /// type for is one item too — NetNewsWire's `.nnwtheme` once NetNewsWire has been
    /// built on the machine, a group before — which a hermetic build cannot ask; this list
    /// is what holds on every machine.
    static let copiedWholeFolderExtensions: Set<String> = ["bundle", "rtfd"]
    /// Folders Xcode compiles with a tool Semel does not run.
    static let notBuiltFolderExtensions: Set<String> = ["xcdatamodeld", "xcdatamodel", "docc"]

    /// A documentation catalog, which a sources phase may list (CodeEdit's
    /// `Documentation.docc`): `docc` runs only in a documentation build, so an app's
    /// bundle holds nothing of it, and a build that leaves it out builds what Xcode's does.
    static func isDocumentationOnly(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "docc"
    }

    /// The role of the folder at `relativePath` in a synchronized folder whose group names
    /// `explicitFolders`; placed, when copied whole, as a file there would be: under its
    /// own name, or its language folder's.
    static func folderRole(at relativePath: String, explicitFolders: [String] = []) -> FolderRole {
        let name = (relativePath as NSString).lastPathComponent
        let pathExtension = (name as NSString).pathExtension.lowercased()
        if pathExtension == "xcassets" || pathExtension == "icon" {
            return .catalog
        }
        if notBuiltFolderExtensions.contains(pathExtension) {
            return .notBuilt
        }
        if copiedWholeFolderExtensions.contains(pathExtension) || explicitFolders.contains(relativePath) {
            return .copiedWhole(bundlePath: localizedBundlePath(relativePath) ?? name)
        }
        return .group
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

    /// A file Xcode copies into the bundle as it is: every file of a synchronized folder
    /// but what `neverCopiedExtensions` names and what a compiler takes. A plist is
    /// copied — `Shared/Resources/GlobalKeyboardShortcuts.plist`, which NetNewsWire reads
    /// at launch — and so are a Markdown file, an xcconfig, a provisioning profile, a
    /// `.gyb` template and a file whose type Xcode does not know. The target's own
    /// Info.plist is left out by the caller, which knows which it is.
    static func isPlainResource(_ relativePath: String) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        guard !neverCopiedNames.contains(name), !isInsideCatalog(relativePath) else {
            return false
        }
        let pathExtension = (name as NSString).pathExtension.lowercased()
        let compiled = pathExtension == "xcstrings" || IBToolCompiler.compiledExtensions[pathExtension] != nil
        return !compiled && !neverCopiedExtensions.contains(pathExtension)
    }

    /// The files of a synchronized folder Xcode never copies, by extension, lowercased.
    /// Seen not copied in an application built by Xcode 26.6: Swift and C-family sources
    /// (compiled), headers and a prefix header, a module map, API notes, an entitlements
    /// file whether the settings name it or not, an exports list and a `.inc` (each "no
    /// rule to process file"). The rest are compiled by a rule Xcode has and Semel does not
    /// run — assembly, Metal, lex and yacc, an intent definition, a Core Data mapping
    /// model, a Core ML model — named so they are not copied as though they were data.
    static let neverCopiedExtensions: Set<String> = cFamilySourceExtensions.union([
        "swift", "h", "hh", "hpp", "hxx", "h++", "pch", "modulemap", "apinotes", "entitlements", "exp", "inc",
        "s", "metal", "l", "lm", "lmm", "lpp", "lxx", "y", "ym", "ymm", "ypp", "yxx",
        "intentdefinition", "xcmappingmodel", "mlmodel",
    ])

    /// Names never copied: what Xcode's copy leaves out of everything it copies
    /// (`builtin-copy -exclude .DS_Store -exclude CVS -exclude .svn -exclude .git -exclude .hg`).
    /// Any other hidden file is copied by Xcode, `.gitkeep` among them; Semel's push takes
    /// no hidden file, so none reaches a listing.
    static let neverCopiedNames: Set<String> = [".DS_Store", "CVS", ".svn", ".git", ".hg"]

    // MARK: - C-family sources in an application target (B-77)

    /// What Xcode compiles through clang in a target, as a package's C target's sources
    /// are compiled; lowercased. Assembly is not among them yet.
    static let cFamilySourceExtensions: Set<String> = ["c", "m", "mm", "cpp", "cc", "cxx"]
    /// The ones that bring the C++ runtime at link.
    static let cxxSourceExtensions: Set<String> = ["mm", "cpp", "cc", "cxx"]
    /// What a header is, for the headers a bridging header is handed.
    static let headerExtensions: Set<String> = ["h", "hh", "hpp", "hxx", "inc", "def"]

    static func isCFamilySource(_ path: String) -> Bool {
        cFamilySourceExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func isHeader(_ path: String) -> Bool {
        headerExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The clang nodes a target's C-family sources are built through. Named rather than
    /// imported, as the Swift nodes are.
    static let clangPreprocessorNamespace = derivedSettingNamespace(forTypeName: "ClangPreprocessor")
    static let clangCompilerNamespace     = derivedSettingNamespace(forTypeName: "ClangCompiler")

    /// What a target's Objective-C, C and C++ come to in its formula: the sources to
    /// compile, the folders their preprocessor searches, the settings both clang stages
    /// take, and the bridging header its Swift imports with the headers beside it.
    struct ObjectiveCSources {
        /// Every C-family source, by its path in the input file system, sorted.
        var sources: [String] = []
        /// The preprocessor's header folders: the target's synchronized folders and the
        /// folder of each listed source outside them. Sorted.
        var headerFolders: [String] = []
        var preprocessorLiterals: [String: String] = [:]
        var compilerLiterals: [String: String] = [:]
        /// `GCC_PREPROCESSOR_DEFINITIONS`, one `NAME` or `NAME=value` each.
        var defines: [String] = []
        /// `OTHER_CFLAGS`, as words.
        var otherFlags: [String] = []
        /// The flags a source has of its own, by its path in the input file system.
        var fileFlags: [String: [String]] = [:]
        var compilesCxx = false
        /// `SWIFT_OBJC_BRIDGING_HEADER`, relative to the project's folder.
        var bridgingHeader: String?
        /// Every header in the target's synchronized folders, by its path relative to the
        /// project's folder (the key) and in the input file system (the path). Sorted.
        var headers: [(key: String, path: String)] = []

        /// The preprocessor's literals for a source with flags of its own: the target's
        /// `OTHER_CFLAGS`, then the source's.
        func preprocessorLiterals(adding flags: [String]) -> [String: String] {
            Self.withArguments(preprocessorLiterals, otherFlags + flags)
        }

        /// The compiler's, the same less what only the preprocessor may act on.
        func compilerLiterals(adding flags: [String]) -> [String: String] {
            Self.withArguments(compilerLiterals, XcodeFormulaEmitter.compileStageFlags(otherFlags + flags))
        }

        static func withArguments(_ literals: [String: String], _ flags: [String]) -> [String: String] {
            var literals = literals
            literals["arguments"] = flags.isEmpty ? nil : flags.joined(separator: ",")
            return literals
        }
    }

    /// Xcode passes `OTHER_CFLAGS` and a source's own flags to the one clang that
    /// preprocesses and compiles it; here the two are separate nodes, and each takes them
    /// all — a `-D` defines nothing in text already preprocessed, a warning flag the
    /// preprocessor has no use for is one it ignores — but for a file forced in ahead of
    /// the source (`-include`, `-imacros`), which the compiler would take in a second time,
    /// and which the preprocessed text already holds.
    static func compileStageFlags(_ flags: [String]) -> [String] {
        var kept: [String] = []
        var skipsNext = false
        for flag in flags {
            if skipsNext {
                skipsNext = false
                continue
            }
            if flag == "-include" || flag == "-imacros" {
                skipsNext = true
                continue
            }
            if flag.hasPrefix("-include") || flag.hasPrefix("-imacros") {
                continue
            }
            kept.append(flag)
        }
        return kept
    }

    /// The target's C-family sources — in its synchronized folders less their exceptions,
    /// borrowed from another folder, or listed — and its headers, from what the converter
    /// walked, with the settings they build under. Clang's settings follow Xcode's:
    /// `CLANG_ENABLE_OBJC_ARC` and `CLANG_ENABLE_MODULES` (off unless set, as in Xcode),
    /// the language standards when the project states them, `GCC_PREPROCESSOR_DEFINITIONS`,
    /// `OTHER_CFLAGS` as `arguments`, and the target's triple, as the Swift compiler gets
    /// it; a source's own flags (`additionalCompilerFlagsByRelativePath`) after the
    /// target's. A Swift source's own flags reach nothing, as in Xcode 26.6: a probe's
    /// `-DPROBE_SWIFT_FILE_FLAG` on one Swift file was on no `swiftc` command line (B-77).
    ///
    /// ISSUE: a definition or a flag holding a comma splits in two, and one holding a
    /// quote ends the formula's string — the limit a package's `.define` has. A C++ source
    /// takes `OTHER_CFLAGS` too, where Xcode gives it `OTHER_CPLUSPLUSFLAGS` (by default the
    /// same).
    func objectiveCSources(of target: XcodeProject.Target,
                           identity: TargetIdentity,
                           in sourceFolders: [(XcodeProject.SynchronizedFolder, String)],
                           settings: XcodeBuildSettings,
                           listing: (String) -> FolderListing?,
                           listed: [String]) -> ObjectiveCSources {
        var result = ObjectiveCSources()
        var sources = Set<String>()
        var searchedFolders = Set<String>()
        for (folder, folderPath) in sourceFolders {
            searchedFolders.insert(folderPath)
            for file in (listing(folderPath) ?? FolderListing()).files where !folder.excludes(file) && !Self.isInsideCatalog(file) {
                if Self.isCFamilySource(file) {
                    sources.insert("\(folderPath)/\(file)")
                    if let flags = folder.compilerFlags[file] {
                        result.fileFlags["\(folderPath)/\(file)"] = XcodeBuildSettings.words(flags)
                    }
                }
                if Self.isHeader(file) {
                    result.headers.append((key: "\(folder.path)/\(file)", path: "\(folderPath)/\(file)"))
                }
            }
        }
        let synchronizedPaths = sourceFolders.map(\.1)
        let borrowedFlags = target.borrowedCompilerFlags
        for relativePath in listed + target.borrowedFiles.filter(Self.isCFamilySource) {
            let path = "\(build.projectFolder)/\(relativePath)"
            sources.insert(path)
            if let flags = borrowedFlags[relativePath] {
                result.fileFlags[path] = XcodeBuildSettings.words(flags)
            }
            if !synchronizedPaths.contains(where: { path.hasPrefix($0 + "/") }) {
                searchedFolders.insert((path as NSString).deletingLastPathComponent)
            }
        }
        result.headers.sort { $0.key < $1.key }
        result.bridgingHeader = settings["SWIFT_OBJC_BRIDGING_HEADER"].map(Self.projectRelativePath).flatMap { $0.isEmpty ? nil : $0 }
        result.defines = settings.list("GCC_PREPROCESSOR_DEFINITIONS")
        result.otherFlags = settings.list("OTHER_CFLAGS")
        guard !sources.isEmpty else {
            return result
        }
        result.sources = sources.sorted()
        result.headerFolders = searchedFolders.sorted()
        result.compilesCxx = sources.contains { Self.cxxSourceExtensions.contains(($0 as NSString).pathExtension.lowercased()) }

        var literals = ["target": identity.target]
        if settings["CLANG_ENABLE_OBJC_ARC"] == "YES" {
            literals["objectiveCARC"] = "true"
        }
        if settings["CLANG_ENABLE_MODULES"] == "YES" {
            literals["modules"] = "true"
        }
        if let standard = settings["GCC_C_LANGUAGE_STANDARD"], !standard.isEmpty, standard != "compiler-default" {
            literals["cStandard"] = standard
        }
        if let standard = settings["CLANG_CXX_LANGUAGE_STANDARD"], !standard.isEmpty, standard != "compiler-default" {
            literals["cxxStandard"] = standard
        }
        result.compilerLiterals = ObjectiveCSources.withArguments(literals, Self.compileStageFlags(result.otherFlags))
        if !result.defines.isEmpty {
            literals["defines"] = result.defines.joined(separator: ",")
        }
        result.preprocessorLiterals = ObjectiveCSources.withArguments(literals, result.otherFlags)
        return result
    }

    /// A path setting relative to the project's folder: `Mac/App-Bridging-Header.h` as it
    /// is, and `$(SRCROOT)/Mac/App-Bridging-Header.h` without the variable, which names
    /// the project's folder and is not among the settings evaluated here.
    static func projectRelativePath(_ setting: String) -> String {
        for prefix in ["$(SRCROOT)/", "${SRCROOT}/", "$(PROJECT_DIR)/", "${PROJECT_DIR}/"] where setting.hasPrefix(prefix) {
            return String(setting.dropFirst(prefix.count))
        }
        return setting
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
        packageType = settings["PRODUCT_BUNDLE_PACKAGE_TYPE"] ?? (target.isExtension ? "XPC!" : "APPL")

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
    ///
    /// Over a project's own file that is not generated, Xcode adds the platform's keys and
    /// leaves the bundle's identity and version to the file: CodeEdit's says
    /// `CFBundleShortVersionString = 0.3.6` beside `MARKETING_VERSION = "Change in
    /// Info.plist"`, and its app and extension come out of Xcode as 0.3.6 (B-77).
    func generatedInfoPlistKeys(settings: XcodeBuildSettings) -> [String: Any] {
        var keys: [String: Any] = ["DTPlatformName": sdk]
        let hasOwnFile = !(settings["INFOPLIST_FILE"] ?? "").isEmpty
        if settings["GENERATE_INFOPLIST_FILE"] == "YES" || !hasOwnFile {
            keys.merge([
                "CFBundleDevelopmentRegion": settings["DEVELOPMENT_LANGUAGE"] ?? "en",
                "CFBundleExecutable": productName,
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": productName,
                "CFBundlePackageType": packageType,
                "CFBundleShortVersionString": settings["MARKETING_VERSION"] ?? "1.0",
                "CFBundleVersion": settings["CURRENT_PROJECT_VERSION"] ?? "1",
            ]) { _, identity in identity }
        }
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
        // Only when the plist is generated: with `GENERATE_INFOPLIST_FILE = NO` Xcode
        // reads the project's file alone and passes these over, and CodeEdit's
        // `INFOPLIST_KEY_NSPrincipalClass` names a class its app does not have, which
        // `NSApplicationMain` exits on (B-77).
        guard settings["GENERATE_INFOPLIST_FILE"] == "YES" else {
            return keys
        }
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
