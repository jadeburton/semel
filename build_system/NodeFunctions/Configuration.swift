//
//  Configuration.swift
//  build_system
//
//  Created by Jade Burton on 28.06.26.
//

// Like a StaticFile, but it allows you to put configuration directly into the formula.
struct Configuration: InputlessNodeFunction {
    static let kind: UInt = 9

    let properties: [String: String]

    enum CodingKeys: CodingKey {
        case properties
    }

    static let outputPort = "output"

    init() {
        properties = [String: String]()
    }

    init(properties: [String : String] = [String: String]()) {
        self.properties = properties
    }

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [], outputPorts: [outputPort], dynamicInputPorts: [])

    func didCreate(node: Node) throws -> ProcessOutput {

        let standardClang = ToolDescriptor(name: "clang",
                                           version: "Apple clang version 17.0.0 (clang-1700.6.3.2)",
                                           platform: "macOS",
                                           architecture: "arm64",
                                           recursiveHash: nil)

        func outputValue() throws -> PolySerializable {
            switch properties["tool"] {
                case "preprocessor":
                    return try ClangPreprocessorToolConfiguration(toolDescriptor: standardClang, arguments: [], environment: [:])
                case "linker":
                    return try ClangLinkerToolConfiguration(toolDescriptor: standardClang, arguments: [], environment: [:])
                case "compiler":
                    return try ClangCompilerToolConfiguration(toolDescriptor: standardClang, arguments: [], environment: [:])
                default:
                    return try ClangPreprocessorToolConfiguration(toolDescriptor: standardClang, arguments: [], environment: [:])
            }
        }
        return .init(outputValues: [Self.outputPort: .value(try outputValue().toJSON().intern())], inputWireExpectations: [:])
    }
}
