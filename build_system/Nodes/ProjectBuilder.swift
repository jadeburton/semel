//
//  ProjectBuilder.swift
//  build_system
//
//  Created by Jade Burton on 14.06.26.
//

/// Reads a single formula.json file and passes its text content through to
/// BuildGraph's formulae input port.
struct ProjectBuilder: NodeFunction {
    static let kind: UInt = 6

    enum CodingKeys: CodingKey {}

    static let projectFileInputPort = "projectFile"
    static let productInputPort = "input"
    static let statusOutputPort = "status"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [projectFileInputPort], outputPorts: [statusOutputPort], dynamicInputPorts: [productInputPort])

    func convertProjectFileFormatToBuildGraphExpectations(projectFileContent: String) throws -> [String: String] {
        ["mylib.dylib":"ClangLinkerTool(input=ClangCompilerTool(input=ClangPreprocessorTool(input=StaticFile('hello.c').output,configuration=StaticFile('hello.c').output).output).output)"]
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        let projectFileValue = try input.inputValues[Self.projectFileInputPort]!.first!.value.expectValue().resolveAsString()
        let productInputPortExpectation = try convertProjectFileFormatToBuildGraphExpectations(projectFileContent: projectFileValue)
        return .init(outputValues: [Self.statusOutputPort: .value("OK".intern())], inputWireExpectations: [Self.productInputPort: productInputPortExpectation])
    }
}
