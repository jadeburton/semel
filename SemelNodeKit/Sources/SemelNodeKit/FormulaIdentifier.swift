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
}
