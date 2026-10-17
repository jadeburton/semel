// SubjectNames.swift
// SemelCLI
//
// How a subject is written — what a failure belongs to, or what a running node is computed
// for (B-145, B-168): its kind as a label, `target`, `source`, and its value as a person
// finds it — a module by its name, a product or a resource by its file name, a source or a
// formula by its path on disk relative to the base. The error report's subject line and
// the monitor's running nodes both write a subject through here, so the two never name one
// thing two ways.

import SemelNodeKit

public enum SubjectNames {

    /// `target`, `product`, `package`, `resource`, `formula`, `project`, `source`.
    public static func label(of subject: ErrorDocument.Subject) -> String {
        switch subject {
        case .target:   return "target"
        case .product:  return "product"
        case .package:  return "package"
        case .resource: return "resource"
        case .formula:  return "formula"
        case .project:  return "project"
        case .source:   return "source"
        }
    }

    /// `Models`, `App`, `Assets.xcassets`, `Sources/App/main.m`.
    public static func value(of subject: ErrorDocument.Subject) -> String {
        switch subject {
        case .target(let name):    return name
        case .package(let name):   return name
        case .product(let path):   return Path(path).lastComponent ?? path
        case .resource(let path):  return Path(path).lastComponent ?? path
        case .project(let path):   return Path(path).lastComponent ?? path
        case .formula(let path):   return displayed(path)
        case .source(let path):    return displayed(path)
        }
    }

    /// A path in the input file system as the reader finds it on disk, relative to the base;
    /// any other path as it is.
    public static func displayed(_ path: String) -> String {
        let root = FileSystemName.input
        if path == root || path == "\(root)/" {
            return "."
        }
        if path.hasPrefix("\(root)/") {
            return String(path.dropFirst(root.count + 1))
        }
        return path
    }
}
