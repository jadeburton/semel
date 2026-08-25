// ConfigSettings.swift
// SemelNodeKit
//
// `semel.config` — settings dropped anywhere above a project, in the same key=value format
// the wire already carries, so there is no format to convert between.
//
// Its reason for existing: a setting like the SDK must reach the graph as an ordinary input.
// Read from the machine instead, a change to it schedules nothing, so nothing rebuilds and
// the stale artifact stays published.
//
// Two dimensions of inheritance and one rule for both — most specific wins:
//
//     across files    swift.sdkVersion in a nearer folder beats one further up
//     across tools    swift.compiler.sdkVersion beats swift.sdkVersion, for the compiler
//
// The tool dimension exists because a setting must reach the node it names and no other.
// Settings were once broadcast to every node a converter emitted, which put properties on
// nodes that ignore them — and a node's properties are its searchKey and part of its cache
// key, so a setting the linker had no use for still gave it a new identity and orphaned its
// cached output. Namespacing lets a setting be addressed; the per-tool schema of accepted
// keys is what actually drops the rest, turning a key no tool wants into a reported mistake
// rather than a silent change of identity.
//
// This lives in the node-authoring API rather than in either toolchain package because both
// need it and neither may depend on the other. Only the toolchain prefix and the schemas
// differ between them.

/// What one tool will accept from a config file.
///
/// Only what a *file* may set. Values a project description supplies — a Swift target's
/// `moduleName`, a formula's literal `std` — are deliberately absent, which is what stops a
/// file from supplying them.
public struct ToolSchema {
    public let namespace: String
    public let acceptedSettings: Set<String>

    public init(namespace: String, acceptedSettings: Set<String>) {
        self.namespace = namespace
        self.acceptedSettings = acceptedSettings
    }
}

/// Where a `semel.config` is looked for.
public enum SemelConfig {

    public static let fileName = "semel.config"

    /// A wire expectation for `semel.config` at `folderPath` and every ancestor above it.
    ///
    /// Asking for files that do not exist is the point: an absent one is a ghost with no
    /// value, and pushing it later fills the wire and re-runs the asking node without anyone
    /// having to rescan or restart.
    public static func expectations(forFolder folderPath: String) -> [String: String] {
        var result: [String: String] = [:]
        var components = folderPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        while !components.isEmpty {
            let path = "\(components.joined(separator: "/"))/\(fileName)"
            result[path] = "StaticFile(path: '\(path)').output"
            components.removeLast()
        }
        return result
    }
}

public struct ConfigSettings {

    private struct Setting {
        let value: String
        /// Only ever read to name the file in a rejection message.
        let sourcePath: String
    }

    private let toolchainPrefix: String
    private let schemas: [ToolSchema]
    private let suppliedByProject: Set<String>
    private let projectName: String

    /// Keyed by what follows the toolchain prefix — `sdkVersion`, or `compiler.sdkVersion`.
    private let settings: [String: Setting]

    /// Merges the files, nearest ancestor winning.
    ///
    /// Per *key*, not per file: a nearer file overriding one setting does not discard the
    /// rest. That rule is the whole reason the format is a flat map of dotted keys — it
    /// answers "what does inheriting mean" once, for every setting that will ever exist.
    ///
    /// - Parameters:
    ///   - toolchainPrefix: `"swift."`, `"clang."`. Keys outside it belong to another
    ///     toolchain and are passed over in silence rather than rejected.
    ///   - suppliedByProject: keys a project description provides. Used only to explain a
    ///     rejection; what stops a file setting them is their absence from every schema.
    ///   - projectName: how to name that description in the explanation.
    public init(files: [String: NodeValue],
                toolchainPrefix: String,
                schemas: [ToolSchema],
                suppliedByProject: Set<String> = [],
                projectName: String = "the project description") {

        self.toolchainPrefix   = toolchainPrefix
        self.schemas           = schemas
        self.suppliedByProject = suppliedByProject
        self.projectName       = projectName

        // Furthest first, so nearer files overwrite. Depth is the path's component count;
        // the path itself breaks ties, because Dictionary order varies between processes and
        // these settings end up in node identities.
        let byDepth = files.keys.sorted {
            ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1)
        }

        var merged: [String: Setting] = [:]
        for path in byDepth {
            guard let text = try? files[path]?.expectValue().resolveAsString() else { continue }
            for (key, value) in [String: String](plainText: text)
            where key.hasPrefix(toolchainPrefix) {
                merged[String(key.dropFirst(toolchainPrefix.count))] =
                    Setting(value: value, sourcePath: path)
            }
        }
        self.settings = merged
    }

    /// The settings one tool should be configured with, its namespace stripped.
    ///
    /// Anything the tool does not accept is dropped here without comment; saying so is
    /// `rejections`' job, once, rather than once per tool.
    public func settings(forNamespace namespace: String) -> [String: String] {
        guard let schema = schemas.first(where: { $0.namespace == namespace }) else { return [:] }

        // Two passes, not one: an unqualified default and a tool-qualified override both
        // write the same bare key, so a single pass over an unordered Dictionary would let
        // whichever came out first win.
        var result: [String: String] = [:]
        for (key, setting) in settings where qualifier(of: key) == nil {
            guard schema.acceptedSettings.contains(key) else { continue }
            result[key] = setting.value
        }
        for (key, setting) in settings {
            guard let split = qualifier(of: key), split.namespace == namespace,
                  schema.acceptedSettings.contains(split.bare) else { continue }
            result[split.bare] = setting.value
        }
        return result
    }

    /// One line per setting that reached no tool, naming the file that set it.
    ///
    /// Reported rather than silently dropped: a typo that changes nothing and says nothing
    /// is the least helpful outcome there is, and this is the only signal the user gets that
    /// the SDK they thought they pinned is not pinned.
    public var rejections: [String] {
        var messages: [String] = []
        for (key, setting) in settings {
            if let split = qualifier(of: key) {
                // The namespace resolved, so a schema for it exists.
                guard let schema = schemas.first(where: { $0.namespace == split.namespace }),
                      !schema.acceptedSettings.contains(split.bare) else { continue }
                messages.append(rejection(setting: setting, key: key, bare: split.bare,
                                          audience: "the \(split.namespace)"))
            } else {
                // Unqualified means "a default for every tool", so it is a mistake only if
                // no tool at all would take it — otherwise every tool-specific default would
                // be reported by all the tools it was not meant for.
                guard !schemas.contains(where: { $0.acceptedSettings.contains(key) }) else { continue }
                messages.append(rejection(setting: setting, key: key, bare: key,
                                          audience: "no tool"))
            }
        }
        return messages.sorted()
    }

    private func rejection(setting: Setting, key: String, bare: String, audience: String) -> String {
        let reason = suppliedByProject.contains(bare)
            ? "'\(bare)' comes from \(projectName)"
            : "\(audience) accepts '\(bare)'"
        return "\(setting.sourcePath): ignoring '\(toolchainPrefix)\(key)' — \(reason)."
    }

    /// Splits `compiler.sdkVersion` into its tool and its key.
    ///
    /// A leading component that is not a tool name is just part of the key, so
    /// `toolDescriptor.version` stays a single setting that every tool can be given.
    private func qualifier(of key: String) -> (namespace: String, bare: String)? {
        guard let dot = key.firstIndex(of: ".") else { return nil }
        let head = String(key[key.startIndex ..< dot])
        guard schemas.contains(where: { $0.namespace == head }) else { return nil }
        return (head, String(key[key.index(after: dot)...]))
    }
}
