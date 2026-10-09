//
//  CodeSigner.swift
//  SemelApple
//
//  Runs `codesign` over a bundle tree, as Xcode signs a bundle it has assembled: every
//  bundle nested in it first, deepest first — embedded frameworks, `PlugIns/*.appex`,
//  Sparkle's `Updater.app` and XPC services — then the bundle itself with its
//  entitlements. What comes out is the signed tree, so a formula's product is the signed
//  bundle (B-77). An arm64 Mac executable carries the linker's ad-hoc signature already,
//  which lets it run; what signing the bundle adds is the seal over its Info.plist and
//  resources, the nested code recorded by hash, and the entitlements — the app sandbox,
//  app groups — none of which the linker's signature has.
//
//  Ad-hoc only: identity `-`, no certificate, no timestamp. Two signings of the same tree
//  write the same bytes, which is what lets the signed bundle be a cached value (B-89).

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

struct CodeSignerConfiguration {
    let toolDescriptor: ToolDescriptor
    /// What `--sign` is given. `-` is ad-hoc, the one this node signs with; a named
    /// identity is a certificate in a keychain, which the sandbox does not reach and a
    /// cache entry could not hold, and is refused by name until Semel signs with one. A
    /// setting rather than a constant so a formula states it, as Xcode's
    /// `CODE_SIGN_IDENTITY` does.
    let identity: String
    /// The toolchain's `codesign_allocate`, which `codesign` runs to make room for a
    /// signature in a Mach-O: a machine setting, written by `semel-swift prepare` as
    /// `apple.codeSigner.codesignAllocatePath`, and handed over as `CODESIGN_ALLOCATE` as
    /// Xcode hands it. Without it `codesign` finds `/usr/bin/codesign_allocate`, a shim to
    /// whichever Xcode `xcode-select` names, which no cache key would see.
    let codesignAllocatePath: String
    /// `hardenedRuntime`: the bundle is signed with the hardened runtime, `-o runtime`, as
    /// Xcode signs a target whose `ENABLE_HARDENED_RUNTIME` is `YES`. A literal from the
    /// converter, like the entitlements a fact about the bundle; off when not stated.
    let hardenedRuntime: Bool

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        identity = required.value("identity")
        codesignAllocatePath = required.value("codesignAllocatePath")
        try required.check()
        hardenedRuntime = properties[Self.hardenedRuntimeKey] == "true"

        guard identity == Self.adHocIdentity else {
            throw ErrorCondition.settingNotSupported(key: "\(Self.settingNamespace).identity", value: identity,
                                                     supported: Self.adHocIdentity)
        }
    }

    /// Pinned, like every Apple platform node's: under `apple.`.
    static let settingNamespace = "apple.codeSigner"
    /// `codesign --sign -`: an ad-hoc signature, the hashes of the code with no identity.
    static let adHocIdentity = "-"
    /// The machine settings this namespace declares.
    static let machineSettingKeys: Set<String> = ["codesignAllocatePath"]
    static let hardenedRuntimeKey = "hardenedRuntime"
}

// MARK: - Node

public struct CodeSigner: Node {
    public static let kind: UInt = 42

    /// 2: `hardenedRuntime` signs with `-o runtime`, and a nested bundle keeps its flags
    /// with its entitlements when it is signed again (B-77).
    /// 3: a tree's symbolic links are laid as links and come back as links in the signed
    /// tree, where a versioned framework's copies were laid as links and handed back as
    /// copies (B-77).
    /// 4: several wires on a one-wire port are an error naming them, where one was taken
    /// (B-141).
    /// 5: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    public static let implementationVersion = 5

    // MARK: Ports

    static let configuration = "configuration"
    /// The bundle, one wire: the tree of its contents, keyed by the bundle's own folder
    /// name — `NetNewsWire.app`, `Widgets.appex` — which is how `codesign` tells what kind
    /// of bundle it signs.
    static let bundle = "bundle"
    /// The entitlements the bundle is signed with, at most one wire: a property list, its
    /// `$(VAR)` references already resolved. None is a signature without entitlements.
    static let entitlements = "entitlements"
    /// The signed bundle's contents, as the bundle wire's tree was, with each signature
    /// `codesign` wrote (`_CodeSignature/CodeResources`) beside what it seals.
    static let output = "files"
    static let infoLog = "infoLog"
    static let errorLog = "errorLog"

    static let signedFolder = "signed"
    static let entitlementsFile = "entitlements.plist"

    /// The kinds of bundle that hold code of their own, and so are signed before the
    /// bundle holding them. A resource bundle (`<Package>_<Target>.bundle`) holds none and
    /// is sealed as the resources it is.
    static let nestedCodeExtensions: Set<String> = ["app", "appex", "framework", "xpc"]

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(configuration), .required(bundle), .optional(entitlements)],
        outputPorts: [output, infoLog, errorLog]
    )

    // MARK: Processing

    /// The binary behind the tool version the configuration names (B-17).
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try toolBinaryCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }

    /// A signature's failure belongs to the bundle it signs, by the wire's key.
    public func errorSubject(input: ProcessInput?) -> ErrorDocument.Subject? {
        input?.inputValues[Self.bundle]?.keys.min().map { .product(path: $0) }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let configurationText = try input.onlyWire(onRequiredPort: Self.configuration).value.expectValue().resolveAsString()
        let configuration = try CodeSignerConfiguration(properties: [String: String](plainText: configurationText))

        let bundleWire = try input.onlyWire(onRequiredPort: Self.bundle)
        let bundleName = bundleWire.key
        guard !bundleName.isEmpty, !bundleName.contains("/") else {
            throw ErrorCondition.bundleWireKeyInvalid(key: bundleName)
        }
        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try bundleWire.value.expectValue().resolveAsString())
        var entitlementsFile: FileNameAndContent?
        var infoLog = ""
        if let entitlementsWire = try input.onlyWire(onOptionalPort: Self.entitlements) {
            let adHoc = try Self.adHocEntitlements(from: try entitlementsWire.value.expectValue())
            entitlementsFile = FileNameAndContent(filePath: Self.entitlementsFile, hash: adHoc.hash)
            if !adHoc.leftOut.isEmpty {
                infoLog += "Left out of the ad-hoc signature, as only a provisioning profile grants them: "
                         + adHoc.leftOut.joined(separator: ", ") + "\n"
            }
        }

        let layout = SigningLayout(entries: manifest.entries)
        let tool = try ToolRunnerRegistry.instance.tool(descriptor: configuration.toolDescriptor,
                                                        namespace:  CodeSignerConfiguration.settingNamespace)
        let root = "\(Self.signedFolder)/\(bundleName)"
        let environment = ["CODESIGN_ALLOCATE": configuration.codesignAllocatePath]
        let signing = ["--force", "--sign", configuration.identity, "--timestamp=none"]
        var entries = manifest.entries
        var errorLog = ""

        // Two runs, since entitlements are per invocation: the nested bundles together,
        // each keeping the entitlements and the flags it was signed with — an extension its
        // own and its hardened runtime, signed by the extension's own signer, a vendor's XPC
        // service the vendor's, as Xcode keeps them when it signs what it embeds
        // (`--preserve-metadata=identifier,entitlements,flags`) — then the bundle with its
        // own. The second lays out what the first wrote.
        var runs: [[String]] = []
        if !layout.nestedBundles.isEmpty {
            runs.append(signing + ["--preserve-metadata=entitlements,flags"] + layout.nestedBundles.map { "\(root)/\($0)" })
        }
        let runtime = configuration.hardenedRuntime ? ["-o", "runtime"] : []
        runs.append(signing + runtime + (entitlementsFile == nil ? [] : ["--entitlements", Self.entitlementsFile]) + [root])

        for arguments in runs {
            // Files laid with their modes, writable: codesign rewrites a signature already
            // there. Links laid as links: a versioned framework's are what codesign reads
            // its shape from.
            let inputFiles = entries.map { entry -> FileNameAndContent in
                switch entry.content {
                case .file(let hash, _):
                    return FileNameAndContent(filePath: "\(root)/\(entry.path)", hash: hash, mode: layout.mode(of: entry.path))
                case .symbolicLink(let target):
                    return FileNameAndContent(symbolicLinkAt: "\(root)/\(entry.path)", target: target)
                }
            } + (entitlementsFile.map { [$0] } ?? [])
            let result = try tool.execute(arguments: arguments,
                                          environment: environment,
                                          inputFiles: inputFiles,
                                          expectedOutputFileNames: [],
                                          expectedOutputFolders: [Self.signedFolder])
            infoLog += result.infoOutput
            errorLog += result.errorOutput
            guard result.exitCode == 0 else {
                return .init(outputValues: [Self.output:   try result.failureDocument(tool: "codesign",
                                                                                  subject: .product(path: bundleName)).published(),
                                            Self.infoLog:  .value(try infoLog.intern()),
                                            Self.errorLog: .value(try errorLog.intern())],
                             inputWireSpecs: [:])
            }
            let prefix = "\(bundleName)/"
            entries = (result.outputTrees[Self.signedFolder] ?? [])
                .filter { $0.path.hasPrefix(prefix) }
                .map { TreeManifestEntry(path: String($0.path.dropFirst(prefix.count)), content: $0.content) }
        }

        let signed = layout.restoringModes(of: entries)
        return .init(outputValues: [Self.output:   .value(try signed.toJSON().intern()),
                                    Self.infoLog:  .value(try infoLog.intern()),
                                    Self.errorLog: .value(try errorLog.intern())],
                     inputWireSpecs: [:])
    }

    // MARK: Entitlements

    /// The entitlements an ad-hoc signature can carry, stored, and the keys left out.
    ///
    /// An entitlement a provisioning profile grants — iCloud, push, associated domains,
    /// WeatherKit, a keychain group, the application identifier — is honoured only with
    /// the profile that grants it, and a process claiming one without it is killed at
    /// launch: an arm64 app signed ad-hoc with `com.apple.developer.icloud-services` exits
    /// on SIGKILL before its first instruction (macOS 26.6). Xcode stops such a build for
    /// want of a team; an ad-hoc signature is for running here, so what only a profile
    /// grants is left out and said on the log, and what a signature carries by itself — the
    /// sandbox, app groups, network access — is kept. NetNewsWire's Mac entitlements hold
    /// both kinds.
    static func adHocEntitlements(from hash: String) throws -> (hash: String, leftOut: [String]) {
        guard let bytes = try DataObjectStore.shared.read(hash: hash),
              let entitlements = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any] else {
            throw ErrorCondition.inputNotOfForm(port: Self.entitlements, wire: hash, form: .propertyListDictionary)
        }
        let leftOut = entitlements.keys.sorted().filter(isGrantedByProfile)
        guard !leftOut.isEmpty else {
            return (hash, [])
        }
        let kept = entitlements.filter { !isGrantedByProfile($0.key) }
        let data = try PropertyListSerialization.data(fromPropertyList: kept, format: .xml, options: 0)
        return (try [UInt8](data).intern(), leftOut)
    }

    /// Whether only a provisioning profile grants an entitlement: Apple's developer
    /// services, under `com.apple.developer.`, and the identifiers a profile names.
    static func isGrantedByProfile(_ key: String) -> Bool {
        key.hasPrefix("com.apple.developer.")
            || ["application-identifier", "com.apple.application-identifier", "keychain-access-groups", "aps-environment"].contains(key)
    }
}

// MARK: - Laying a bundle out for codesign

/// What `codesign` has to be told about a bundle tree beyond its entries, and the way back
/// to a tree.
///
/// The tree is laid as it is: files with their modes, symbolic links as links. A versioned
/// framework — Sparkle's, or any a vendor builds — arrives with `Versions/Current` and the
/// links at its top as links (B-77), which is the shape `codesign` signs one in; a copy of
/// either at a framework's top reads as a shallow bundle and a versioned one at once
/// ("bundle format is ambiguous"), and a bundle holding a framework it cannot sign cannot
/// be signed either.
struct SigningLayout {

    /// Every bundle holding code below the bundle's root, relative to it, deepest first:
    /// what is signed before the bundle itself, and what each holds before it. Found along
    /// the entries' folders, so never through a link: a link to `Versions/Current/Updater.app`
    /// is the link, and the app is signed where it is.
    let nestedBundles: [String]
    /// Every file's mode by path. A file comes back from the sandbox with the mode the
    /// store keeps objects in; what it had in the tree is what it has signed.
    private let modes: [String: UInt16]

    // Plain loops rather than `Dictionary(_:uniquingKeysWith:)` over a `compactMap` of
    // closures: the release optimizer of Swift 6.3.3 (Xcode 26.6) dies in CopyPropagation
    // on that shape of this initializer, deterministically, on the hosted runner and
    // locally alike. The loops say the same thing — the first mode for a path wins.
    init(entries: [TreeManifestEntry]) {
        var modesByPath: [String: UInt16] = [:]
        var bundles = Set<String>()
        for entry in entries {
            if let mode = entry.mode, modesByPath[entry.path] == nil {
                modesByPath[entry.path] = mode
            }
            let components = entry.path.split(separator: "/").map(String.init)
            for index in components.indices.dropLast() {
                let name = components[index] as NSString
                if CodeSigner.nestedCodeExtensions.contains(name.pathExtension.lowercased()) {
                    bundles.insert(components[...index].joined(separator: "/"))
                }
            }
        }
        modes = modesByPath
        nestedBundles = bundles.sorted { first, second in
            let firstDepth = first.split(separator: "/").count
            let secondDepth = second.split(separator: "/").count
            return firstDepth != secondDepth ? firstDepth > secondDepth : first < second
        }
    }

    /// The mode a file had in the tree; a file the tree did not have — a signature — has
    /// the mode a file has by default.
    func mode(of path: String) -> UInt16 {
        modes[path] ?? FileMetadata.defaultMode
    }

    /// The signed entries as a tree: each file with the mode it had in the tree, each link
    /// as it came back.
    func restoringModes(of signed: [TreeManifestEntry]) -> TreeManifest {
        TreeManifest(entries: signed.map { entry in
            guard case .file(let hash, _) = entry.content else {
                return entry
            }
            return TreeManifestEntry(path: entry.path, hash: hash, mode: mode(of: entry.path))
        })
    }
}
