// ErrorCondition.swift
// SemelNodeKit
//
// Every condition of the engine and its nodes that reaches an error report, as a value.
//
// A node that cannot produce says why with one of these, and the client renders the
// sentence; nothing that crosses a port is a sentence the engine composed. Each case
// carries the values its sentence needs and no more, so two runs of the same failing
// inputs publish the same document, and a client can act on a value — a path to push, a
// key to set — without taking text apart.
//
// A new condition is a new case. The client's renderer switches over every case without a
// `default`, so a case nobody renders does not compile.

import Foundation

/// An error that names its condition, so the engine publishes it as a typed document
/// rather than as its description.
///
/// The typed errors inside the engine and the toolchains — `NodeError`, the applier's,
/// the converters' — conform where they are declared; each maps to the condition a report
/// shows for it.
public protocol ErrorConditionConvertible: Error {
    var errorCondition: ErrorCondition { get }
}

public enum ErrorCondition: Codable, Hashable, Sendable, Error, ErrorConditionConvertible {

    // MARK: - Tools

    /// A tool that failed and printed nothing on either stream: the one case in which its
    /// exit status is information.
    case toolExitedSilently(tool: String, status: Int32)
    /// A tool that exited cleanly and did not write what it was asked for, by the paths
    /// relative to its sandbox.
    case toolWroteNothing(tool: String, status: Int32, paths: [String])
    /// A node's settings name a tool this machine does not have. `namespace` is the
    /// settings' — `clang.compiler`; `available` every tool of the name that is installed;
    /// `writer` what rewrites the machine file the setting most likely came from, written
    /// before the toolchain changed (B-109).
    case toolNotInstalled(requested: ToolIdentity, available: [ToolIdentity], namespace: String,
                          writer: MachineFileCommand?)
    /// A tool path in the settings with nothing there.
    case toolNotFound(path: String)
    /// A tool path in the settings with a file there that cannot be run.
    case toolNotExecutable(path: String)
    /// An input could not be laid in the tool's sandbox: the file, and what the file
    /// system said.
    case toolInputNotWritten(file: String, reason: String)
    /// An output the tool was expected to write could not be read back.
    case toolOutputNotRead(file: String)
    /// The tool's process could not be started: what the system said.
    case toolLaunchFailed(reason: String)

    // MARK: - Settings

    /// Settings a node needs that its configuration does not hold, split by whose they
    /// are: the project's choices, and the machine's facts that a toolchain's own command
    /// writes (B-109). Keys fully qualified, sorted. `writer` is the command the namespace's
    /// toolchain registered for the machine file, when it registered one.
    case settingsMissing(project: [String], machine: [String], writer: MachineFileCommand?)
    /// A setting whose value is not one the node takes.
    case settingNotAccepted(key: String, value: String, accepted: [String])
    /// A setting that holds a list, as JSON, and whose value is not one.
    case settingNotAList(key: String, value: String)
    /// An SDK the settings name that this machine does not have; `key` names it.
    case sdkNotFound(sdk: String, key: String)
    /// An SDK version the settings declare that is not this machine's: `found` is what the
    /// machine has, nil when it has no such SDK at all. A declared version without a build
    /// number is never a match, since the build number is part of what is declared.
    case sdkVersionDiffers(sdk: String, declared: String, found: String?)
    /// A setting only one value of which is built with: `CodeSigner` signs ad hoc.
    case settingNotSupported(key: String, value: String, supported: String)

    // MARK: - Sources

    /// A source the formula names and nobody has pushed. `path` in the input file system,
    /// `input:/…`; a folder is the whole tree the formula asked for.
    case notPushed(path: String, isFolder: Bool)
    /// A source pushed and then removed, which something still reads.
    case removed(path: String?, isFolder: Bool)
    /// A node that carries an input's failure and whose cause is no longer in the graph,
    /// so it stands in for it.
    case inputInError
    /// An error port whose document cannot be read back from the object store.
    case documentUnreadable(hash: String)

    // MARK: - Types and the graph

    /// A node row of a kind this server does not link (B-130).
    case unlinkedKind(kind: UInt)
    /// A spec or a formula names a type no plugin registers.
    case unknownTypeName(name: String)
    /// A type's required input port with nothing wired to it.
    case requiredPortUnwired(type: String?, port: String)
    /// A port that takes one wire, with several wired to it, by name, sorted (B-141).
    case severalWiresOnOneWirePort(type: String?, port: String, wires: [String])
    /// A formula or a node reads a port its type does not declare.
    case portNotDeclared(type: String?, port: String)
    /// A node holding no row for an output port its type declares: a damaged graph.
    case outputPortMissing(nodeID: Int64, port: String)
    /// A node whose row lacks a property its type is always created with.
    case nodePropertyMissing(kind: UInt, nodeID: Int64?, property: String)
    /// A node given no value for a property it needs: `XcodeProjectConverter` without a
    /// `path`. `alternatives` names the other ways to give it what it needs, if any.
    case propertyMissing(type: String, property: String, alternatives: [String])
    /// A node given both or neither of two properties it takes exactly one of.
    case propertiesExclusive(type: String, properties: [String])
    /// A property whose value is not of the form the node reads.
    case propertyNotOfForm(type: String, property: String, form: ValueForm)
    /// A wire whose value is not of the form the port reads.
    case inputNotOfForm(port: String, wire: String, form: ValueForm)
    /// A wire whose value names nothing in the object store.
    case inputHasNoContent(port: String, wire: String)
    /// A source node asked to process, which nothing schedules in a working graph.
    case sourceCannotProcess(type: String)
    /// A node that cannot be processed at all.
    case processNotSupported(type: String?)
    /// A node type that takes no properties, given some.
    case cannotHaveProperties
    /// A node whose outputs are still wired, asked to be deleted.
    case cannotDeleteNodeWithOutputs
    /// No node where one was asked for.
    case nodeNotFound
    /// Two children of one folder under one name.
    case nameCollision(path: String, existingKind: UInt)
    /// A graph whose shape is not its spec's.
    case graphSpecBadIntegrity(found: String, expected: String, log: String)
    /// A spec whose source names no output port to take a value from.
    case wireWithoutOutputPort(wire: String?, type: String)
    /// A spec table that files a row under an identity its row does not give it.
    case identityMismatch(type: String, filedUnder: String, computed: String)
    /// A wire asked for under an empty name.
    case emptyWireName
    /// A spec table naming a node it holds no row for.
    case specTableMissingRow(identity: String)
    /// A spec table with a node among its own sources.
    case specTableCycle(identity: String)
    /// A spec text that cannot be read back: what was met, and where.
    case specUnreadable(found: String?, context: String)
    /// A wire name an input port already holds, for a different source.
    case duplicateWireName(name: String)
    /// A wire that could not be disconnected.
    case wireNotDisconnected
    /// A wire that would make the graph circular.
    case circularWiring(fromNodeID: Int64, toNodeID: Int64)
    /// A static port wired after its node was made (B-115).
    case staticPortWiredAfterCreation(type: String, port: String)
    /// A source with no identity, so nothing wired from it can compute its own.
    case sourceWithoutIdentity(nodeID: Int64)
    /// A node that has not been saved, asked for its id.
    case nodeNotPersisted(kind: UInt, name: String?)
    /// A node that has no name, asked for it.
    case nodeHasNoName(kind: UInt?, nodeID: Int64?)
    /// A path in the input or output file system with no folder at it.
    case noSuchFolder(path: String)
    /// A folder child of a kind no file system listing knows.
    case unexpectedNodeKind(kind: UInt)
    /// A folder that cannot be deleted because something below it must stay.
    case folderNotDeletable(path: String?)
    /// A decoded value whose type is not the one asked for.
    case unexpectedValueType
    /// A kind registered to something that is not serialisable, or not a node.
    case kindNotSerializable(kind: UInt)
    case kindNotANode(kind: UInt)
    /// Two types claiming one kind.
    case duplicateKind(kind: UInt, existing: String, duplicate: String)

    // MARK: - Values

    /// A stored object whose bytes are not the ones it is filed under; deleting the file
    /// makes it rebuild.
    case objectCorrupted(path: String, expected: String, found: String)
    /// A value on a port that is not of the form the reader takes: a folder manifest on a
    /// port that carries one, keyed by the wire.
    case valueUnreadable(form: ValueForm, port: String?, wire: String)
    /// A subtree manifest naming a subfolder's that cannot be read.
    case subtreeUnreadable(folder: String, hash: String)
    /// A folder on disk that cannot be read to fold its root.
    case folderUnreadable(path: String, reason: String)
    /// Two trees that hold different things at one path, by the wires they came from.
    case treeCollision(path: String, first: String, second: String)
    /// A tree holding no entry at a name a product reads from it.
    case treeHasNoEntry(name: String, entries: [String])

    // MARK: - Formulas and products

    /// A formula that cannot be read, where it is known: line and column, 1-based, with
    /// the line's text.
    case formulaInvalid(path: String?, problem: FormulaProblem, line: Int?, column: Int?, lineText: String?)
    /// Two products of one formula at one path.
    case twoProductsAtOnePath(path: String)
    /// A product path that names no file system, or nothing at all.
    case productPathInvalid(path: String, root: String?)
    /// A formula's `include` no plugin answers, two claim, or the one claiming it refuses.
    case includeUnanswered(name: String, installed: [String])
    case includeClaimedTwice(name: String, plugins: [String])
    case includeRefused(name: String, plugin: String, reason: IncludeRefusal)

    // MARK: - Inputs a node asked for

    /// Inputs a node demanded that have no value: the converter's packages, the folders a
    /// target may be in, the include files a preprocessor resolves. A node publishes this
    /// while its demands are on their way; it is a report's only when they never arrive.
    case inputsWithoutValue(kind: AwaitedInput, paths: [String])
    /// A compile with no source to compile.
    case noSources

    // MARK: - Swift packages

    /// A package's manifest whose JSON cannot be read: what the decoder said.
    case manifestUnreadable(path: String?, reason: String)
    /// A package a dependency graph names that is not in the input file system: where it
    /// was expected, and where it comes from, or nil for a local path dependency. Nothing is
    /// fetched: a dependency is pushed like any other source.
    case packageNotPresent(path: String, origin: PackageOrigin?)
    /// A target that declares no path and is in none of SwiftPM's predefined folders.
    case targetFolderMissing(package: String, packageFolder: String, target: String)
    /// A vendored package whose pushed tree is not the one its lock records.
    case lockMismatch(folder: String, lock: LockFacts, expected: String, found: String, leftOut: [LeftOutEntry])
    /// A lock taken under another fold than this Semel's, so its root cannot be compared.
    case lockFoldChanged(folder: String, lock: LockFacts, lockFold: String, currentFold: String)
    /// A lock whose text is not a lock.
    case lockUnreadable(folder: String, lockPath: String, problem: LockProblem)
    /// A binary target a product reaches whose artifact is not an `.xcframework` that is
    /// there (B-77, B-133).
    case binaryTargetNotBuilt(target: UnbuiltBinaryTarget)
    /// A target whose only sources are what its build-tool plugins would make, and no
    /// plugin is run (B-77). `package` is nil for an Xcode project's target.
    case sourcesOnlyFromPlugins(package: String?, target: String, plugins: [String])

    // MARK: - Xcode projects

    case notAProject
    case projectNotPushed(path: String)
    case projectHasNoContent(path: String)
    case noSuchTarget(name: String)
    case targetHasNoSources(name: String)
    case noSuchConfiguration(name: String, available: [String])
    /// Listed sources the converter does not compile: Objective-C, C, Metal.
    case unsupportedSources(target: String, files: [String])
    case noApplicationTarget
    case noApplicationForSDK(sdk: String, applications: [String])
    case severalApplicationsForSDK(sdk: String, applications: [String])
    case noSuchApplication(name: String, applications: [String])
    /// An application linking local package products, in a project that has no package
    /// where the converter looks: no package folder declared, and none directly in a
    /// synchronized folder.
    case localPackagesNotFound(application: String, products: [String], synchronizedFolders: [String])
    case xcconfigIncludeCycle(chain: [String])
    /// xcconfig files that are not there, and the settings they would define, which are
    /// undefined.
    case xcconfigMissing(paths: [String], undefined: [String])
    /// An Info.plist whose values name build settings nothing defines.
    case undefinedPlistVariables(names: [String])

    // MARK: - Apple resources

    /// A document `IBToolCompiler` does not compile, with the extensions it does.
    case notAnInterfaceBuilderDocument(path: String, compiles: [String])
    /// A bundle wire's key that is not one folder's name.
    case bundleWireKeyInvalid(key: String)
    /// An `.xcframework` with no slice for the build, or one that cannot be linked here.
    case xcframeworkUnusable(path: String, problem: XCFrameworkProblem)
    /// actool's `Assets.car` that cannot be put in canonical form, or whose canonical form
    /// does not read as the file actool wrote (B-89).
    case assetCatalogNotCanonical(problem: AssetCatalogProblem)

    // MARK: - Everything else

    /// An error of a type that names no condition: its type and its own description. The
    /// last resort, for an error from outside Semel — a Foundation error a node let through.
    case unclassified(type: String, description: String)

    public var errorCondition: ErrorCondition {
        self
    }

    /// The remedy the condition states by itself, when there is one to state as a fact:
    /// the command that re-locks, the type to register. A node that knows a better one
    /// passes it to the document.
    public var impliedRemedy: ErrorDocument.Remedy? {
        switch self {
        case .lockMismatch(let folder, _, _, _, _),
             .lockFoldChanged(let folder, _, _, _),
             .lockUnreadable(let folder, _, _):
            return .relock(package: Path(folder).lastComponent ?? folder)
        case .unlinkedKind(let kind):
            return .register(kind: kind)
        case .unknownTypeName(let name):
            return .registerType(name: name)
        case .targetFolderMissing(_, _, let target):
            return .missingFolder(tried: Self.predefinedTargetFolders.map { "\($0)/\(target)" })
        case .packageNotPresent(_, let origin):
            return origin == nil ? nil : .vendor
        case .settingsMissing(let project, let machine, let writer):
            if !machine.isEmpty, let writer {
                return .writeMachineFile(commands: [writer])
            }
            return project.isEmpty ? nil : .setting(keys: project)
        case .toolNotInstalled(_, _, _, let writer?):
            return .writeMachineFile(commands: [writer])
        case .settingNotAccepted(let key, _, _),
             .settingNotAList(let key, _),
             .sdkNotFound(_, let key),
             .settingNotSupported(let key, _, _):
            return .setting(keys: [key])
        case .objectCorrupted(let path, _, _):
            return .delete(path: path)
        case .binaryTargetNotBuilt(let target):
            // What is downloaded or zipped is put in place by `prepare`; an artifact the
            // manifest names by path is the package's own, and nothing vendors it.
            guard case .missing = target.location else {
                return nil
            }
            switch target.artifact {
            case .remote, .zip: return .vendor
            case .local:        return nil
            }
        default:
            return nil
        }
    }

    /// SwiftPM's predefined source folders, in the order it tries them: what a missing
    /// target folder's remedy names.
    public static let predefinedTargetFolders = ["Sources", "Source", "src", "srcs"]
}

// MARK: - The values the conditions carry

/// A tool as a configuration names it, without the fingerprint a configuration cannot
/// state.
public struct ToolIdentity: Codable, Hashable, Sendable {
    public let name:         String
    public let version:      String
    public let platform:     String
    public let architecture: String

    public init(name: String, version: String, platform: String, architecture: String) {
        self.name         = name
        self.version      = version
        self.platform     = platform
        self.architecture = architecture
    }
}

/// The form a value was expected to have.
public enum ValueForm: String, Codable, Hashable, Sendable {
    case jsonDictionary
    case jsonStringDictionary
    case jsonStringList
    case propertyListDictionary
    case folderManifest
    case folderSubtreeManifest
    case treeManifest
    case lock
}

/// What a node is waiting for, by kind: the noun a report puts before the paths.
public enum AwaitedInput: String, Codable, Hashable, Sendable {
    /// A package folder and its manifest, for a converter named by `path`.
    case packageFolderAndManifest
    /// The folders a target that names no path may be in (B-143).
    case targetFolderCandidates
    case targetFolders
    case binaryArtifactFolders
    /// The settings whose `sdk` decides a platform condition.
    case platformSettings
    case locks
    case headerFolders
    case includeFiles
}

/// Where a vendored package comes from.
public enum PackageOrigin: Codable, Hashable, Sendable {
    /// A git repository, by its URL, or by its name when the manifest gives none.
    case repository(location: String)
    /// A package registry's package, by its identity: `mona.LinkedList`.
    case registry(identity: String)
}

/// What a lock records about where its package came from, and where it is.
public struct LockFacts: Codable, Hashable, Sendable {
    public let lockPath: String
    public let version:  String?
    public let origin:   String?

    public init(lockPath: String, version: String?, origin: String?) {
        self.lockPath = lockPath
        self.version  = version
        self.origin   = origin
    }
}

/// Why a lock's text is not a lock, by the line that says so.
public enum LockProblem: Codable, Hashable, Sendable {
    case unknownKey(key: String, line: Int, keys: [String])
    case repeatedKey(key: String, line: Int)
    case emptyValue(key: String, line: Int)
    case missingKey(key: String)
    case unknownContentScheme(value: String, scheme: String)
    case malformedArtifact(item: String)
}

/// A binary target that is not built, and why.
public struct UnbuiltBinaryTarget: Codable, Hashable, Sendable {
    public enum Artifact: Codable, Hashable, Sendable {
        case remote(url: String)
        case zip(path: String)
        case local(path: String)
    }

    public enum Location: Codable, Hashable, Sendable {
        /// Nothing is at the folder where the artifact should be.
        case missing(folder: String)
        /// Something is there and it is not an `.xcframework`: what the folder holds.
        case notAnXCFramework(path: String, contents: [String])
    }

    public let package:       String
    public let packageFolder: String
    public let target:        String
    public let artifact:      Artifact
    public let location:      Location
    /// The products of the converted package that reach it, sorted.
    public let products:      [String]

    public init(package: String, packageFolder: String, target: String, artifact: Artifact, location: Location,
                products: [String]) {
        self.package       = package
        self.packageFolder = packageFolder
        self.target        = target
        self.artifact      = artifact
        self.location      = location
        self.products      = products
    }
}

/// Why a formula cannot be read: the parser's cases, with what each names.
public enum FormulaProblem: Codable, Hashable, Sendable {
    case unexpectedToken(token: String, expected: String)
    case unexpectedCharacter(character: String, context: String)
    case unterminatedString(context: String)
    case unterminatedPath(context: String)
    case undefinedIdentifier(name: String)
    case typeMismatch(expected: String, found: String, context: String)
    case wrongArgumentCount(function: String, expected: Int, found: Int)
    case positionalArgument(type: String)
    case pathEscapesBase(path: String)
    case pathEscapesRoot(path: String)
    case forEachWithoutItems
    case forEachExceptLeavesNothing(variable: String, removed: [String])
    case duplicateDefinition(kind: String, name: String)
    case unboundParameter(function: String, parameter: String)
    case namespaceOutsidePrelude(namespace: String)
    case productInPrelude(namespace: String, product: String)
    case preludeNotIncluded(namespace: String, callee: String, scope: String?)
}

/// Why a plugin will not provide an include it claims.
public enum IncludeRefusal: Codable, Hashable, Sendable {
    /// The tool the prelude is for is not installed here.
    case toolNotInstalled(tool: String)
    /// The language version or feature the include names is not one the installed tool
    /// supports.
    case notSupported(feature: String)
}

/// Why an `.xcframework` gives a build nothing to link.
public enum XCFrameworkProblem: Codable, Hashable, Sendable {
    case infoPlistUnreadable
    case noSliceForSDK(sdk: String)
    case noSliceForPlatform(platform: String, available: [String])
    case noSliceForArchitecture(architecture: String, slice: String, architectures: [String])
    case unsupportedLibrary(path: String)
    case noFrameworkBinary(paths: [String])
    case frameworkBinaryUnrecognised(path: String, reason: BinaryProblem)
}

/// Why a framework's binary is neither a dynamic library nor an archive.
public enum BinaryProblem: Codable, Hashable, Sendable {
    case unreadable
    case unknownMagic(bytes: String)
    case machOFileType(fileType: UInt32)
    case mixedSlices
}

/// Why actool's `Assets.car` is not published (B-89).
public enum AssetCatalogProblem: Codable, Hashable, Sendable {
    /// Which of the two catalogs `assetutil` was reading.
    public enum Copy: String, Codable, Hashable, Sendable {
        case actools
        case canonical
    }

    case unreadableByAssetutil(copy: Copy, output: String)
    case printedNoCatalog(copy: Copy, output: String)
    case entryCountDiffers(actools: Int, canonical: Int)
    case entriesDiffer(differences: [String])
    case notABOMStore(problem: BOMProblem)
    case missingVariable(name: String)
    case unknownIconFacetPart(facet: String, part: UInt16)
    case generatedNameRemains(offset: Int, text: String)
    case roundTripDiffers(variable: String)
}

/// Why a file is not a BOM store an `Assets.car` is read as.
public enum BOMProblem: Codable, Hashable, Sendable {
    case notABOMStore
    case unsupportedVersion(version: UInt32)
    case truncated(what: String)
    case blockOutOfRange(index: UInt32)
    case emptyBlockReferenced(index: UInt32, referrer: String)
    case unreachableBlocks(indices: [UInt32])
    case treeCycle(variable: String, node: UInt32)
    case unknownKeyForm(variable: String, form: UInt8)
}
