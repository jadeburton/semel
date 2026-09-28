//
//  FormulaIdentifier.swift
//  SemelNodeKit
//
//  The names a generated formula gives its funcs, shared by every converter that emits
//  or consumes them. A package's converter emits `modules_Timeline()` and
//  `objects_Timeline()` for product `Timeline`; a project's converter, in another
//  package, calls them by product name. Both go through here, so the two cannot drift.

public enum FormulaIdentifier {

    /// `MyTarget-A` → `MyTarget_A`: a formula identifier is letters, digits and
    /// underscores, and a target or product name is whatever the manifest said.
    public static func sanitized(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber ? $0 : Character("_") })
    }

    /// The func carrying every `.swiftmodule` behind a package product, as a tree.
    public static func modulesFunc(forProduct product: String) -> String {
        "modules_\(sanitized(product))"
    }

    /// The func carrying every object file a package product links, as a tree.
    public static func objectsFunc(forProduct product: String) -> String {
        "objects_\(sanitized(product))"
    }

    /// The func carrying what linking a package product's objects needs beyond them — its
    /// targets' frameworks and libraries, and the C++ runtime — as settings
    /// (`LinkRequirements`). Always defined, empty when nothing is needed, so a consumer
    /// can name it without knowing (B-55).
    public static func linkRequirementsFunc(forProduct product: String) -> String {
        "linking_\(sanitized(product))"
    }

    /// The func carrying the resource bundles of every target behind a package product,
    /// each under its `<Package>_<Target>.bundle/`, as one tree (B-77). Empty when no
    /// target has resources, so a consumer can name it without knowing.
    public static func bundlesFunc(forProduct product: String) -> String {
        "bundles_\(sanitized(product))"
    }

    /// The func carrying one target's resource bundle as a tree.
    public static func bundleFunc(forTarget target: String) -> String {
        "bundle_\(sanitized(target))"
    }

    /// The bundle a target's resources are built into, as SwiftPM names it:
    /// `FoodTruckKit_FoodTruckKit`. `Bundle.module` in the target's code finds it by this
    /// name beside the executable, or under `Contents/Resources` on macOS.
    public static func resourceBundleName(package: String, target: String) -> String {
        "\(package)_\(target)"
    }
}
