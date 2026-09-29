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
            throw NodeError.other(message: "CodeSigner signs ad-hoc only: \(Self.settingNamespace).identity is '\(identity)', "
                                         + "and only '\(Self.adHocIdentity)' is signed with (B-77)")
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
    public static let implementationVersion = 2

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

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let configurationText = try input.inputValues[Self.configuration]!.values.first!.expectValue().resolveAsString()
        let configuration = try CodeSignerConfiguration(properties: [String: String](plainText: configurationText))

        guard let bundleWire = input.inputValues[Self.bundle]?.first else {
            throw NodeError.other(message: "CodeSigner: nothing is wired to its bundle port")
        }
        let bundleName = bundleWire.key
        guard !bundleName.isEmpty, !bundleName.contains("/") else {
            throw NodeError.other(message: "CodeSigner: the bundle's wire is keyed '\(bundleName)'; "
                                         + "it names the bundle's folder, as 'NetNewsWire.app' does")
        }
        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try bundleWire.value.expectValue().resolveAsString())
        var entitlementsFile: FileNameAndContent?
        var infoLog = ""
        if let entitlementsWire = input.inputValues[Self.entitlements]?.first {
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
        var files = layout.files.map { (path: $0.path, hash: $0.hash) }
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
            // Laid with their modes, writable: codesign rewrites a signature already there.
            let inputFiles = files.map { FileNameAndContent(filePath: "\(root)/\($0.path)", hash: $0.hash, mode: layout.mode(of: $0.path)) }
                + layout.links.map { FileNameAndContent(symbolicLinkAt: "\(root)/\($0.path)", destination: $0.destination) }
                + (entitlementsFile.map { [$0] } ?? [])
            let result = try tool.execute(arguments: arguments,
                                          environment: environment,
                                          inputFiles: inputFiles,
                                          expectedOutputFileNames: [],
                                          expectedOutputFolders: [Self.signedFolder])
            infoLog += result.infoOutput
            errorLog += result.errorOutput
            guard result.exitCode == 0 else {
                let message = result.failureMessage(tool: "codesign")
                return .init(outputValues: [Self.output:   .noValue(reason: .error(messageDataObjectHash: try message.intern())),
                                            Self.infoLog:  .value(try infoLog.intern()),
                                            Self.errorLog: .value(try errorLog.intern())],
                             inputWireSpecs: [:])
            }
            let prefix = "\(bundleName)/"
            files = (result.outputTrees[Self.signedFolder] ?? [])
                .filter { $0.relativePath.hasPrefix(prefix) }
                .map { (path: String($0.relativePath.dropFirst(prefix.count)), hash: $0.hash) }
        }

        let signed = layout.restoring(signedFiles: files)
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
            throw NodeError.other(message: "CodeSigner: the entitlements are not a property list dictionary")
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

/// A bundle tree as `codesign` must see it, and the way back to a tree.
///
/// A tree has no link entry: a push follows a symbolic link, so a versioned framework —
/// Sparkle's, or any a vendor builds — arrives with `Versions/Current` and every link at
/// its top as copies of what they named. `codesign` cannot sign that: a framework folder
/// holding real files at its top reads as a shallow bundle and a versioned one at once
/// ("bundle format is ambiguous"), and a bundle holding a nested framework it cannot sign
/// cannot be signed either. So the copies are recognised by the shape every versioned
/// framework has — `Versions/Current` the same files as one other version, each other
/// entry at the top the same as its namesake in `Versions/Current` — and laid as the links
/// they were, and after signing each link is a copy again of what it names, now signed.
/// The export then holds copies, as it did before signing, which run but do not verify as
/// a bundle; the links in a tree itself are what would make it verify (B-77).
struct SigningLayout {

    struct Link: Equatable {
        /// Where the link is, relative to the bundle: `Contents/Frameworks/Tiny.framework/Tiny`.
        let path: String
        /// What it says, relative to its folder: `Versions/Current/Tiny`.
        let destination: String
        /// What it names in the tree, links followed: `Contents/Frameworks/Tiny.framework/Versions/A/Tiny`.
        let target: String
    }

    /// The tree's entries less every copy that stands for a link.
    let files: [TreeManifestEntry]
    /// Outermost first.
    let links: [Link]
    /// Every bundle holding code below the bundle's root, relative to it, deepest first:
    /// what is signed before the bundle itself, and what each holds before it.
    let nestedBundles: [String]
    /// Every entry's mode by path. A file comes back from the sandbox with the mode the
    /// store keeps objects in; what it had in the tree is what it has signed.
    private let modes: [String: UInt16]

    init(entries: [TreeManifestEntry]) {
        var remaining = entries
        var links: [Link] = []
        for framework in Self.versionedFrameworks(in: entries) {
            // A framework inside a copy already taken away is taken away with it.
            guard remaining.contains(where: { $0.path.hasPrefix(framework + "/") }) else {
                continue
            }
            let found = Self.links(in: framework, entries: remaining)
            let covered = Set(found.map(\.path))
            remaining.removeAll { entry in covered.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") } }
            links += found
        }
        files = remaining
        self.links = links
        modes = Dictionary(entries.map { ($0.path, $0.mode) }, uniquingKeysWith: { first, _ in first })

        var bundles = Set<String>()
        for entry in remaining {
            let components = entry.path.split(separator: "/").map(String.init)
            for index in components.indices.dropLast() {
                let name = components[index] as NSString
                if CodeSigner.nestedCodeExtensions.contains(name.pathExtension.lowercased()) {
                    bundles.insert(components[...index].joined(separator: "/"))
                }
            }
        }
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

    /// The signed files as a tree: each link a copy again of what it names, and each file
    /// with the mode it had in the tree.
    func restoring(signedFiles: [(path: String, hash: String)]) -> TreeManifest {
        var entries = signedFiles.map { file in
            TreeManifestEntry(path: file.path, hash: file.hash, mode: mode(of: file.path))
        }
        for link in links {
            for entry in entries where entry.path == link.target || entry.path.hasPrefix(link.target + "/") {
                entries.append(TreeManifestEntry(path: link.path + entry.path.dropFirst(link.target.count),
                                                 hash: entry.hash, mode: entry.mode))
            }
        }
        return TreeManifest(entries: entries)
    }

    /// Every framework folder with a `Versions` folder in it, outermost first.
    private static func versionedFrameworks(in entries: [TreeManifestEntry]) -> [String] {
        var frameworks = Set<String>()
        for entry in entries {
            let components = entry.path.split(separator: "/").map(String.init)
            for index in components.indices.dropLast(2) where components[index].hasSuffix(".framework") && components[index + 1] == "Versions" {
                frameworks.insert(components[...index].joined(separator: "/"))
            }
        }
        return frameworks.sorted { first, second in
            let firstDepth = first.split(separator: "/").count
            let secondDepth = second.split(separator: "/").count
            return firstDepth != secondDepth ? firstDepth < secondDepth : first < second
        }
    }

    /// The links one versioned framework's copies stand for: `Versions/Current` when it
    /// holds what exactly one other version holds, and each other entry at the top that
    /// is what its namesake in that version is. Nothing when `Versions/Current` matches no
    /// version: then the copies are not recognisably links, and `codesign` says what it
    /// makes of the folder.
    private static func links(in framework: String, entries: [TreeManifestEntry]) -> [Link] {
        let versionsFolder = framework + "/Versions/"
        var versions: [String: [String: String]] = [:]
        var top: [String: [String: String]] = [:]
        for entry in entries where entry.path.hasPrefix(framework + "/") {
            let relative = String(entry.path.dropFirst(framework.count + 1))
            let name = String(relative.split(separator: "/", maxSplits: 1)[0])
            let below = String(relative.dropFirst(name.count)).drop { $0 == "/" }
            if entry.path.hasPrefix(versionsFolder) {
                let inVersions = String(entry.path.dropFirst(versionsFolder.count))
                let version = String(inVersions.split(separator: "/", maxSplits: 1)[0])
                let inVersion = String(inVersions.dropFirst(version.count)).drop { $0 == "/" }
                versions[version, default: [:]][String(inVersion)] = entry.hash
            } else {
                top[name, default: [:]][String(below)] = entry.hash
            }
        }
        guard let current = versions["Current"] else {
            return []
        }
        let matching = versions.keys.sorted().filter { $0 != "Current" && versions[$0] == current }
        guard matching.count == 1, let version = matching.first else {
            return []
        }
        var links = [Link(path: framework + "/Versions/Current", destination: version, target: versionsFolder + version)]
        for (name, contents) in top.sorted(by: { $0.key < $1.key }) {
            // A file at the top is one entry with nothing below it; a folder, what is in it.
            let namesake = current.compactMap { path, hash -> (String, String)? in
                if path == name {
                    return ("", hash)
                }
                return path.hasPrefix(name + "/") ? (String(path.dropFirst(name.count + 1)), hash) : nil
            }
            guard Dictionary(namesake, uniquingKeysWith: { first, _ in first }) == contents else {
                continue
            }
            links.append(Link(path: "\(framework)/\(name)", destination: "Versions/Current/\(name)",
                              target: "\(versionsFolder)\(version)/\(name)"))
        }
        return links
    }
}
