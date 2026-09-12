//
//  Configuration.swift
//  semel
//
//  Created by Jade Burton on 28.06.26.
//

// Like a StaticFile, but it allows you to put configuration directly into the formula.
import SemelNodeKit

public struct Configuration: Node {
    public static let kind: UInt = 9

    public var thisNode: NodeRecord

    static let outputPort = "output"
    static let inputPort = "inherit"

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.optional(inputPort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        var aggregatedConfig = [String: String]()

        let inputValues = input.inputValues[Self.inputPort] ?? [:]

        for inputPortWireKey in inputValues.keys.sorted() {
            let plainText = try inputValues[inputPortWireKey]!.expectValue().resolveAsString()
            let configuration = [String: String](plainText: plainText)
            aggregatedConfig = aggregatedConfig.mergedWith(configuration)
        }

        return .init(outputValues: [Self.outputPort: .value(try aggregatedConfig.mergedWith(thisNode.properties).asPlainText().intern())],
                     inputWireSpecs: [:])
    }
}

