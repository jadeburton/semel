// ProjectDiscovery.swift
// SemelNodeKit
//
// How a package teaches the engine to recognise a kind of project.
//
// The engine walks the input file system and, for each entry it finds, asks the registered
// plugins whether any of them claims it — a `.fmla` file, a `Package.swift`, a
// `CMakeLists.txt` later. Whichever claims it returns the graph spec that builds it.
//
// This lives in the node-authoring API rather than the engine for the same reason the node
// protocols do: a toolchain package has to be able to contribute one without depending on
// the engine, which is the dependency direction that makes the engine toolchain-agnostic.

import Foundation

/// Recognises one kind of project file and says how to build it.
public protocol ProjectBuilderPlugin {
    /// The `ProjectBuilder` tree for `entry` inside `folderPath`, or nil if
    /// this plugin does not claim the entry.
    func spec(forEntry entry: FolderManifestEntry, inFolder folderPath: String) -> GraphSpecNode?
}

/// The set of registered project kinds.
///
/// A process-global registry, like the other swappable globals: threading it through the
/// engine's discovery walk would cost far more plumbing than it saves, and being swappable
/// is what keeps it testable.
public enum ProjectDiscovery {

    /// Guards both registries: a host registers while an engine's compute threads walk
    /// them, and a Dictionary read concurrent with a write is undefined, not merely stale.
    private static let lock = NSLock()

    // Keyed by type name so registering the same plugin twice replaces rather than
    // duplicates. Tests re-run registration for every case, and a growing array would
    // leave each test asking the same plugin more times than the last.
    private static var pluginsByTypeName: [String: any ProjectBuilderPlugin] = [:]

    public static func register(_ plugin: any ProjectBuilderPlugin) {
        lock.withLock { pluginsByTypeName[String(describing: type(of: plugin))] = plugin }
    }

    /// Every registered plugin, in a stable order.
    ///
    /// Sorted rather than in registration order: discovery takes the *first* plugin that
    /// claims an entry, and Dictionary iteration order is seeded per process — so an
    /// unsorted walk could hand the same folder to different plugins on different runs.
    /// No two plugins should claim the same entry, but relying on that silently is how the
    /// non-deterministic bug gets written later.
    public static var plugins: [any ProjectBuilderPlugin] {
        lock.withLock { pluginsByTypeName.keys.sorted().compactMap { pluginsByTypeName[$0] } }
    }

    /// Drops every registration. For tests that need a known-empty registry.
    public static func removeAll() {
        lock.withLock {
            pluginsByTypeName.removeAll()
            includablePluginsByTypeName.removeAll()
        }
    }

    // MARK: - Projects a formula names

    // Keyed by type name, for the reason `pluginsByTypeName` is.
    private static var includablePluginsByTypeName: [String: any IncludableProjectPlugin] = [:]

    public static func register(includable plugin: any IncludableProjectPlugin) {
        lock.withLock { includablePluginsByTypeName[String(describing: type(of: plugin))] = plugin }
    }

    /// Every registered includable-project plugin, in a stable order, for the reason
    /// `plugins` is sorted.
    public static var includablePlugins: [any IncludableProjectPlugin] {
        lock.withLock { includablePluginsByTypeName.keys.sorted().compactMap { includablePluginsByTypeName[$0] } }
    }
}

/// Recognises a project file that builds nothing by itself: a formula has to `include` the
/// node that converts it — a `Package.swift` is built by
/// `include SwiftFormulaConverter(path: <.>).formula`, never by being pushed (B-10). The
/// engine asks this of every file it sees and says so at idle when nothing reads one, which
/// is the only way a user learns that a pushed package builds nothing.
///
/// Separate from `ProjectBuilderPlugin`, which claims a file *as* a project and builds it:
/// this one claims a file only to say what would build it.
public protocol IncludableProjectPlugin {
    /// The node a formula's `include` names to build `entry` inside `folderPath`, or nil
    /// when the entry is not this plugin's — or is one a formula reaches through another,
    /// as a package's vendored dependencies are reached through the package.
    func includeSpec(forEntry entry: FolderManifestEntry, inFolder folderPath: String) -> GraphSpecNode?
}
