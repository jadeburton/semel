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

/// Recognises one kind of project file and says how to build it.
public protocol ProjectBuilderPlugin {
    /// The `ProjectBuilder` spec string for `entry` inside `folderPath`, or nil if
    /// this plugin does not claim the entry.
    func specString(forEntry entry: FolderManifestEntry, inFolder folderPath: String) -> String?
}

/// The set of registered project kinds.
///
/// A process-global registry, like the other swappable globals: threading it through the
/// engine's discovery walk would cost far more plumbing than it saves, and being swappable
/// is what keeps it testable.
public enum ProjectDiscovery {

    // Keyed by type name so registering the same plugin twice replaces rather than
    // duplicates. Tests re-run registration for every case, and a growing array would
    // leave each test asking the same plugin more times than the last.
    private static var pluginsByTypeName: [String: any ProjectBuilderPlugin] = [:]

    public static func register(_ plugin: any ProjectBuilderPlugin) {
        pluginsByTypeName[String(describing: type(of: plugin))] = plugin
    }

    /// Every registered plugin, in a stable order.
    ///
    /// Sorted rather than in registration order: discovery takes the *first* plugin that
    /// claims an entry, and Dictionary iteration order is seeded per process — so an
    /// unsorted walk could hand the same folder to different plugins on different runs.
    /// No two plugins should claim the same entry, but relying on that silently is how the
    /// non-deterministic bug gets written later.
    public static var plugins: [any ProjectBuilderPlugin] {
        pluginsByTypeName.keys.sorted().compactMap { pluginsByTypeName[$0] }
    }

    /// Drops every registration. For tests that need a known-empty registry.
    public static func removeAll() {
        pluginsByTypeName.removeAll()
        packageFormulaProvidersByTypeName.removeAll()
    }

    // MARK: - Packages named by a formula

    // A `.fmla` names the package it builds with `package <folder>`; only a formula creates
    // a ProjectBuilder, so only a formula's products are published — a dependency package
    // has no builder and no artifacts of its own. Which toolchain turns that folder into a
    // formula is not the engine's to know, so it asks a registered provider.

    private static var packageFormulaProvidersByTypeName: [String: any PackageFormulaProvider] = [:]

    public static func register(packageFormulaProvider provider: any PackageFormulaProvider) {
        packageFormulaProvidersByTypeName[String(describing: type(of: provider))] = provider
    }

    /// Every registered provider, in a stable order (see `plugins`).
    public static var packageFormulaProviders: [any PackageFormulaProvider] {
        packageFormulaProvidersByTypeName.keys.sorted().compactMap { packageFormulaProvidersByTypeName[$0] }
    }
}

/// Turns a package folder into the spec of a node whose output is that package's formula
/// text — for Swift, a `SwiftFormulaConverter` over the folder's `Package.swift`.
public protocol PackageFormulaProvider {
    func formulaSpec(forPackageFolder folder: String) -> String
}
