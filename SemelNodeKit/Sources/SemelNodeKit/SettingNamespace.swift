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

    // Split on capitals, treating a run of capitals as one word, except that a capital
    // followed by a lowercase letter starts a new word. This yields config-file prefixes
    // that users will type, so "swift.http" (not "swift.hTTP") matters.
    // "SwiftHTTPClient" → ["Swift", "HTTP", "Client"]
    // "SwiftCompiler" → ["Swift", "Compiler"]
    var words: [String] = []
    var current = ""
    let chars = Array(name)

    for (index, character) in chars.enumerated() {
        if character.isUppercase && !current.isEmpty {
            let prevIsLowercase = chars[index - 1].isLowercase
            let nextIsLowercase = index + 1 < chars.count && chars[index + 1].isLowercase

            if prevIsLowercase || nextIsLowercase {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty { words.append(current) }

    guard let domain = words.first else { return "" }
    let rest = words.dropFirst()
    guard !rest.isEmpty else { return domain.lowercasedFirst() }

    // The remainder is one segment, not one per word: the namespace is exactly
    // domain-then-node, and splitting further would invent levels the file does not have.
    // Each word is lower-camelled individually (all-caps words become fully lowercase),
    // then joined in camel case (first word lowercase, subsequent words capitalized).
    let node = rest.enumerated().map { (index, word) in
        let lowered = word.lowercasedFirst()
        if index == 0 {
            return lowered
        } else {
            guard let first = lowered.first else { return lowered }
            return first.uppercased() + lowered.dropFirst()
        }
    }.joined()
    return "\(domain.lowercasedFirst()).\(node)"
}

/// Reads settings that have no default, reporting every one that is missing rather than the
/// first. A message naming one of four missing keys costs four build attempts to fix.
public struct RequiredSettings {
    private let properties: [String: String]
    private let namespace: String
    private var missing: [String] = []

    public init(properties: [String: String], namespace: String) {
        self.properties = properties
        self.namespace = namespace
    }

    public mutating func value(_ key: String) -> String {
        guard let value = properties[key] else {
            missing.append("\(namespace).\(key)")
            return ""
        }
        return value
    }

    public func check() throws {
        guard !missing.isEmpty else { return }
        throw NodeError.other(message: """
            Missing configuration. Add these to a semel.config in the input file system:

            \(missing.sorted().map { "\($0)=…" }.joined(separator: "\n"))

            There are no default values: one baked into Semel would change what this build \
            means when Semel is upgraded.
            """)
    }
}

private extension String {
    func lowercasedFirst() -> String {
        // All-uppercase words (like "HTTP") become fully lowercase.
        // Mixed-case words get only their first letter lowercased.
        let letters = self.filter { $0.isLetter }
        if !letters.isEmpty && letters == letters.uppercased() {
            return self.lowercased()
        }
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
