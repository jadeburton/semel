//
//  XcodeScheme.swift
//  SemelApple
//
//  What a shared scheme runs before a build: the build action's pre-actions. A scheme is
//  outside what Semel builds from — a hermetic build runs no script a developer's machine
//  decides the output of — but a pre-action is where a project generates a source its
//  build then needs (NetNewsWire's `SecretKey.swift`, B-77), and naming it is what turns
//  a bare "cannot find in scope" into a step the developer can take.

import Foundation

/// One shell-script pre-action of a scheme's build action.
public struct SchemePreAction: Equatable {
    /// The scheme it belongs to: the file's name without `.xcscheme`.
    public let scheme: String
    /// What Xcode shows for it: `Run Script` unless renamed.
    public let title: String
    /// The script as the scheme holds it, entities decoded.
    public let script: String

    public init(scheme: String, title: String, script: String) {
        self.scheme = scheme
        self.title  = title
        self.script = script
    }
}

struct XcodeScheme: Equatable {

    typealias PreAction = SchemePreAction

    let name: String
    let buildPreActions: [PreAction]

    /// The shared schemes of the project at `project` (the `.xcodeproj`), sorted by name:
    /// the ones in `xcshareddata/xcschemes`, which a clone has. A developer's own schemes
    /// live in `xcuserdata`, which a repository does not share.
    static func sharedSchemes(ofProjectAt project: URL) -> [XcodeScheme] {
        let folder = project.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".xcscheme") }
            .sorted()
        return names.compactMap { fileName in
            guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(fileName).path) else {
                return nil
            }
            return XcodeScheme(named: String(fileName.dropLast(".xcscheme".count)), xml: data)
        }
    }

    /// Reads the build action's pre-actions from a scheme's XML. A scheme that does not
    /// parse has none: the question is only ever what to tell a developer.
    init?(named name: String, xml: Data) {
        let reader = PreActionReader(scheme: name)
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        guard parser.parse() else {
            return nil
        }
        self.name = name
        buildPreActions = reader.preActions
    }

    /// The SAX walk: an `ActionContent` inside `BuildAction` > `PreActions` is a pre-action.
    private final class PreActionReader: NSObject, XMLParserDelegate {
        let scheme: String
        var preActions: [PreAction] = []
        private var path: [String] = []

        init(scheme: String) {
            self.scheme = scheme
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(elementName)
            guard elementName == "ActionContent", path.contains("BuildAction"), path.contains("PreActions"),
                  let script = attributes["scriptText"] else {
                return
            }
            preActions.append(PreAction(scheme: scheme, title: attributes["title"] ?? "Run Script", script: script))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            _ = path.popLast()
        }
    }
}
