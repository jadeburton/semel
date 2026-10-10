// The `#stringify` macro's compiler plugin, speaking the plugin protocol by hand.
//
// A macro is normally written against swift-syntax's `SwiftCompilerPlugin`, which reads
// the compiler's messages and parses what they carry. This one has no dependency, so that
// the fixture builds offline and in seconds: swift-syntax is a large build of its own, and
// the roster's swift-dependencies project builds a macro from it. The protocol is what the
// compiler speaks to any plugin executable: each message is a little-endian 64-bit length
// and that many bytes of JSON, on standard input and output. The compiler first asks for
// the plugin's capability, then sends one `expandFreestandingMacro` per use, carrying the
// use's source text — `#stringify(1 + 2)` — and takes back the expansion's source.

import Foundation

@main
struct StringifyPlugin {
    static func main() {
        while let message = readMessage() {
            writeMessage(reply(to: message))
        }
    }

    /// `#stringify(x)` is `(x, "x")`: the value and the text it was written as.
    static func reply(to message: [String: Any]) -> [String: Any] {
        if message["getCapability"] != nil {
            return ["getCapabilityResult": ["capability": ["protocolVersion": 7]]]
        }
        guard let expansion = message["expandFreestandingMacro"] as? [String: Any],
              let syntax    = expansion["syntax"] as? [String: Any],
              let source    = syntax["source"] as? String,
              let open      = source.firstIndex(of: "("),
              let close     = source.lastIndex(of: ")") else {
            return ["expandMacroResult": ["diagnostics": [] as [Any]]]
        }
        let argument = source[source.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        let quoted   = argument.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return ["expandMacroResult": ["expandedSource": "(\(argument), \"\(quoted)\")", "diagnostics": [] as [Any]]]
    }

    static func readMessage() -> [String: Any]? {
        guard let header = try? FileHandle.standardInput.read(upToCount: 8), header.count == 8 else {
            return nil
        }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard let body = try? FileHandle.standardInput.read(upToCount: Int(length)), body.count == Int(length) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    static func writeMessage(_ message: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else {
            return
        }
        var length = UInt64(body.count).littleEndian
        FileHandle.standardOutput.write(Data(bytes: &length, count: MemoryLayout<UInt64>.size))
        FileHandle.standardOutput.write(body)
    }
}
