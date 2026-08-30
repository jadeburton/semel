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
        for line in plainText.split(separator: "\n") {
            // A leading `#` is a comment, recognised rather than merely failing to parse.
            // Commenting a setting out is how one gets disabled, and
            // `# swift.compiler.sdkVersion=26.5` splits on `=` like any other line — so
            // without this the line a user believes they switched off is still in force.
            // Only a leading `#`: a value may contain one, and there is no trailing-comment
            // form to take it away from them.
            guard line.drop(while: { $0 == " " || $0 == "\t" }).first != "#" else { continue }

            // Empty subsequences are omitted, so `key=` yields one part and is dropped: a
            // setting with nothing after the `=` is absent, not present-and-empty. That is
            // what lets an optional value round-trip through `asPlainText()` — it is written
            // as empty and read back as missing rather than as "".
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
