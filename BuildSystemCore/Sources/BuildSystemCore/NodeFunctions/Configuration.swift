//
//  Configuration.swift
//  build_system
//
//  Created by Jade Burton on 28.06.26.
//

// Like a StaticFile, but it allows you to put configuration directly into the formula.
public struct Configuration: NodeFunction {
    public static let kind: UInt = 9

    var embeddedNode: Node?

    static let outputPort = "output"
    static let inputPort = "inherit"

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    static let descriptor = NodeFunctionDescriptor(
        inputPorts: [.optional(inputPort)],
        outputPorts: [outputPort]
    )

    func process(input: ProcessInput) throws -> ProcessOutput {
        var aggregatedConfig = [String: String]()

        let inputValues = input.inputValues[Self.inputPort] ?? [:]

        for inputPortWireKey in inputValues.keys.sorted() {
            let plainText = try inputValues[inputPortWireKey]!.expectValue().resolveAsString()
            let configuration = [String: String](plainText: plainText)
            aggregatedConfig = aggregatedConfig.mergedWith(configuration)
        }

        return .init(outputValues: [Self.outputPort: .value(aggregatedConfig.mergedWith(thisNode.properties).asPlainText().intern())],
                     inputWireExpectations: [:])
    }
}

extension [String: String] {
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
        self.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}
