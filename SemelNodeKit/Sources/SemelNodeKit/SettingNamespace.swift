// SettingNamespace.swift
// SemelNodeKit
//
// Where a node's settings live in a config file.
//
// A config file is one flat namespace holding every node's settings, so each node needs a
// place in it that nothing else can claim. Deriving that place from the type name keeps the
// two from drifting apart as settings are added.
//
// The cost is that a type rename is a breaking change to every config file written against it.
// So a type may pin its namespace instead, which is what lets it be renamed after its
// namespace is public.

/// `SwiftCompilerTool` → `swift.compiler`. The first word is the domain, the rest is the node.
public func derivedSettingNamespace(forTypeName typeName: String) -> String {
    var name = typeName
    if name.hasSuffix("Tool") {
        name.removeLast("Tool".count)
    }

    // Split on capitals: "SwiftPackageReader" → ["Swift", "Package", "Reader"].
    var words: [String] = []
    var current = ""
    for character in name {
        if character.isUppercase && !current.isEmpty {
            words.append(current)
            current = ""
        }
        current.append(character)
    }
    if !current.isEmpty { words.append(current) }

    guard let domain = words.first else { return "" }
    let rest = words.dropFirst()
    guard !rest.isEmpty else { return domain.lowercasedFirst() }

    // The remainder is one segment, not one per word: the namespace is exactly
    // domain-then-node, and splitting further would invent levels the file does not have.
    let node = rest.joined().lowercasedFirst()
    return "\(domain.lowercasedFirst()).\(node)"
}

private extension String {
    func lowercasedFirst() -> String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
