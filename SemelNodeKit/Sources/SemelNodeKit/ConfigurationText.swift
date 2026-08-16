// ConfigurationText.swift
// SemelNodeKit
//
// How a node's configuration is carried on a wire: one `key=value` per line.
//
// Every node function parses its configuration this way, so the format belongs with the
// node-authoring API rather than inside the Configuration node that happens to produce it.
// One consequence worth knowing when adding a setting: a value cannot contain a newline.

public extension Dictionary where Key == String, Value == String {

    func mergedWith(_ other: [String: String]) -> [String: String] {
        var result = self
        for (key, value) in other {
            result[key] = value
        }
        return result
    }

    init(plainText: String) {
        var result: [String: String] = [:]
        let lines = plainText.split(separator: "\n")
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0])
                let value = String(parts[1])
                result[key] = value
            }
        }
        self = result
    }

    func asPlainText() -> String {
        self.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}
