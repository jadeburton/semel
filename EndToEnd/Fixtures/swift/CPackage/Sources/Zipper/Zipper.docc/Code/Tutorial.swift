// A tutorial's code, kept in the documentation catalog as SwiftTreeSitter keeps a
// package manifest there: the catalog is not the target's sources, and compiled with them
// this would fail, there being no PackageDescription to import in a package target (B-77).
import PackageDescription

let tutorial = Package(name: "Tutorial")
