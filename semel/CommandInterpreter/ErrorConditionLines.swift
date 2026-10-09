// ErrorConditionLines.swift
// semel
//
// The sentence each engine condition reads as. The engine publishes the condition with
// the values it needs, and this is the one place they become words: one `switch` over
// every case of `ErrorCondition`, with no `default`, so a condition added to the engine
// does not compile here until it has its lines.
//
// A line says what is, never what happened: no "while", "after" or "still" (AGENTS.md,
// "The engine is a time-free zone"). A path comes first where the condition is about one,
// so a terminal makes it a link.

import Foundation
import SemelNodeKit

struct ConditionLines {

    /// What a condition reads as: line one — its path, when it leads with one, drawn
    /// bold, then the rest — the labelled lines under it, and lines that continue it as
    /// they are, such as a formula's line of text.
    struct Drawn: Equatable {
        var path:         String?
        var headline:     String
        var details:      [Detail] = []
        var continuation: [String] = []
    }

    struct Detail: Equatable {
        let label: String
        let value: String
    }

    /// How a path in the input file system is drawn: relative to the session's base.
    let path: (String) -> String

    // MARK: - The switch

    // One case per condition, each a few lines: the length is the catalogue, not logic.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func lines(for condition: ErrorCondition) -> Drawn {
        switch condition {

        // MARK: Tools

        case .toolExitedSilently(let tool, let status):
            return Drawn(headline: "\(tool) exited with status \(status) and said nothing")
        case .toolWroteNothing(let tool, let status, let paths):
            let what = paths.isEmpty ? "its output" : capped(paths.map(path))
            return Drawn(headline: "\(tool) exited with status \(status) and wrote nothing at \(what)")
        case .toolNotInstalled(let requested, let available, let namespace, _):
            return Drawn(headline: "no tool installed here matches \(described(requested))",
                         details: [Detail(label: "installed", value: available.isEmpty ? "none"
                                                                     : available.map(described).joined(separator: ", ")),
                                   Detail(label: "named by", value: "\(namespace).toolDescriptor")])
        case .toolNotFound(let toolPath):
            return Drawn(headline: "no tool exists at \(toolPath)")
        case .toolNotExecutable(let toolPath):
            return Drawn(path: toolPath, headline: " is not executable")
        case .toolInputNotWritten(let file, let reason):
            return Drawn(path: path(file), headline: " cannot be laid in the tool's sandbox",
                         details: [Detail(label: "reason", value: reason)])
        case .toolOutputNotRead(let file):
            return Drawn(headline: "the tool's output \(file) cannot be read back")
        case .toolLaunchFailed(let reason):
            return Drawn(headline: "the tool cannot be started", details: [Detail(label: "reason", value: reason)])

        // MARK: Settings

        case .settingsMissing(let project, let machine, let writer):
            var details: [Detail] = []
            // The remedy names one thing to change; where both kinds are missing and the
            // machine's command is the remedy, the project's keys are said beside it.
            if !project.isEmpty, !machine.isEmpty, writer != nil {
                details.append(Detail(label: "set", value: project.joined(separator: ", ")))
            }
            return Drawn(headline: "missing settings: \((project + machine).sorted().joined(separator: ", "))", details: details)
        case .settingNotAccepted(let key, let value, let accepted):
            return Drawn(headline: "\(key) is '\(value)', which is not one of \(accepted.joined(separator: ", "))")
        case .settingNotAList(let key, let value):
            return Drawn(headline: "\(key) is '\(value)', which is not a JSON list of strings")
        case .sdkNotFound(let sdk, let key):
            return Drawn(headline: "no SDK named \(sdk) is installed here", details: [Detail(label: "named by", value: key)])
        case .sdkVersionDiffers(let sdk, let declared, let found):
            guard let found else {
                return Drawn(headline: "sdkVersion is \(declared), and no SDK named \(sdk) is installed here")
            }
            // The build number is part of what is declared, and a version without it is
            // never a match: the line says which of the two it is.
            let headline = declared.contains("(")
                ? "sdkVersion is \(declared), and this machine's \(sdk) SDK is \(found)"
                : "sdkVersion is \(declared), without the SDK's build number; this machine's \(sdk) SDK is \(found)"
            return Drawn(headline: headline)
        case .settingNotSupported(let key, let value, let supported):
            return Drawn(headline: "\(key) is '\(value)', and '\(supported)' is the one value built with")

        // MARK: Sources

        case .notPushed(let source, _):
            return Drawn(path: path(source), headline: " has not been pushed")
        case .removed(let source, _):
            guard let source else {
                return Drawn(headline: "a source this node reads has been removed")
            }
            return Drawn(path: path(source), headline: " has been removed")
        case .inputInError:
            return Drawn(headline: "an input is in error, and no node above it says why")
        case .documentUnreadable(let hash):
            return Drawn(headline: "an error whose document cannot be read",
                         details: [Detail(label: "document", value: hash.isEmpty ? "none" : hash)])

        // MARK: Types and the graph

        case .unlinkedKind(let kind):
            return Drawn(headline: "a node of kind \(kind) is of a type this server does not link")
        case .unknownTypeName(let name):
            return Drawn(headline: "no node type is registered under the name '\(name)'")
        case .requiredPortUnwired(let type, let port):
            return Drawn(headline: "\(owner(type))required input '\(port)' has nothing wired to it")
        case .severalWiresOnOneWirePort(let type, let port, let wires):
            return Drawn(headline: "\(owner(type))input '\(port)' takes one wire, and \(wires.count) are wired to it",
                         details: [Detail(label: "wires", value: wires.joined(separator: ", "))])
        case .portNotDeclared(let type, let port):
            return Drawn(headline: "\(type ?? "this node") declares no input port '\(port)'")
        case .outputPortMissing(let nodeID, let port):
            return Drawn(headline: "node #\(nodeID) holds no row for its output port '\(port)', which its type declares")
        case .nodePropertyMissing(let kind, let nodeID, let property):
            return Drawn(headline: "node \(nodeID.map { "#\($0)" } ?? "(not saved)") of kind \(kind) has no '\(property)', "
                                 + "which its type is always made with")
        case .propertyMissing(let type, let property, let alternatives):
            var details: [Detail] = []
            if !alternatives.isEmpty {
                details.append(Detail(label: "or wired", value: alternatives.joined(separator: ", ")))
            }
            return Drawn(headline: "\(type) is given no '\(property)'", details: details)
        case .propertiesExclusive(let type, let properties):
            return Drawn(headline: "\(type) takes exactly one of \(properties.joined(separator: " and "))")
        case .propertyNotOfForm(let type, let property, let form):
            return Drawn(headline: "\(type)'s '\(property)' is not \(phrase(form))")
        case .inputNotOfForm(let port, let wire, let form):
            return Drawn(headline: "'\(path(wire))' on \(port) is not \(phrase(form))")
        case .inputHasNoContent(let port, let wire):
            return Drawn(headline: "'\(path(wire))' on \(port) has no content")
        case .sourceCannotProcess(let type):
            return Drawn(headline: "\(type) declares no input ports and does not process")
        case .processNotSupported(let type):
            return Drawn(headline: "\(type ?? "this node") does not process")
        case .cannotHaveProperties:
            return Drawn(headline: "this node takes no properties")
        case .cannotDeleteNodeWithOutputs:
            return Drawn(headline: "a node whose outputs are wired is not deleted")
        case .nodeNotFound:
            return Drawn(headline: "there is no such node")
        case .nameCollision(let name, let existingKind):
            return Drawn(path: path(name), headline: " is a node of kind \(existingKind), and two children of one folder "
                                                   + "do not share a name")
        case .graphSpecBadIntegrity(let found, let expected, let log):
            return Drawn(headline: "the graph holds \(found) where its spec has \(expected)",
                         continuation: log.components(separatedBy: "\n").filter { !$0.isEmpty })
        case .wireWithoutOutputPort(let wire, let type):
            let fed = wire.map { "the wire '\($0)'" } ?? "this node"
            return Drawn(headline: "the \(type) feeding \(fed) names no output port to take a value from")
        case .identityMismatch(let type, let filedUnder, let computed):
            return Drawn(headline: "a spec table files a \(type) under \(NodeIdentity.shown(filedUnder))…, "
                                 + "and its row gives \(NodeIdentity.shown(computed))…")
        case .emptyWireName:
            return Drawn(headline: "a wire is asked for under an empty name")
        case .specTableMissingRow(let identity):
            return Drawn(headline: "a spec table names the node \(NodeIdentity.shown(identity))… and holds no row for it")
        case .specTableCycle(let identity):
            return Drawn(headline: "a spec table has the node \(NodeIdentity.shown(identity))… among its own sources")
        case .specUnreadable(let found, let context):
            guard let found else {
                return Drawn(headline: "a graph spec ends early — \(context)")
            }
            guard !found.isEmpty else {
                return Drawn(headline: "a graph spec has an empty name where a type or a port belongs")
            }
            return Drawn(headline: "a graph spec has '\(found)' where it does not belong — \(context)")
        case .duplicateWireName(let name):
            return Drawn(headline: "an input port holds a different wire named '\(name)'")
        case .wireNotDisconnected:
            return Drawn(headline: "a wire does not disconnect")
        case .circularWiring(let fromNodeID, let toNodeID):
            return Drawn(headline: "a wire from node #\(fromNodeID) into node #\(toNodeID) would make the graph circular")
        case .staticPortWiredAfterCreation(let type, let port):
            return Drawn(headline: "\(type)'s input '\(port)' is wired when the node is made, from its spec, and not after")
        case .sourceWithoutIdentity(let nodeID):
            return Drawn(headline: "node #\(nodeID) has no identity, so nothing wired from it has one")
        case .nodeNotPersisted(let kind, let name):
            return Drawn(headline: "a node of kind \(kind)\(name.map { " named '\($0)'" } ?? "") is not saved, so it has no id")
        case .nodeHasNoName(let kind, let nodeID):
            let node = nodeID.map { "node #\($0)" } ?? "a node"
            return Drawn(headline: "\(node)\(kind.map { " of kind \($0)" } ?? "") has no name, and a path is made of names")
        case .noSuchFolder(let folder):
            return Drawn(headline: "no folder is at \(path(folder))")
        case .unexpectedNodeKind(let kind):
            return Drawn(headline: "a node of kind \(kind) is not one a folder holds")
        case .folderNotDeletable(let folder):
            return Drawn(headline: "\(folder.map(path) ?? "a folder") holds something that is not deletable")
        case .unexpectedValueType:
            return Drawn(headline: "a value is not of the type its reader takes")
        case .kindNotSerializable(let kind):
            return Drawn(headline: "the type registered for kind \(kind) is not serializable")
        case .kindNotANode(let kind):
            return Drawn(headline: "the type registered for kind \(kind) is not a node type")
        case .duplicateKind(let kind, let existing, let duplicate):
            return Drawn(headline: "kind \(kind) is claimed by both \(existing) and \(duplicate)")

        // MARK: Values

        case .objectCorrupted(let file, let expected, let found):
            return Drawn(path: file, headline: " is filed as \(expected), and its bytes hash to \(found)")
        case .valueUnreadable(let form, let port, let wire):
            return Drawn(headline: "the \(noun(form)) for '\(path(wire))'\(port.map { " on \($0)" } ?? "") cannot be read")
        case .subtreeUnreadable(let folder, let hash):
            return Drawn(headline: "the subtree manifest of \(path(folder)) cannot be read",
                         details: [Detail(label: "manifest", value: hash)])
        case .folderUnreadable(let folder, let reason):
            return Drawn(path: folder, headline: " cannot be read to fold its content root",
                         details: [Detail(label: "reason", value: reason)])
        case .treeCollision(let entry, let first, let second):
            return Drawn(headline: "two trees hold '\(entry)': \(path(first)) and \(path(second))")
        case .treeHasNoEntry(let name, let entries):
            return Drawn(headline: "the tree holds no file '\(name)'",
                         details: [Detail(label: "it holds", value: entries.isEmpty ? "nothing" : capped(entries))])

        // MARK: Formulas and products

        case .formulaInvalid(let formula, let problem, let line, let column, let lineText):
            let sentence = self.sentence(problem)
            let continuation = lineText.map { [$0] } ?? []
            guard let formula else {
                return Drawn(headline: sentence, continuation: continuation)
            }
            // The location a terminal makes a link of, as a compiler writes one.
            let location = [path(formula), line.map(String.init), column.map(String.init)].compactMap { $0 }.joined(separator: ":")
            return Drawn(path: location, headline: ": error: \(sentence)", continuation: continuation)
        case .twoProductsAtOnePath(let product):
            return Drawn(headline: "two products of one formula are at \(OutputPaths.underOutput(product))")
        case .productPathInvalid(let product, let root):
            guard let root else {
                return Drawn(headline: "the product path '\(product)' names nothing")
            }
            return Drawn(headline: "the product path '\(product)' begins with '\(root)', which is neither input: nor output:")
        case .includeUnanswered(let name, let installed):
            return Drawn(headline: "include '\(name)': no plugin answers this name",
                         details: [Detail(label: "plugins", value: installed.isEmpty ? "none" : installed.joined(separator: ", "))])
        case .includeClaimedTwice(let name, let plugins):
            return Drawn(headline: "include '\(name)' is claimed by both \(plugins.joined(separator: " and "))")
        case .includeRefused(let name, let plugin, let reason):
            switch reason {
            case .toolNotInstalled(let tool):
                return Drawn(headline: "include '\(name)': \(plugin) finds no \(tool) installed here")
            case .notSupported(let feature):
                return Drawn(headline: "include '\(name)': \(plugin) does not support \(feature)")
            }

        // MARK: Inputs a node asked for

        case .inputsWithoutValue(let kind, let paths):
            return Drawn(headline: awaited(kind, paths.map(path)))
        case .noSources:
            return Drawn(headline: "no Swift source to compile")

        // MARK: Swift packages

        case .manifestUnreadable(let manifest, let reason):
            return Drawn(path: manifest.map(path), headline: manifest == nil ? "a package manifest cannot be read" : " cannot be read",
                         details: [Detail(label: "reason", value: reason)])
        case .packageNotPresent(let package, let origin):
            let from: String
            switch origin {
            case .repository(let location): from = location
            case .registry(let identity):   from = "registry package \(identity)"
            case nil:                       from = "a local path dependency"
            }
            return Drawn(path: path(package), headline: " holds no package", details: [Detail(label: "from", value: from)])
        case .targetFolderMissing(_, let packageFolder, let target):
            let first = ErrorCondition.predefinedTargetFolders.first.map { "\($0)/\(target)" } ?? target
            return Drawn(path: path("\(packageFolder)/\(first)"), headline: " has not been pushed")
        case .lockMismatch(let folder, let lock, let expected, let found, let leftOut):
            var details = [Detail(label: "lock", value: described(lock)),
                           Detail(label: "expected", value: expected),
                           Detail(label: "found", value: found)]
            if let notCompared = notCompared(leftOut) {
                details.append(Detail(label: "not compared", value: notCompared))
            }
            return Drawn(path: path(folder), headline: " differs from its lock", details: details)
        case .lockFoldChanged(let folder, let lock, let lockFold, let currentFold):
            return Drawn(path: path(folder), headline: " cannot be compared with its lock",
                         details: [Detail(label: "lock", value: described(lock)),
                                   Detail(label: "folded as", value: lockFold),
                                   Detail(label: "this Semel folds as", value: currentFold)])
        case .lockUnreadable(_, let lockPath, let problem):
            return Drawn(path: path(lockPath), headline: " is not a lock: \(sentence(problem))")
        case .batchRejected(let folder, let lock, let expected, let found, let paths):
            var details = [Detail(label: "lock", value: path(lock)),
                           Detail(label: "expected", value: described(expected)),
                           Detail(label: "found", value: found.map { DependencyLock.contentScheme + $0 } ?? "no folder")]
            if !paths.isEmpty {
                details.append(Detail(label: "paths", value: capped(paths.map(path))))
            }
            return Drawn(path: path(folder),
                         headline: " is locked, and the batch changes it without a lock it matches: "
                                 + "nothing of the batch is committed",
                         details: details)
        case .binaryTargetNotBuilt(let target):
            return binaryTarget(target)
        case .sourcesOnlyFromPlugins(let package, let target, let plugins):
            var details = [Detail(label: "plugins", value: plugins.joined(separator: ", "))]
            if let package {
                details.insert(Detail(label: "package", value: package), at: 0)
            }
            return Drawn(headline: "\(target) has no source of its own, only what its build-tool plugins would generate, "
                                 + "and no plugin is run", details: details)
        case .macroForAnotherPlatform(let package, let target, let platform):
            return Drawn(headline: "\(target) is a macro, which the compiler runs on this Mac, and a macro is built only "
                                 + "in a build for macOS",
                         details: [Detail(label: "package", value: package),
                                   Detail(label: "platform", value: platform ?? "not one SwiftPM names")])

        // MARK: Xcode projects

        case .notAProject:
            return Drawn(headline: "the project file is not a project.pbxproj: it has no objects table and root object")
        case .projectNotPushed(let project):
            return Drawn(path: path(project), headline: " has not been pushed")
        case .projectHasNoContent(let project):
            return Drawn(path: path(project), headline: " has no content")
        case .noSuchTarget(let name):
            return Drawn(headline: "the project has no target named '\(name)'")
        case .targetHasNoSources(let name):
            return Drawn(headline: "\(name) has no synchronized folder, no listed sources and no borrowed sources")
        case .noSuchConfiguration(let name, let available):
            return Drawn(headline: "the project has no configuration named '\(name)'",
                         details: [Detail(label: "configurations", value: available.joined(separator: ", "))])
        case .unsupportedSources(let target, let files):
            return Drawn(headline: "\(target) lists sources that are not Swift, and they are not compiled",
                         details: [Detail(label: "sources", value: capped(files.map(path)))])
        case .noApplicationTarget:
            return Drawn(headline: "the project has no application target")
        case .noApplicationForSDK(let sdk, let applications):
            return Drawn(headline: "no application target builds for \(sdk)",
                         details: [Detail(label: "applications", value: applications.joined(separator: ", "))])
        case .severalApplicationsForSDK(let sdk, let applications):
            return Drawn(headline: "\(applications.count) application targets build for \(sdk), and nothing names one",
                         details: [Detail(label: "applications", value: applications.joined(separator: ", "))])
        case .noSuchApplication(let name, let applications):
            return Drawn(headline: "the project has no application target named '\(name)'",
                         details: [Detail(label: "applications", value: applications.isEmpty ? "none"
                                                                        : applications.joined(separator: ", "))])
        case .localPackagesNotFound(let application, let products, let folders):
            return Drawn(headline: "\(application) links \(products.joined(separator: ", ")) from local packages, "
                                 + "and the project has none where they are looked for",
                         details: [Detail(label: "synchronized folders", value: folders.isEmpty ? "none"
                                                                                : folders.joined(separator: ", "))])
        case .xcconfigIncludeCycle(let chain):
            return Drawn(headline: "xcconfig files include each other in a cycle: \(chain.map(path).joined(separator: " → "))")
        case .xcconfigMissing(let paths, let undefined):
            return Drawn(headline: "\(capped(paths.map(path))) \(paths.count == 1 ? "has" : "have") not been pushed",
                         details: [Detail(label: "undefined", value: capped(undefined))])
        case .undefinedPlistVariables(let names):
            return Drawn(headline: "the Info.plist names settings nothing defines: \(names.joined(separator: ", "))")

        // MARK: Apple resources

        case .notAnInterfaceBuilderDocument(let document, let compiles):
            return Drawn(path: path(document), headline: " is not an Interface Builder document",
                         details: [Detail(label: "compiled", value: compiles.joined(separator: ", "))])
        case .bundleWireKeyInvalid(let key):
            return Drawn(headline: "the bundle's wire is keyed '\(key)', which is not one folder's name")
        case .xcframeworkUnusable(let xcframework, let problem):
            return Drawn(path: path(xcframework), headline: ": \(sentence(problem))")
        case .assetCatalogNotCanonical(let problem):
            return assetCatalog(problem)

        // MARK: Everything else

        case .unclassified(let type, let description):
            let lines = description.components(separatedBy: "\n").filter { !$0.isEmpty }
            return Drawn(headline: lines.first ?? type,
                         details: [Detail(label: "error", value: type)],
                         continuation: Array(lines.dropFirst()))
        }
    }

    // MARK: - Parts

    /// Up to `pathsNamed` items, then how many more.
    private func capped(_ items: [String]) -> String {
        let shown = items.prefix(ErrorReportRenderer.pathsNamed).joined(separator: ", ")
        let rest  = items.count - ErrorReportRenderer.pathsNamed
        return rest > 0 ? "\(shown) and \(rest) more" : shown
    }

    private func owner(_ type: String?) -> String {
        type.map { "\($0)'s " } ?? ""
    }

    private func described(_ tool: ToolIdentity) -> String {
        "\(tool.name) \(tool.version) (\(tool.platform)/\(tool.architecture))"
    }

    private func described(_ lock: LockFacts) -> String {
        let recorded = [lock.version.map { "version \($0)" }, lock.origin.map { "from \($0)" }].compactMap { $0 }
        return recorded.isEmpty ? path(lock.lockPath) : "\(path(lock.lockPath)) (\(recorded.joined(separator: ", ")))"
    }

    private func described(_ expected: LockExpectation) -> String {
        switch expected {
        case .contentRoot(let root):
            return DependencyLock.contentScheme + root
        case .otherFold(let fold, let root):
            return "\(DependencyLock.contentScheme)\(root), folded as '\(fold)'; this Semel folds as '\(FolderContentRoot.formatTag)'"
        case .unreadable(let problem):
            return "nothing: the lock is not a lock, \(sentence(problem))"
        }
    }

    private func phrase(_ form: ValueForm) -> String {
        switch form {
        case .jsonDictionary:         return "a JSON dictionary"
        case .jsonStringDictionary:   return "a JSON dictionary of strings"
        case .jsonStringList:         return "a JSON list of strings"
        case .propertyListDictionary: return "a property list dictionary"
        case .folderManifest:         return "a folder manifest"
        case .folderSubtreeManifest:  return "a subtree manifest"
        case .treeManifest:           return "a tree"
        case .lock:                   return "a lock"
        }
    }

    private func noun(_ form: ValueForm) -> String {
        switch form {
        case .jsonDictionary, .jsonStringDictionary: return "JSON dictionary"
        case .jsonStringList:                        return "JSON list"
        case .propertyListDictionary:                return "property list"
        case .folderManifest:                        return "folder manifest"
        case .folderSubtreeManifest:                 return "subtree manifest"
        case .treeManifest:                          return "tree"
        case .lock:                                  return "lock"
        }
    }

    private func awaited(_ kind: AwaitedInput, _ paths: [String]) -> String {
        let noun: String
        switch kind {
        case .packageFolderAndManifest:
            guard let folder = paths.first else {
                return "the package folder and its manifest have no value"
            }
            return "\(folder) and its Package.swift have no value"
        case .targetFolderCandidates: noun = "folders a target's sources may be in"
        case .targetFolders:          noun = "target folders"
        case .binaryArtifactFolders:  noun = "folders of binary targets' artifacts"
        case .platformSettings:       noun = "settings that decide the platform"
        case .locks:                  noun = "locks of vendored packages"
        case .headerFolders:          noun = "header folders"
        case .includeFiles:           noun = "include files"
        }
        return paths.isEmpty ? "\(noun) have no value" : "\(noun) without a value: \(capped(paths))"
    }

    /// What the comparison of a lock left out, by reason, a few paths each.
    private func notCompared(_ leftOut: [LeftOutEntry]) -> String? {
        let groups: [(reason: LeftOutEntry.Reason, label: String)] = [
            (.dotNamed,     "dot-named"),
            (.notPushed,    "asked for and not pushed"),
            (.removed,      "removed"),
            (.product,      "products"),
            (.failed,       "failed"),
            (.holdsNothing, "holding nothing a push sends"),
        ]
        let parts = groups.compactMap { group -> String? in
            let paths = leftOut.filter { $0.reason == group.reason }.map(\.path)
            return paths.isEmpty ? nil : "\(paths.count) \(group.label) (\(capped(paths)))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    private func binaryTarget(_ target: UnbuiltBinaryTarget) -> Drawn {
        var details: [Detail] = []
        switch target.artifact {
        case .remote(let url):   details.append(Detail(label: "from", value: url))
        case .zip(let zip):      details.append(Detail(label: "zip", value: path("\(target.packageFolder)/\(zip)")))
        case .local:             break
        }
        details.append(Detail(label: "products", value: target.products.joined(separator: ", ")))
        switch target.location {
        case .missing(let folder):
            return Drawn(path: path(folder), headline: " holds no artifact for binary target \(target.target)", details: details)
        case .notAnXCFramework(let artifact, let contents):
            if !contents.isEmpty {
                details.insert(Detail(label: "holds", value: capped(contents)), at: 0)
            }
            return Drawn(path: path(artifact), headline: " is not an .xcframework, which is the binary artifact linked here",
                         details: details)
        }
    }

    private func assetCatalog(_ problem: AssetCatalogProblem) -> Drawn {
        let headline = "actool's Assets.car has no canonical form that reads as the file actool wrote"
        func copy(_ copy: AssetCatalogProblem.Copy) -> String {
            copy == .actools ? "actool's" : "the canonical one"
        }
        switch problem {
        case .unreadableByAssetutil(let which, let output):
            return Drawn(headline: headline, details: [Detail(label: "assetutil", value: "fails on \(copy(which))")],
                         continuation: output.components(separatedBy: "\n").filter { !$0.isEmpty })
        case .printedNoCatalog(let which, let output):
            return Drawn(headline: headline, details: [Detail(label: "assetutil", value: "prints no catalog for \(copy(which))")],
                         continuation: output.isEmpty ? [] : [output])
        case .entryCountDiffers(let actools, let canonical):
            return Drawn(headline: headline, details: [Detail(label: "entries", value: "\(actools) in actool's, \(canonical) "
                                                                                 + "in the canonical one")])
        case .entriesDiffer(let differences):
            return Drawn(headline: headline, continuation: differences)
        case .notABOMStore(let bom):
            return Drawn(headline: headline, details: [Detail(label: "BOM store", value: sentence(bom))])
        case .missingVariable(let name):
            return Drawn(headline: headline, details: [Detail(label: "missing", value: name)])
        case .unknownIconFacetPart(let facet, let part):
            return Drawn(headline: headline, details: [Detail(label: "icon facet", value: "'\(facet)' names part \(part), "
                                                                                    + "none of the icon's own")])
        case .generatedNameRemains(let offset, let text):
            return Drawn(headline: headline, details: [Detail(label: "generated name", value: "'\(text)' at byte \(offset)")])
        case .roundTripDiffers(let variable):
            return Drawn(headline: headline, details: [Detail(label: "reads back differently", value: variable)])
        }
    }

    // MARK: - Nested problems

    private func sentence(_ problem: FormulaProblem) -> String {
        switch problem {
        case .unexpectedToken(let token, let expected):
            return "unexpected \(token), where \(expected) belongs"
        case .unexpectedCharacter(let character, let context):
            return "unexpected character '\(character)' — \(context)"
        case .unterminatedString(let context):
            return "a string literal has no end — \(context)"
        case .unterminatedPath(let context):
            return "a path literal has no end — \(context)"
        case .undefinedIdentifier(let name):
            return "'\(name)' is not defined"
        case .typeMismatch(let expected, let found, let context):
            return "\(found) where \(expected) belongs — \(context)"
        case .wrongArgumentCount(let function, let expected, let found):
            return "'\(function)' takes \(expected) argument\(expected == 1 ? "" : "s"), and is given \(found)"
        case .positionalArgument(let type):
            return "'\(type)' is given an argument without a name; use 'key: value' or 'port: [...]'"
        case .pathEscapesBase(let literal):
            return "the path literal '<\(literal)>' leads out of the formula's folder"
        case .pathEscapesRoot(let literal):
            return "the path literal '<\(literal)>' leads out of the root"
        case .forEachWithoutItems:
            return "a for-each '{...}' has no items"
        case .forEachExceptLeavesNothing(let variable, let removed):
            return "for-each '{\(variable): ...}' leaves nothing: its 'except' removes every item it matched "
                 + "(\(removed.joined(separator: ", ")))"
        case .duplicateDefinition(let kind, let name):
            return "\(kind) '\(name)' is defined by the formula and by a formula it includes"
        case .unboundParameter(let function, let parameter):
            return "'\(function)' is called without its parameter '\(parameter)'"
        case .namespaceOutsidePrelude(let namespace):
            return "'namespace \(namespace)' belongs in a plugin's prelude, not in a formula"
        case .productInPrelude(let namespace, let product):
            return "the prelude '\(namespace)' declares the product '\(product)', and a prelude holds funcs only"
        case .preludeNotIncluded(let namespace, let callee, let scope):
            guard let scope else {
                return "'\(callee)' calls into the prelude '\(namespace)', which this formula does not include"
            }
            return "the prelude '\(scope)' calls '\(callee)' and does not include the prelude '\(namespace)'"
        }
    }

    private func sentence(_ problem: LockProblem) -> String {
        switch problem {
        case .unknownKey(let key, let line, let keys):
            return "line \(line): '\(key)' is not a lock key; the keys are \(keys.joined(separator: ", "))"
        case .repeatedKey(let key, let line):
            return "line \(line): '\(key)' is said a second time"
        case .emptyValue(let key, let line):
            return "line \(line): '\(key)' has no value"
        case .missingKey(let key):
            return "there is no '\(key)' line"
        case .unknownContentScheme(let value, let scheme):
            return "'content' is '\(value)', and a content root is written '\(scheme)<hex>'"
        case .malformedArtifact(let item):
            return "'artifacts' holds '\(item)', and each item is written '<target>=<checksum>', a target once"
        case .malformedHiddenFile(let path, let line):
            return "line \(line): 'hidden' holds '\(path)', and each is a relative path, said once, to a dot-named file "
                 + "in no dot-named folder"
        }
    }

    private func sentence(_ problem: XCFrameworkProblem) -> String {
        switch problem {
        case .infoPlistUnreadable:
            return "its Info.plist is not an xcframework's: no AvailableLibraries with a LibraryIdentifier, LibraryPath "
                 + "and SupportedPlatform each"
        case .noSliceForSDK(let sdk):
            return "no slice is for the SDK \(sdk)"
        case .noSliceForPlatform(let platform, let available):
            return "no slice is for \(platform); its slices are \(available.joined(separator: ", "))"
        case .noSliceForArchitecture(let architecture, let slice, let architectures):
            return "its slice \(slice) has no \(architecture), only \(architectures.joined(separator: ", "))"
        case .unsupportedLibrary(let library):
            return "its slice's library \(library) is neither a framework nor a static archive"
        case .noFrameworkBinary(let paths):
            return "its slice's framework has no binary at \(paths.joined(separator: " or "))"
        case .frameworkBinaryUnrecognised(let binary, let reason):
            return "its slice's framework binary \(binary) \(sentence(reason))"
        }
    }

    private func sentence(_ problem: BinaryProblem) -> String {
        switch problem {
        case .unreadable:                  return "cannot be read"
        case .unknownMagic(let bytes):     return "is neither Mach-O nor an archive (it begins \(bytes))"
        case .machOFileType(let fileType): return "is a Mach-O file of type \(fileType), neither a dynamic library nor an object"
        case .mixedSlices:                 return "is a fat file whose architectures are not all of one kind"
        }
    }

    private func sentence(_ problem: BOMProblem) -> String {
        switch problem {
        case .notABOMStore:
            return "it does not open with 'BOMStore'"
        case .unsupportedVersion(let version):
            return "version \(version), and version 1 is the one known"
        case .truncated(let what):
            return "its \(what) runs past the end of the file"
        case .blockOutOfRange(let index):
            return "it names block \(index), past the end of its block table"
        case .emptyBlockReferenced(let index, let referrer):
            return "\(referrer) names block \(index), which is empty"
        case .unreachableBlocks(let indices):
            return "blocks \(capped(indices.map(String.init))) are reached from no variable"
        case .treeCycle(let variable, let node):
            return "the tree of \(variable) reaches its node \(node) twice"
        case .unknownKeyForm(let variable, let form):
            return "the tree of \(variable) declares key form \(form); 0 and 1 are the ones known"
        }
    }
}
