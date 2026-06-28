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

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [projectFileInputPort],
                                            outputPorts: [statusOutputPort],
                                            dynamicInputPorts: [productInputPort])

    var properties: [String : String] {
        [:]
    }

    init(properties: [String : String]) {
    }

    func convertProjectFileFormatToBuildGraphExpectations(projectFileName: String, projectFileContent: String) throws -> [String: String] {
        let graphShape = try GraphShapeNode.parse("OutputFile(path: '\(projectFileName.removingSuffix(".fmla"))', input <- ['product': \(projectFileContent)]).status")
        return [projectFileName.removingSuffix(".fmla"): graphShape.asString(omitOutputPort: false)]
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        let inputValue = input.inputValues[Self.projectFileInputPort]!.first!
        let productInputPortExpectation = try convertProjectFileFormatToBuildGraphExpectations(projectFileName: inputValue.key,
                                                                                               projectFileContent: inputValue.value.expectValue().resolveAsString())
        return .init(outputValues: [Self.statusOutputPort: .value("OK".intern())],
                     inputWireExpectations: [Self.productInputPort: productInputPortExpectation])
    }
}
