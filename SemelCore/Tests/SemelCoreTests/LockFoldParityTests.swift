//
//  LockFoldParityTests.swift
//  SemelCore
//

@testable import SemelCore
import Darwin
import SemelNodeKit
import XCTest

/// The lock `semel-swift prepare` writes beside a vendored dependency records the root
/// `FolderContentRoot.root(ofFolderAt:)` folds from the copy on disk; the converter compares
/// it with the root the engine folds over the pushed copy (B-06). Each case here crafts one
/// shape on disk, folds it both ways and asks that the two agree, so that a shape the two
/// folds read differently is named by the case it breaks rather than found on a tree nobody
/// can share (B-143).
///
/// The push is the client's for a folder the server does not hold: every entry
/// `FolderOnDisk.entriesToPush` lists, a file read through `PushedContent` as the client
/// reads it and one it cannot read skipped as the client skips it, then the settle's flush.
final class LockFoldParityTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var disk: URL!
    /// Paths given the immutable flag or a mode that stops their removal, put right before
    /// the tree is removed.
    private var immutablePaths: [String] = []
    private var unreadablePaths: [String] = []

    private let package = "Dependencies/Pkg"

    private var packageURL: URL {
        disk.appendingPathComponent(package, isDirectory: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        disk = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-lock-parity-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        // Every package holds one plain file, so a case whose shape a fold leaves out still
        // compares a root over something.
        try write("Package.swift", "// swift-tools-version: 5.9\n")
    }

    override func tearDownWithError() throws {
        engine = nil
        for path in immutablePaths {
            _ = chflags(path, 0)
        }
        for path in unreadablePaths {
            _ = chmod(path, 0o755)
        }
        // `rm`, which walks a tree deeper than `PATH_MAX` where `FileManager` cannot.
        let remover = Process()
        remover.executableURL = URL(fileURLWithPath: "/bin/rm")
        remover.arguments = ["-rf", disk.path]
        try remover.run()
        remover.waitUntilExit()
        try super.tearDownWithError()
    }

    // MARK: - Building shapes

    private func absolutePath(_ relativePath: String) -> String {
        packageURL.appendingPathComponent(relativePath).path
    }

    private func write(_ relativePath: String, _ content: String, mode: UInt16? = nil) throws {
        try write(relativePath, Data(content.utf8), mode: mode)
    }

    private func write(_ relativePath: String, _ content: Data, mode: UInt16? = nil) throws {
        let url = packageURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url)
        if let mode {
            try setMode(of: relativePath, to: mode)
        }
    }

    private func setMode(of relativePath: String, to mode: UInt16) throws {
        guard chmod(absolutePath(relativePath), mode_t(mode)) == 0 else {
            throw ShapeError.call("chmod \(String(mode, radix: 8)) \(relativePath)", errno)
        }
    }

    private func link(_ relativePath: String, to target: String) throws {
        let url = packageURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    private func makeFolder(_ relativePath: String) throws {
        try FileManager.default.createDirectory(at: packageURL.appendingPathComponent(relativePath),
                                                withIntermediateDirectories: true)
    }

    private enum ShapeError: Error {
        case call(String, Int32)
    }

    // MARK: - The comparison

    /// What `push <package>` stores for a server that holds nothing below it.
    private func push() throws {
        let onDisk = FolderOnDisk.read(Path(package), under: disk.path)
        for entry in onDisk.entriesToPush {
            switch entry.kind {
            case .folder:
                guard let target = entry.symbolicLinkTarget else {
                    continue
                }
                _ = try Folder.pushSymbolicLink(target: target, at: entry.path)
            case .file:
                let absolute = disk.appendingPathComponent(entry.path.string).path
                guard let content = try? PushedContent(ofFileAt: absolute, listedAs: entry) else {
                    continue
                }
                _ = try StaticFile.push([UInt8](content.bytes), mode: content.mode,
                                        symbolicLinkTarget: content.symbolicLinkTarget, at: entry.path)
            }
        }
        try Folder.flushDirtyManifests()
    }

    /// The document behind a root the engine folded, and each subfolder's below it, for a
    /// failure to show where the two folds parted.
    private func engineDocuments(of folder: String) throws -> String {
        let node = try XCTUnwrap(try engine.inputFileSystem.childNode(path: Path(folder)))
        let root = try node.readFromOutputPort(Folder.contentRootOutputPort).expectValue()
        var text = "\(folder):\n\(try root.resolveAsString())"
        for child in try node.allChildren where child.kind == Folder.kind {
            text += try engineDocuments(of: "\(folder)/\(try child.requireName())")
        }
        return text
    }

    /// Folds the package on disk, pushes it, runs `afterPush` — what else a build does to
    /// the graph below the package — and asks that the engine's pushed root, which the lock
    /// check compares, is the one the lock would record. Where nothing but the push touched
    /// the package, the whole root is that root too, as the graph holds only what was sent.
    private func assertTheFoldsAgree(_ shape: String, hiddenFiles: [String] = [], onlyThePush: Bool = true,
                                     afterPush: () throws -> Void = {},
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let recorded = try FolderContentRoot.root(ofFolderAt: packageURL, hiddenFiles: hiddenFiles)
        try push()
        try afterPush()
        try Folder.flushDirtyManifests()
        let node = try XCTUnwrap(try engine.inputFileSystem.childNode(path: Path(package)), file: file, line: line)
        let pushed = try node.readFromOutputPort(Folder.pushedContentRootOutputPort).expectValue()
        if recorded != pushed {
            XCTFail("\(shape): the lock records \(recorded) and the engine's pushed root is \(pushed)\n"
                    + "\(try engineDocuments(of: package))", file: file, line: line)
        }
        let whole = try node.readFromOutputPort(Folder.contentRootOutputPort).expectValue()
        let leftOut = try FolderContentRoot.entriesLeftOutOfThePushedRoot(below: whole)
        if onlyThePush {
            XCTAssertEqual(whole, recorded, "\(shape): the graph holds only what was pushed", file: file, line: line)
        }
        if (whole == pushed) != leftOut.isEmpty {
            XCTFail("\(shape): the whole root \(whole) and the pushed root \(pushed) disagree with what is left out, "
                    + "\(leftOut)\n\(try engineDocuments(of: package))", file: file, line: line)
        }
    }

    /// The whole root below the package, as the lock check reads it to name what it left
    /// out.
    private func leftOut() throws -> [LeftOutEntry] {
        let node = try XCTUnwrap(try engine.inputFileSystem.childNode(path: Path(package)))
        return try FolderContentRoot.entriesLeftOutOfThePushedRoot(
            below: try node.readFromOutputPort(Folder.contentRootOutputPort).expectValue())
    }

    // MARK: - Modes

    /// The modes a checkout made under another umask, or by `git` from a tree that records
    /// them, leaves: every bit `stat` reports below the file type is the mode a push sends
    /// and the fold on disk reads.
    func test_fileModesOtherThan644And755FoldAlike() throws {
        for mode: UInt16 in [0o600, 0o664, 0o640, 0o444, 0o775, 0o700, 0o4755, 0o2755] {
            try write("modes/file-\(String(mode, radix: 8))", "mode \(mode)\n", mode: mode)
        }
        try assertTheFoldsAgree("modes")
    }

    /// The sticky bit on a file, where the system lets an owner set it: on macOS it does
    /// not (`EFTYPE`), and the case says so rather than testing a mode that cannot exist.
    func test_aStickyFileFoldsAlike() throws {
        try write("sticky", "sticky\n")
        guard chmod(absolutePath("sticky"), 0o1644) == 0 else {
            throw XCTSkip("chmod 1644 on a file: errno \(errno), a mode a checkout cannot leave here")
        }
        try assertTheFoldsAgree("sticky")
    }

    // MARK: - Links

    func test_aLinkToAFileInsideTheFolder() throws {
        try write("Sources/real.swift", "real\n")
        try link("Sources/alias.swift", to: "real.swift")
        try link("deep-alias.swift", to: "Sources/real.swift")
        try assertTheFoldsAgree("link to a file inside")
    }

    func test_aLinkToAFolderInsideTheFolder() throws {
        try write("Versions/A/Headers/Tiny.h", "tiny\n")
        try link("Versions/Current", to: "A")
        try link("Headers", to: "Versions/Current/Headers")
        try assertTheFoldsAgree("link to a folder inside")
    }

    func test_aLinkToAPathOutsideTheFolder() throws {
        let shared = disk.appendingPathComponent("Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared.appendingPathComponent("include"), withIntermediateDirectories: true)
        try Data("outside\n".utf8).write(to: shared.appendingPathComponent("outside.h"))
        try Data("inside\n".utf8).write(to: shared.appendingPathComponent("include/inner.h"))
        try link("outside.h", to: "../../Shared/outside.h")
        try link("include", to: "../../Shared/include")
        try link("absolute.h", to: shared.appendingPathComponent("outside.h").path)
        try assertTheFoldsAgree("link outside")
    }

    func test_anAbsoluteLinkToAFileInsideTheFolder() throws {
        try write("real.txt", "real\n")
        try link("absolute.txt", to: absolutePath("real.txt"))
        try assertTheFoldsAgree("absolute link inside")
    }

    func test_aDanglingLink() throws {
        try link("dangling-inside", to: "missing.swift")
        try link("dangling-outside", to: "../../missing.swift")
        try link("only-dangling/dangling", to: "nothing")
        try link("loop-one", to: "loop-two")
        try link("loop-two", to: "loop-one")
        try assertTheFoldsAgree("dangling link")
    }

    /// The lister refuses a link to a folder above it, which would walk for ever; both
    /// sides use the lister, so both leave it out.
    func test_aLinkToAFolderAboveItself() throws {
        try write("Sources/a.swift", "a\n")
        try link("Sources/up", to: "..")
        try link("Sources/top", to: "../..")
        try link("Sources/here", to: ".")
        try link("Sources/absoluteUp", to: packageURL.path)
        try assertTheFoldsAgree("link above itself")
    }

    func test_aHardLink() throws {
        try write("original.swift", "shared bytes\n", mode: 0o640)
        guard Darwin.link(absolutePath("original.swift"), absolutePath("hard.swift")) == 0 else {
            throw ShapeError.call("link", errno)
        }
        try assertTheFoldsAgree("hard link")
    }

    /// A file nobody may read, with a link inside the folder to it: a push skips what it
    /// cannot read and goes on, so the root it leaves is not the tree's, and the fold on
    /// disk refuses rather than record a root over a file it did not see. A link whose
    /// referent is unreadable cannot get past this: a link inside its folder names a file
    /// the walk reaches, and one outside is followed and read.
    func test_aFileNobodyCanReadStopsTheFoldOnDisk() throws {
        try write("secret", "secret\n")
        try link("alias", to: "secret")
        try setMode(of: "secret", to: 0o000)
        unreadablePaths.append(absolutePath("secret"))
        XCTAssertThrowsError(try FolderContentRoot.root(ofFolderAt: packageURL))
    }

    // MARK: - Folders with nothing a push sends

    /// "No folder without a file below it": a push makes a folder only on the way to a
    /// file, so the fold on disk leaves out a folder holding nothing it would send.
    func test_anEmptyFolderAndAFolderHoldingOnlyEmptyFolders() throws {
        try makeFolder("Empty")
        try makeFolder("Hollow/Deeper/Deepest")
        try makeFolder("Hollow/Other")
        try write("OnlyDotFiles/.keep", "")
        try write("OnlyDotFiles/.hidden/inner", "x")
        try link("OnlyADanglingLink/gone", to: "nowhere")
        try assertTheFoldsAgree("empty folders")
    }

    /// A folder the walk cannot list is one it sees nothing in, on both sides.
    func test_aFolderNobodyCanList() throws {
        try write("Locked/inside.swift", "inside\n")
        try setMode(of: "Locked", to: 0o000)
        unreadablePaths.append(absolutePath("Locked"))
        try assertTheFoldsAgree("unlistable folder")
    }

    // MARK: - Names

    /// Every dot-name is left out by both, whatever is below it: a dot-folder holding
    /// plain files, a plain folder inside a dot-folder, a dot-file beside sources at each
    /// level, and a folder whose only content is dot-named.
    func test_dotNamesAtEveryLevel() throws {
        try write(".gitignore", ".build\n")
        try write(".swift-version", "6.0\n")
        try write(".github/workflows/ci.yml", "on: push\n")
        try write(".config/Plain/Settings.swift", "inside a plain folder inside a dot-folder\n")
        try write(".config/Plain/Deeper/More.swift", "deeper\n")
        try write("Sources/.DS_Store", "finder")
        try write("Sources/Lib/.swiftlint.yml", "rules")
        try write("Sources/Lib/.hidden/Code.swift", "hidden")
        try write("Sources/Lib/.hidden/.inner/Code.swift", "hidden twice")
        try write("Sources/Lib/Code.swift", "code\n")
        try write("Sources/Lib/..double", "double dot")
        try write("Sources/Lib/Resources/.keep", "")
        try write("Sources/Lib/Resources/data.json", "{}\n")
        try write("Tests/.only-dots/.inside", "dots all the way")
        try assertTheFoldsAgree("dot names")
    }

    /// A dot-named file the package's manifest declares as a resource is named by the lock
    /// `prepare` writes, which folds it in; a push of the folder, which reads the lock
    /// beside it, sends it, so the engine's pushed root holds it and the two agree: the
    /// file the build reads is locked (B-143). A dot-name the lock does not name is left
    /// out by both, at any level.
    func test_aDotNamedFileTheLockNamesIsLockedAndPushed() throws {
        try write("Sources/Lib/Code.swift", "code\n")
        try write("Sources/Lib/Resources/.config.json", "{}\n")
        try write(".env", "declared at the root\n")
        try write("Sources/Lib/.swiftlint.yml", "rules\n")
        let hidden = [".env", "Sources/Lib/Resources/.config.json"]
        let lock = DependencyLock(contentRoot: "-", fold: FolderContentRoot.formatTag, hiddenFiles: hidden)
        try Data(lock.text.utf8).write(to: disk.appendingPathComponent(DependencyLock.lockPath(forDependencyAt: package)))

        try assertTheFoldsAgree("declared dot-file", hiddenFiles: hidden)

        XCTAssertNotEqual(try FolderContentRoot.root(ofFolderAt: packageURL, hiddenFiles: hidden),
                          try FolderContentRoot.root(ofFolderAt: packageURL), "the named files are in the root")
        XCTAssertEqual(try leftOut(), [])
    }

    /// A dot-named file pushed into the folder by its name and named by no lock — `push
    /// <path>/.swiftlint.yml`, a watcher's `--only` — is in the pushed root, as a push of
    /// the folder sends every dot-named file the graph holds: the build would read a file
    /// the lock does not describe, and the lock fails on it rather than leave it out.
    func test_aDotNamedFileHeldByNameAndNamedByNoLockIsCompared() throws {
        try write("Sources/Lib/Code.swift", "code\n")
        try write("Sources/Lib/.swiftlint.yml", "rules\n")
        let recorded = try FolderContentRoot.root(ofFolderAt: packageURL)
        try push()
        _ = try StaticFile.push(Array("rules\n".utf8), mode: FileMetadata.defaultMode, at: Path("\(package)/Sources/Lib/.swiftlint.yml"))
        try Folder.flushDirtyManifests()

        let node = try XCTUnwrap(try engine.inputFileSystem.childNode(path: Path(package)))
        XCTAssertNotEqual(try node.readFromOutputPort(Folder.pushedContentRootOutputPort).expectValue(), recorded)
        XCTAssertEqual(try node.readFromOutputPort(Folder.pushedContentRootOutputPort).expectValue(),
                       try FolderContentRoot.root(ofFolderAt: packageURL, hiddenFiles: ["Sources/Lib/.swiftlint.yml"]))
        XCTAssertEqual(try leftOut(), [], "nothing is left out: the file is compared")
    }

    /// A name a converter asks for below the package that the copy does not have — a
    /// target's default `Sources/<Target>`, a declared resource — is a ghost: a file or a
    /// folder nobody pushed, in the folder's whole root as not produced. The copy's fold
    /// cannot see it, and the pushed root leaves it out, so the lock holds.
    func test_aGhostDemandedBelowThePackageIsLeftOutOfTheComparedRoot() throws {
        try write("Sources/Lib/Code.swift", "code\n")
        try assertTheFoldsAgree("ghost demand", onlyThePush: false) {
            let input = Folder.inputFileSystemName
            for spec in ["StaticFile(path: '\(input)/\(package)/Sources/Lib/Resources/missing.json')",
                         "StaticFile(path: '\(input)/\(package)/PrivacyInfo.xcprivacy')",
                         "Folder(path: '\(input)/\(package)/Sources/Missing').manifest"] {
                _ = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()
            }
        }
        let leftOut = try leftOut()
        XCTAssertTrue(leftOut.contains(LeftOutEntry(path: "PrivacyInfo.xcprivacy", reason: .notPushed)), "\(leftOut)")
        XCTAssertTrue(leftOut.contains(LeftOutEntry(path: "Sources/Lib/Resources/missing.json", reason: .notPushed)),
                      "\(leftOut)")
    }

    /// Hidden by the `UF_HIDDEN` flag (`chflags hidden`) rather than by name: Finder hides
    /// it and Foundation's `.skipsHiddenFiles` skips it, but nothing that pushes or folds
    /// enumerates with that option, so both read it as the plain file or folder it is.
    func test_aFileAndAFolderHiddenByTheFlagRatherThanByName() throws {
        try write("Flagged.swift", "hidden by flag\n")
        try write("FlaggedFolder/Inside.swift", "inside a flagged folder\n")
        for relativePath in ["Flagged.swift", "FlaggedFolder"] {
            guard chflags(absolutePath(relativePath), UInt32(UF_HIDDEN)) == 0 else {
                throw ShapeError.call("chflags hidden \(relativePath)", errno)
            }
        }
        let flagged = try packageURL.appendingPathComponent("Flagged.swift").resourceValues(forKeys: [.isHiddenKey])
        XCTAssertEqual(flagged.isHidden, true)
        try assertTheFoldsAgree("hidden by flag")
    }

    /// APFS keeps the form a name was made in and HFS+ decomposes it; either way the lister
    /// hands both sides the one form the disk gives, and the fold orders by its bytes.
    func test_namesInNFCAndNFD() throws {
        try write("Composed/caf\u{E9}.swift", "nfc\n")
        try write("Decomposed/cafe\u{301}.swift", "nfd\n")
        try write("Mixed/\u{C5}ngstr\u{F6}m", "nfc\n")
        try write("Mixed/A\u{30A}ngstro\u{308}m-decomposed", "nfd\n")
        try write("Mixed/\u{1F600}", "emoji\n")
        try write("Mixed/z", "after every multi-byte name by bytes\n")
        try link("Mixed/link-to-cafe\u{301}", to: "../Decomposed/cafe\u{301}.swift")
        try assertTheFoldsAgree("NFC and NFD names")
    }

    func test_namesWithSpacesQuotesAndControlCharacters() throws {
        try write("with space.swift", "space\n")
        try write("it's \"quoted\".swift", "quotes\n")
        try write("new\nline.swift", "newline\n")
        try write("tab\there.swift", "tab\n")
        try write("back\\slash", "backslash\n")
        try write("colon:name", "colon\n")
        try write("-leading-dash", "dash\n")
        try write("Folder With Space/inner file", "inner\n")
        try link("link with space", to: "with space.swift")
        try assertTheFoldsAgree("names with spaces, quotes and control characters")
    }

    /// The case-insensitive volume `/tmp` and `NSTemporaryDirectory()` are on here keeps
    /// only one of two names that differ in case; a link may still name its target in
    /// another case, and resolve.
    func test_aLinkNamingItsTargetInAnotherCase() throws {
        try write("Versions/A/Headers/Tiny.h", "tiny\n")
        try link("Versions/Current", to: "a")
        try link("Headers", to: "versions/current/headers")
        try assertTheFoldsAgree("case-only difference")
    }

    // MARK: - Sizes

    func test_aZeroLengthFile() throws {
        try write("Empty.swift", "")
        try write("Nested/Empty.swift", "", mode: 0o755)
        try assertTheFoldsAgree("zero-length file")
    }

    /// Larger than one push request's bytes (`FilePlugin.bytesPerRequest`, 8 MB).
    func test_aFileLargerThanAPushBatch() throws {
        try write("Resources/large.bin", Data(repeating: 0x5A, count: (8 << 20) + 4_096))
        try assertTheFoldsAgree("file over 8 MB")
    }

    /// A tree whose deepest folder is over `PATH_MAX` (1,024 bytes) from the root: made a
    /// folder at a time by descriptor, since no call takes a path that long.
    func test_aPathLongerThanPathMax() throws {
        let component = String(repeating: "d", count: 200)
        var descriptor = open(packageURL.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw ShapeError.call("open", errno)
        }
        for depth in 0..<7 {
            guard mkdirat(descriptor, component, 0o755) == 0 else {
                throw ShapeError.call("mkdirat at depth \(depth)", errno)
            }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY)
            close(descriptor)
            guard next >= 0 else {
                throw ShapeError.call("openat at depth \(depth)", errno)
            }
            descriptor = next
            let fileDescriptor = openat(descriptor, "at-depth-\(depth).txt", O_CREAT | O_WRONLY, 0o644)
            guard fileDescriptor >= 0 else {
                throw ShapeError.call("openat file at depth \(depth)", errno)
            }
            _ = "depth \(depth)\n".withCString { Darwin.write(fileDescriptor, $0, strlen($0)) }
            close(fileDescriptor)
        }
        close(descriptor)
        try assertTheFoldsAgree("path over PATH_MAX")
    }

    // MARK: - Names other code knows

    func test_aFileNamedLikeALockInsideTheFolder() throws {
        try write("Pkg.semel-lock", "content sha256:0\nfold x\n")
        try write("Nested/Other.semel-lock", "not a lock")
        try write("Nested/.semel-lock", "dot lock")
        try assertTheFoldsAgree("lock-like names")
    }

    /// A folder named as a file the converter or the lister reads.
    func test_aFolderNamedLikeAFile() throws {
        try write("Package.swift.d/Package.swift/inner.txt", "inside a folder named Package.swift\n")
        try write("Sub.semel-lock/inside.txt", "inside a folder named like a lock\n")
        try write("semel.fmla/inside.txt", "inside a folder named like a formula\n")
        try write("Thing.xcframework/Info.plist", "plist")
        try assertTheFoldsAgree("folders named like files")
    }

    /// What `prepare` unzips with `ditto`: a framework of links and files of several modes.
    func test_aSemelArtifactsFolderWithMixedModes() throws {
        let framework = "semel-artifacts/Tiny/Tiny.xcframework/macos-arm64_x86_64/Tiny.framework"
        try write("semel-artifacts/Tiny/Tiny.xcframework/Info.plist", "plist", mode: 0o644)
        try write("\(framework)/Versions/A/Tiny", "binary", mode: 0o755)
        try write("\(framework)/Versions/A/Headers/Tiny.h", "header", mode: 0o444)
        try write("\(framework)/Versions/A/Resources/Info.plist", "plist", mode: 0o664)
        try write("\(framework)/Versions/A/_CodeSignature/CodeResources", "signature", mode: 0o600)
        try link("\(framework)/Versions/Current", to: "A")
        for name in ["Tiny", "Headers", "Resources"] {
            try link("\(framework)/\(name)", to: "Versions/Current/\(name)")
        }
        try assertTheFoldsAgree("semel-artifacts")
    }

    // MARK: - What is neither a file nor a folder

    /// A named pipe: opening one to read waits for a writer, so a fold that reads it never
    /// returns. Neither side can hold one, so neither lists it.
    func test_aFIFOInTheTree() throws {
        guard mkfifo(absolutePath("pipe"), 0o644) == 0 else {
            throw ShapeError.call("mkfifo", errno)
        }
        try makeFolder("Pipes")
        guard mkfifo(absolutePath("Pipes/only-a-pipe"), 0o644) == 0 else {
            throw ShapeError.call("mkfifo", errno)
        }
        try link("link-to-pipe", to: "pipe")
        try assertTheFoldsAgree("FIFO")
    }

    /// A socket a tool left in the tree: it cannot be opened, so a fold that reads it
    /// cannot fold the folder, while a push skips it and goes on.
    func test_aSocketInTheTree() throws {
        try makeSocket(at: absolutePath("daemon.sock"))
        try assertTheFoldsAgree("socket")
    }

    /// Bound at a short path, as `sun_path` holds 104 bytes, and moved into the tree.
    private func makeSocket(at path: String) throws {
        let shortPath = "/tmp/semel-\(UUID().uuidString.prefix(8)).sock"
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ShapeError.call("socket", errno)
        }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(shortPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            throw ShapeError.call("bind", errno)
        }
        guard rename(shortPath, path) == 0 else {
            let failure = errno
            unlink(shortPath)
            throw ShapeError.call("rename", failure)
        }
    }

    // MARK: - Metadata a fold does not read

    func test_aFileWithExtendedAttributesAndTheImmutableFlag() throws {
        try write("Downloaded.swift", "downloaded\n")
        let quarantine = Array("0081;00000000;Safari;".utf8)
        guard setxattr(absolutePath("Downloaded.swift"), "com.apple.quarantine", quarantine, quarantine.count, 0, 0) == 0 else {
            throw ShapeError.call("setxattr", errno)
        }
        try write("Frozen.swift", "frozen\n")
        guard chflags(absolutePath("Frozen.swift"), UInt32(UF_IMMUTABLE)) == 0 else {
            throw ShapeError.call("chflags", errno)
        }
        immutablePaths.append(absolutePath("Frozen.swift"))
        try assertTheFoldsAgree("extended attributes and immutable flag")
    }
}
