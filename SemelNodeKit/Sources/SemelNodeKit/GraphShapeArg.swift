// GraphShapeArg.swift
// SemelNodeKit
//
// One init-time argument that distinguishes a node from others of its type — `path` for a
// StaticFile, `moduleName` for a compile. It lives here rather than with the rest of the
// graph-shape machinery because `InputlessNodeFunction.graphShapeArgs` names it, so a node
// function cannot be declared without it. Nothing else of GraphShape is API.

public struct GraphShapeArg: Equatable, Hashable {
    public let key:   String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
