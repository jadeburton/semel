//
//  CodeSignerTests.swift
//  SemelAppleTests
//
//  codesign over a bundle tree, nested bundles first, then the bundle with its
//  entitlements (B-77).
//

@testable import SemelApple
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class CodeSignerTests: SemelAppleTestCase {

    private let descriptor = ToolDescriptor(name: "codesign", version: "Apple codesign version 83.100.6", platform: "macOS",
                                            architecture: "arm64", recursiveHash: nil)
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    private func configuration(identity: String = "-", allocator: String = "/Toolchain/usr/bin/codesign_allocate",
                               omitting omitted: String? = nil) -> String {
        [
            "toolDescriptor.name=\(descriptor.name)",
            "toolDescriptor.version=\(descriptor.version)",
            "toolDescriptor.platform=\(descriptor.platform)",
            "toolDescriptor.architecture=\(descriptor.architecture)",
            "identity=\(identity)",
            "codesignAllocatePath=\(allocator)",
        ].filter { omitted == nil || !$0.hasPrefix("\(omitted ?? "")=") }.joined(separator: "\n")
    }

    private func tree(_ files: [String: String], executables: Set<String> = []) throws -> NodeValue {
        let entries = try files.map { path, content in
            TreeManifestEntry(path: path, hash: try content.intern(),
                              mode: executables.contains(path) ? FileMetadata.executableMode : FileMetadata.defaultMode)
        }
        return .value(try TreeManifest(entries: entries).toJSON().intern())
    }

    private func process(bundle: String = "Tiny.app", tree: NodeValue, entitlements: String? = nil,
                         configuration: String? = nil) throws -> ProcessOutput {
        var inputs: [String: [String: NodeValue]] = [
            CodeSigner.configuration: ["configuration": .value(try (configuration ?? self.configuration()).intern())],
            CodeSigner.bundle: [bundle: tree],
        ]
        if let entitlements {
            inputs[CodeSigner.entitlements] = ["entitlements": .value(try entitlements.intern())]
        }
        let node = try CodeSigner(thisNode: NodeRecord(id: 1, kind: CodeSigner.kind))
        return try node.process(input: ProcessInput(inputValues: inputs))
    }

    private func errorMessage(_ value: NodeValue?) throws -> String {
        guard case .noValue(.error(let messageHash)) = try XCTUnwrap(value) else {
            XCTFail("expected an error, got \(String(describing: value))")
            return ""
        }
        return try messageHash.resolveAsString()
    }

    // MARK: - The command lines

    /// A bundle with nothing nested is one run: the bundle, ad-hoc, no timestamp, with its
    /// entitlements, and the toolchain's allocator in the environment.
    func test_signsTheBundleAdHocWithItsEntitlements() throws {
        let sandbox = Self.entitlements(["com.apple.security.app-sandbox"])
        let output = try process(tree: try tree(["Contents/MacOS/Tiny": "binary", "Contents/Info.plist": "plist"]),
                                 entitlements: sandbox)

        XCTAssertEqual(executor.invocations.count, 1)
        XCTAssertEqual(executor.lastArguments, ["--force", "--sign", "-", "--timestamp=none",
                                                "--entitlements", "entitlements.plist", "signed/Tiny.app"])
        XCTAssertEqual(executor.lastInputFileNames, ["signed/Tiny.app/Contents/Info.plist", "signed/Tiny.app/Contents/MacOS/Tiny",
                                                     "entitlements.plist"])
        XCTAssertEqual(executor.invocations.last?.environment, ["CODESIGN_ALLOCATE": "/Toolchain/usr/bin/codesign_allocate"])
        XCTAssertEqual(executor.invocations.last?.expectedOutputFolders, ["signed"])
        XCTAssertEqual(executor.lastInputHashes.last, try sandbox.intern(), "entitlements an ad-hoc signature carries go as they are")
        XCTAssertEqual(try output.outputValues[CodeSigner.infoLog]?.expectValue().resolveAsString(), "")
    }

    /// What only a provisioning profile grants would have the process killed at launch
    /// under an ad-hoc signature, so it is left out, and the log says which; the rest is
    /// signed with.
    func test_entitlementsOnlyAProfileGrantsAreLeftOutOfAnAdHocSignature() throws {
        let output = try process(tree: try tree(["Contents/MacOS/Tiny": "binary"]),
                                 entitlements: Self.entitlements(["com.apple.developer.icloud-services", "com.apple.security.app-sandbox",
                                                                  "com.apple.developer.aps-environment", "keychain-access-groups"]))

        let signedWith = try XCTUnwrap(executor.lastInputHashes.last)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(try XCTUnwrap(DataObjectStore.shared.read(hash: signedWith))),
                                                                         format: nil) as? [String: Any])
        XCTAssertEqual(plist.keys.sorted(), ["com.apple.security.app-sandbox"])
        XCTAssertEqual(try output.outputValues[CodeSigner.infoLog]?.expectValue().resolveAsString(),
                       "Left out of the ad-hoc signature, as only a provisioning profile grants them: "
                       + "com.apple.developer.aps-environment, com.apple.developer.icloud-services, keychain-access-groups\n")
    }

    func test_withoutEntitlementsNoneArePassed() throws {
        _ = try process(tree: try tree(["Contents/MacOS/Tiny": "binary"]))

        XCTAssertFalse(executor.lastArguments.contains("--entitlements"), "\(executor.lastArguments)")
        XCTAssertFalse(executor.lastArguments.contains("runtime"), "no hardened runtime unless asked: \(executor.lastArguments)")
    }

    /// `hardenedRuntime` signs the bundle with the hardened runtime, `-o runtime`, where
    /// Xcode 26.6 puts it for a target with `ENABLE_HARDENED_RUNTIME = YES` (`codesign
    /// --force --sign - -o runtime --entitlements … --timestamp=none`); the nested bundles
    /// signed before it keep the flags they have, so an extension's own hardened runtime
    /// survives the app's signing.
    func test_aBundleAskingForTheHardenedRuntimeIsSignedWithIt() throws {
        _ = try process(tree: try tree(["Contents/MacOS/Tiny": "binary", "Contents/PlugIns/Share.appex/Contents/MacOS/Share": "share"]),
                        entitlements: Self.entitlements(["com.apple.security.app-sandbox"]),
                        configuration: configuration() + "\nhardenedRuntime=true")

        XCTAssertEqual(executor.invocations.count, 2)
        XCTAssertEqual(executor.invocations.first?.arguments, ["--force", "--sign", "-", "--timestamp=none",
                                                               "--preserve-metadata=entitlements,flags", "signed/Tiny.app/Contents/PlugIns/Share.appex"])
        XCTAssertEqual(executor.lastArguments, ["--force", "--sign", "-", "--timestamp=none", "-o", "runtime",
                                                "--entitlements", "entitlements.plist", "signed/Tiny.app"])
    }

    /// Nested bundles are signed first, deepest first, keeping the entitlements and flags
    /// each was signed with; the bundle after, with its own.
    func test_signsNestedBundlesDeepestFirstThenTheBundle() throws {
        _ = try process(tree: try tree([
            "Contents/MacOS/Tiny": "binary",
            "Contents/PlugIns/Share.appex/Contents/MacOS/Share": "share",
            "Contents/Frameworks/Kit.framework/Kit": "kit",
            "Contents/Frameworks/Kit.framework/Helpers/Updater.app/Contents/MacOS/Updater": "updater",
            "Contents/Resources/Package_Target.bundle/Assets.car": "car",
        ]), entitlements: Self.entitlements(["com.apple.security.app-sandbox"]))

        XCTAssertEqual(executor.invocations.count, 2)
        XCTAssertEqual(executor.invocations.first?.arguments, [
            "--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=entitlements,flags",
            "signed/Tiny.app/Contents/Frameworks/Kit.framework/Helpers/Updater.app",
            "signed/Tiny.app/Contents/Frameworks/Kit.framework",
            "signed/Tiny.app/Contents/PlugIns/Share.appex",
        ])
        XCTAssertEqual(executor.lastArguments.suffix(3), ["--entitlements", "entitlements.plist", "signed/Tiny.app"])
    }

    /// A versioned framework whose links arrived as copies is laid with the links, and
    /// the signed tree has the copies again, of the signed files.
    func test_aVersionedFrameworksCopiesAreLaidAsLinksAndComeBackAsCopies() throws {
        let framework = "Contents/Frameworks/Tiny.framework"
        executor.producedTrees["signed"] = [
            "Tiny.app/Contents/MacOS/Tiny": Array("signed binary".utf8),
            "Tiny.app/\(framework)/Versions/A/Tiny": Array("signed framework".utf8),
            "Tiny.app/\(framework)/Versions/A/Resources/Info.plist": Array("plist".utf8),
            "Tiny.app/\(framework)/Versions/A/_CodeSignature/CodeResources": Array("seal".utf8),
        ]
        let output = try process(tree: try tree([
            "Contents/MacOS/Tiny": "binary",
            "\(framework)/Versions/A/Tiny": "framework",
            "\(framework)/Versions/A/Resources/Info.plist": "plist",
            "\(framework)/Versions/Current/Tiny": "framework",
            "\(framework)/Versions/Current/Resources/Info.plist": "plist",
            "\(framework)/Tiny": "framework",
            "\(framework)/Resources/Info.plist": "plist",
        ], executables: ["Contents/MacOS/Tiny", "\(framework)/Versions/A/Tiny", "\(framework)/Versions/Current/Tiny", "\(framework)/Tiny"]))

        let layout = SigningLayout(entries: try treeManifest(from: try tree([
            "\(framework)/Versions/A/Tiny": "framework",
            "\(framework)/Versions/Current/Tiny": "framework",
            "\(framework)/Tiny": "framework",
        ])).entries)
        XCTAssertEqual(layout.links, [
            .init(path: "\(framework)/Versions/Current", destination: "A", target: "\(framework)/Versions/A"),
            .init(path: "\(framework)/Tiny", destination: "Versions/Current/Tiny", target: "\(framework)/Versions/A/Tiny"),
        ])
        XCTAssertEqual(executor.invocations.first?.inputFileNames, [
            "signed/Tiny.app/Contents/Frameworks/Tiny.framework/Versions/A/Resources/Info.plist",
            "signed/Tiny.app/Contents/Frameworks/Tiny.framework/Versions/A/Tiny",
            "signed/Tiny.app/Contents/MacOS/Tiny",
            "signed/Tiny.app/Contents/Frameworks/Tiny.framework/Versions/Current",
            "signed/Tiny.app/Contents/Frameworks/Tiny.framework/Resources",
            "signed/Tiny.app/Contents/Frameworks/Tiny.framework/Tiny",
        ], "the files, then the links, outermost first")

        let signed = try treeManifest(from: output.outputValues[CodeSigner.output])
        XCTAssertEqual(signed.entries.map(\.path), [
            "\(framework)/Resources/Info.plist",
            "\(framework)/Tiny",
            "\(framework)/Versions/A/Resources/Info.plist",
            "\(framework)/Versions/A/Tiny",
            "\(framework)/Versions/A/_CodeSignature/CodeResources",
            "\(framework)/Versions/Current/Resources/Info.plist",
            "\(framework)/Versions/Current/Tiny",
            "\(framework)/Versions/Current/_CodeSignature/CodeResources",
            "Contents/MacOS/Tiny",
        ])
        XCTAssertEqual(try signed.entry(at: "\(framework)/Tiny")?.hash.resolveAsString(), "signed framework")
        XCTAssertEqual(signed.entry(at: "\(framework)/Tiny")?.mode, FileMetadata.executableMode, "each file keeps its mode")
        XCTAssertEqual(signed.entry(at: "Contents/MacOS/Tiny")?.mode, FileMetadata.executableMode)
        XCTAssertEqual(signed.entry(at: "\(framework)/Versions/A/_CodeSignature/CodeResources")?.mode, FileMetadata.defaultMode)
    }

    /// `Versions/Current` that is no copy of one version is not taken for a link: the
    /// folder is laid as it came, and codesign says what it makes of it.
    func test_aCurrentThatMatchesNoVersionIsLeftAsItIs() throws {
        let layout = SigningLayout(entries: try treeManifest(from: try tree([
            "Kit.framework/Versions/A/Kit": "one",
            "Kit.framework/Versions/Current/Kit": "another",
            "Kit.framework/Kit": "another",
        ])).entries)

        XCTAssertEqual(layout.links, [])
        XCTAssertEqual(layout.files.count, 3)
    }

    // MARK: - Settings and failures

    /// A named identity is a certificate in a keychain; ad-hoc is the one signed with.
    func test_aNamedIdentityIsRefused() throws {
        XCTAssertThrowsError(try process(tree: try tree(["Contents/MacOS/Tiny": "binary"]),
                                         configuration: configuration(identity: "Apple Development"))) { error in
            XCTAssertTrue("\(error)".contains("signs ad-hoc only"), "\(error)")
            XCTAssertTrue("\(error)".contains("'Apple Development'"), "\(error)")
        }
    }

    func test_theIdentityAndTheAllocatorAreRequired() throws {
        for key in ["identity", "codesignAllocatePath"] {
            XCTAssertThrowsError(try process(tree: try tree(["Contents/MacOS/Tiny": "binary"]),
                                             configuration: configuration(omitting: key)), key) { error in
                XCTAssertTrue("\(error)".contains("apple.codeSigner.\(key)"), "\(error)")
            }
        }
    }

    func test_aFailedRunIsTheToolsError() throws {
        executor.exitCode = 1
        executor.errorOutput = "Tiny.app: bundle format is ambiguous (could be app or framework)"

        let output = try process(tree: try tree(["Contents/MacOS/Tiny": "binary"]))

        let message = try errorMessage(output.outputValues[CodeSigner.output])
        XCTAssertTrue(message.hasPrefix("codesign exited with status 1"), message)
        XCTAssertTrue(message.contains("ambiguous"), message)
    }

    func test_theBundlesWireNamesItsFolder() throws {
        XCTAssertThrowsError(try process(bundle: "Contents/Tiny.app", tree: try tree(["Contents/MacOS/Tiny": "binary"]))) { error in
            XCTAssertTrue("\(error)".contains("names the bundle's folder"), "\(error)")
        }
    }

    func test_codesignsVersionIsItsProjectStamp() {
        let binary = Data("\u{0}garbage@(#)PROGRAM:codesign  PROJECT:codesign-83.100.6\n\u{0}more".utf8)
        XCTAssertEqual(AppleToolDiscovery.codesignVersion(fromBinary: binary), "Apple codesign version 83.100.6")
        XCTAssertNil(AppleToolDiscovery.codesignVersion(fromBinary: Data("no stamp".utf8)))
    }

    // MARK: - This machine

    /// A tiny app — an executable, an Info.plist, a resource, an extension signed with its
    /// own entitlements, and a versioned framework whose links came as copies — signed by
    /// the real codesign twice, each run in sandboxes of its own. The signed tree is the
    /// same bytes both times: an ad-hoc signature has no identity and, with
    /// `--timestamp=none`, no time, and nothing in it names the sandbox (B-89). Written out
    /// with the framework's links as links, the app verifies deep and strict, with its
    /// entitlements on the executable and the extension's kept on the extension, as is the
    /// hardened runtime the extension alone was signed with — NetNewsWire's Debug shape.
    func test_theRealCodesignSignsATinyAppToTheSameBytesTwice() throws {
        let codesign = try XCTUnwrap(AppleToolDiscovery.locate("codesign"), "codesign must be discoverable via xcrun")
        let allocator = try XCTUnwrap(AppleToolDiscovery.locate("codesign_allocate"))
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: try LocalFileSystemTool(localPath: codesign))
        let configuration = self.configuration(allocator: allocator)
        // Any Mach-O signs: the system's `true` stands for the app's, the extension's and
        // the framework's binaries.
        let binary = try DataObjectStore.shared.store(fileAt: URL(fileURLWithPath: "/usr/bin/true"))
        let appEntitlements = Self.entitlements(["com.apple.security.app-sandbox", "com.apple.security.network.client"])
        let extensionEntitlements = Self.entitlements(["com.apple.security.app-sandbox"])

        var trees: [TreeManifest] = []
        for _ in 0..<2 {
            let appex = try sign(bundle: "Share.appex", entries: [
                .init(path: "Contents/MacOS/Share", hash: binary, mode: FileMetadata.executableMode),
                .init(path: "Contents/Info.plist", hash: try Self.infoPlist(executable: "Share", identifier: "com.example.Tiny.Share", type: "XPC!").intern(),
                      mode: FileMetadata.defaultMode),
            ], entitlements: extensionEntitlements, configuration: configuration + "\nhardenedRuntime=true")
            let framework = "Contents/Frameworks/Kit.framework"
            let frameworkPlist = try Self.infoPlist(executable: "Kit", identifier: "com.example.Kit", type: "FMWK").intern()
            var entries: [TreeManifestEntry] = [
                .init(path: "Contents/MacOS/Tiny", hash: binary, mode: FileMetadata.executableMode),
                .init(path: "Contents/Info.plist", hash: try Self.infoPlist(executable: "Tiny", identifier: "com.example.Tiny", type: "APPL").intern(),
                      mode: FileMetadata.defaultMode),
                .init(path: "Contents/Resources/greeting.txt", hash: try "Hello from a signed bundle\n".intern(), mode: FileMetadata.defaultMode),
            ]
            for version in ["A", "Current"] {
                entries.append(.init(path: "\(framework)/Versions/\(version)/Kit", hash: binary, mode: FileMetadata.executableMode))
                entries.append(.init(path: "\(framework)/Versions/\(version)/Resources/Info.plist", hash: frameworkPlist, mode: FileMetadata.defaultMode))
            }
            entries.append(.init(path: "\(framework)/Kit", hash: binary, mode: FileMetadata.executableMode))
            entries.append(.init(path: "\(framework)/Resources/Info.plist", hash: frameworkPlist, mode: FileMetadata.defaultMode))
            entries += appex.entries.map { .init(path: "Contents/PlugIns/Share.appex/\($0.path)", hash: $0.hash, mode: $0.mode) }
            trees.append(try sign(bundle: "Tiny.app", entries: entries, entitlements: appEntitlements, configuration: configuration))
        }

        XCTAssertEqual(trees[0], trees[1], "two signings of one tree are the same bytes")
        let signed = trees[0]
        for seal in ["Contents/_CodeSignature/CodeResources", "Contents/PlugIns/Share.appex/Contents/_CodeSignature/CodeResources",
                     "Contents/Frameworks/Kit.framework/Versions/A/_CodeSignature/CodeResources",
                     "Contents/Frameworks/Kit.framework/Versions/Current/_CodeSignature/CodeResources"] {
            XCTAssertNotNil(signed.entry(at: seal), "\(seal) in \(signed.entries.map(\.path))")
        }
        XCTAssertEqual(signed.entry(at: "Contents/MacOS/Tiny")?.mode, FileMetadata.executableMode)
        XCTAssertNotEqual(signed.entry(at: "Contents/MacOS/Tiny")?.hash, binary, "the executable carries the new signature")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("semel-codesigner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Tiny.app", isDirectory: true)
        try write(signed, to: app)

        let verified = try Self.run(codesign, ["--verify", "--deep", "--strict", "--verbose=2", app.path])
        XCTAssertEqual(verified.status, 0, verified.output)
        let appSigned = try Self.run(codesign, ["-d", "--entitlements", ":-", app.path])
        XCTAssertTrue(appSigned.output.contains("com.apple.security.network.client"), appSigned.output)
        let extensionSigned = try Self.run(codesign, ["-d", "--entitlements", ":-", app.appendingPathComponent("Contents/PlugIns/Share.appex").path])
        XCTAssertTrue(extensionSigned.output.contains("com.apple.security.app-sandbox"), extensionSigned.output)
        XCTAssertFalse(extensionSigned.output.contains("com.apple.security.network.client"), "the extension keeps its own: \(extensionSigned.output)")
        let details = try Self.run(codesign, ["-dv", app.path])
        XCTAssertTrue(details.output.contains("Signature=adhoc"), details.output)
        XCTAssertFalse(details.output.contains("runtime"), "the app asked for no hardened runtime: \(details.output)")
        let extensionDetails = try Self.run(codesign, ["-dv", app.appendingPathComponent("Contents/PlugIns/Share.appex").path])
        XCTAssertTrue(extensionDetails.output.contains("flags=0x10002(adhoc,runtime)"),
                      "the extension's hardened runtime survives the app's signing: \(extensionDetails.output)")
    }

    private func sign(bundle: String, entries: [TreeManifestEntry], entitlements: String, configuration: String) throws -> TreeManifest {
        let node = try CodeSigner(thisNode: NodeRecord(id: 1, kind: CodeSigner.kind))
        let output = try node.process(input: ProcessInput(inputValues: [
            CodeSigner.configuration: ["configuration": .value(try configuration.intern())],
            CodeSigner.bundle: [bundle: .value(try TreeManifest(entries: entries).toJSON().intern())],
            CodeSigner.entitlements: ["entitlements": .value(try entitlements.intern())],
        ]))
        if case .noValue(.error(let messageHash)) = output.outputValues[CodeSigner.output] {
            XCTFail("\(bundle): \(try messageHash.resolveAsString())")
        }
        return try treeManifest(from: output.outputValues[CodeSigner.output])
    }

    /// The tree as files under `folder`, each with its mode, and a versioned framework's
    /// copies as the links they stand for — what a bundle is before it is pushed.
    private func write(_ tree: TreeManifest, to folder: URL) throws {
        let layout = SigningLayout(entries: tree.entries)
        for entry in layout.files {
            let url = folder.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(try XCTUnwrap(DataObjectStore.shared.read(hash: entry.hash))).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: entry.mode)], ofItemAtPath: url.path)
        }
        for link in layout.links {
            try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent(link.path).path,
                                                       withDestinationPath: link.destination)
        }
    }

    private static func entitlements(_ keys: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>\(keys.map { "<key>\($0)</key><true/>" }.joined())</dict></plist>
        """
    }

    private static func infoPlist(executable: String, identifier: String, type: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleExecutable</key><string>\(executable)</string>\
        <key>CFBundleIdentifier</key><string>\(identifier)</string>\
        <key>CFBundlePackageType</key><string>\(type)</string></dict></plist>
        """
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
