//
//  ProjectBuilder.swift
//  build_system
//
//  Created by Jade Burton on 14.06.26.
//

public struct ProjectBuilder: NodeFunction {
    public static let kind: UInt = 6

    static let projectFileInputPort = "projectFile"
    static let productInputPort = "input"
    static let statusOutputPort = "status"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [projectFileInputPort],
                                            outputPorts: [statusOutputPort],
                                            dynamicInputPorts: [productInputPort])

    var embeddedNode: Node?

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    func convertProjectFileFormatToBuildGraphExpectations(projectFileName: String, projectFileContent: String) throws -> [String: String] {
        let parentFolderOfFormulaFile = (Path(projectFileName).deletingLastComponent) ?? Path(".")

        let projectFileProducts: [String: GraphShapeNode] = try FormulaFile.parse(projectFileContent, basePath: parentFolderOfFormulaFile)

        var result = [String: String]()

        for (productName, graphShapeNode) in projectFileProducts {
            let fullPath = Path("outputFileSystem") / (parentFolderOfFormulaFile.deletingFirstComponent ?? Path("")) / Path(productName)
            let graphShape = try GraphShapeNode.parse("OutputFile(path: '\(fullPath)', input <- ['product': \(graphShapeNode.asString(omitOutputPort: false))]).status")
            result[fullPath.string] = graphShape.asString(omitOutputPort: false)
        }

        return result
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        let inputValue = input.inputValues[Self.projectFileInputPort]!.first! // TODO: multiple fmla files and multiple products
        let productInputPortExpectation = try convertProjectFileFormatToBuildGraphExpectations(projectFileName: inputValue.key,
                                                                                               projectFileContent: inputValue.value.expectValue().resolveAsString())
        return .init(outputValues: [Self.statusOutputPort: .value("OK".intern())],
                     inputWireExpectations: [Self.productInputPort: productInputPortExpectation])
    }
}
