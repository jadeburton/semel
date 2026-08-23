// SwiftConfigSettings.swift
// SemelSwift
//
// Resolves the settings in `semel.config` down to what one tool should be configured with.
//
// There are two dimensions of inheritance and one rule for both — most specific wins:
//
//     across files    swift.sdkVersion in a nearer folder beats one further up
//     across tools    swift.compiler.sdkVersion beats swift.sdkVersion, for the compiler
//
// The tool dimension exists because a setting must reach the node it names and no other.
// Every setting used to be broadcast to every node the converter emitted, which put
// properties on nodes that ignore them — and a node's properties are its searchKey and part
// of its cache key, so a setting the linker had no use for still gave it a new identity and
// orphaned its cached output. Namespacing removes the broadcast; a per-tool schema of
// accepted keys removes the rest, by making a key no tool wants a reported mistake rather
// than a silent change of identity.

import SemelNodeKit

/// What one tool will accept from a config file.
///
/// Only what a *file* may set. Values the converter derives from the package manifest —
/// moduleName, outputName — are not listed, which is what stops a file from supplying them.
struct SwiftToolSchema {
    let namespace: String
    let acceptedSettings: Set<String>
}

struct SwiftConfigSettings {

    /// Namespaced because one file serves every toolchain in a tree; clang's settings are
    /// not ours to interpret and are left alone rather than reported.
    static let toolchainPrefix = "swift."

    private struct Setting {
        let value: String
        /// Only ever read to name the file in a rejection message.
        let sourcePath: String
    }

    private let schemas: [SwiftToolSchema]

    /// Keyed by what follows `swift.` — `sdkVersion`, or `compiler.sdkVersion`.
    private let settings: [String: Setting]

    /// Merges the files, nearest ancestor winning.
    ///
    /// Per *key*, not per file: a nearer file overriding one setting does not discard the
    /// rest. That rule is the whole reason the format is a flat map of dotted keys — it
    /// answers "what does inheriting mean" once, for every setting that will ever exist.
    init(files: [String: NodeValue], schemas: [SwiftToolSchema]) {
        self.schemas = schemas

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
            where key.hasPrefix(Self.toolchainPrefix) {
                merged[String(key.dropFirst(Self.toolchainPrefix.count))] =
                    Setting(value: value, sourcePath: path)
            }
        }
        self.settings = merged
    }

    /// The settings one tool should be configured with, its namespace stripped.
    ///
    /// Anything the tool does not accept is dropped here without comment; saying so is
    /// `rejections`' job, once, rather than once per tool.
    func settings(forNamespace namespace: String) -> [String: String] {
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
    var rejections: [String] {
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
                // no tool at all would take it.
                guard !schemas.contains(where: { $0.acceptedSettings.contains(key) }) else { continue }
                messages.append(rejection(setting: setting, key: key, bare: key,
                                          audience: "no Swift tool"))
            }
        }
        return messages.sorted()
    }

    /// Keys the package manifest supplies. Used only to explain a rejection: what stops a
    /// file from setting these is their absence from every tool's accepted set, not this
    /// list. It exists because "the compiler accepts no such setting" is true but unhelpful
    /// for a key the user can plainly see the compiler using.
    private static let manifestSupplied: Set<String> = [
        "moduleName", "parseAsLibrary", "sourcePaths", "excludedPaths",
        "dynamicLibrary", "outputName",
    ]

    private func rejection(setting: Setting, key: String, bare: String, audience: String) -> String {
        let reason = Self.manifestSupplied.contains(bare)
            ? "'\(bare)' comes from the package manifest"
            : "\(audience) accepts '\(bare)'"
        return "\(setting.sourcePath): ignoring '\(Self.toolchainPrefix)\(key)' — \(reason)."
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
