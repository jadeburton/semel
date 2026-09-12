//
//  FormulaParserTests.swift
//  semel_tests
//

@testable import SemelCore
import XCTest
import SemelNodeKit

final class FormulaParserTests: SemelCoreTestCase {

    private func parse(_ source: String) throws -> [String: GraphSpecNode] {
        try FormulaFile.parse(source, basePath: Path("."), wildcardExpander: { _ in [] })
    }

    // MARK: - Leaf node construction

    func test_leafNode_typeName() throws {
        let result = try parse("product \"X\" = StaticFile(path: 'src/hello.c').output")
        XCTAssertEqual(result["X"]?.typeName, "StaticFile")
    }

    func test_leafNode_arg() throws {
        let result = try parse("product \"X\" = StaticFile(path: 'src/hello.c').output")
        XCTAssertEqual(result["X"]?.properties, [GraphSpecProperty(key: "path", value: "src/hello.c")])
    }

    func test_leafNode_outputPort() throws {
        let result = try parse("product \"X\" = StaticFile(path: 'src/hello.c').output")
        XCTAssertEqual(result["X"]?.outputPort, "output")
    }

    func test_leafNode_noOutputPort_resolvesToTheTypesSingleOutputPort() throws {
        // A node constructor without an explicit .port is resolved against the registered
        // type: StaticFile declares exactly one output port, so that is what it gets.
        let result = try parse("product \"X\" = StaticFile(path: 'src/hello.c')")
        XCTAssertEqual(result["X"]?.outputPort, "output")
    }

    // Only an unregistered type leaves the placeholder in place — there is nothing
    // downstream that resolves "_default", so this is a formula naming a type that does
    // not exist, not a deferred resolution.
    func test_leafNode_noOutputPort_unknownType_keepsPlaceholder() throws {
        let result = try parse("product \"X\" = NoSuchNodeType(path: 'src/hello.c')")
        XCTAssertEqual(result["X"]?.outputPort, "_default")
    }

    func test_leafNode_multipleArgs() throws {
        let result = try parse("product \"X\" = Tool(name: 'foo', version: '1.0').output")
        let node = try XCTUnwrap(result["X"])
        XCTAssertEqual(node.properties.count, 2)
        XCTAssertEqual(node.properties[0], GraphSpecProperty(key: "name", value: "foo"))
        XCTAssertEqual(node.properties[1], GraphSpecProperty(key: "version", value: "1.0"))
    }

    // MARK: - No-arg node

    func test_noArgNode_typeName() throws {
        let result = try parse("product \"X\" = Configuration().output")
        XCTAssertEqual(result["X"]?.typeName, "Configuration")
    }

    func test_noArgNode_emptyArgs() throws {
        let result = try parse("product \"X\" = Configuration().output")
        XCTAssertEqual(result["X"]?.properties, [])
    }

    func test_noArgNode_outputPort() throws {
        let result = try parse("product \"X\" = Configuration().output")
        XCTAssertEqual(result["X"]?.outputPort, "output")
    }

    // MARK: - Wire input ports

    func test_wire_portName() throws {
        let result = try parse(
            "product \"X\" = Tool(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output"
        )
        XCTAssertEqual(result["X"]?.inputs.first?.portName, "input")
    }

    func test_wire_wireName() throws {
        let result = try parse(
            "product \"X\" = Tool(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output"
        )
        XCTAssertEqual(result["X"]?.inputs.first?.wires.first?.name, "hello.c")
    }

    func test_wire_upstreamNodeTypeName() throws {
        let result = try parse(
            "product \"X\" = Tool(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output"
        )
        XCTAssertEqual(result["X"]?.inputs.first?.wires.first?.node.typeName, "StaticFile")
    }

    func test_wire_upstreamNodeOutputPort() throws {
        let result = try parse(
            "product \"X\" = Tool(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output"
        )
        XCTAssertEqual(result["X"]?.inputs.first?.wires.first?.node.outputPort, "output")
    }

    func test_multipleWires_count() throws {
        let result = try parse(
            "product \"X\" = Linker(input: [\"a.o\": Compiler(path: 'a').output, \"b.o\": Compiler(path: 'b').output]).output"
        )
        XCTAssertEqual(result["X"]?.inputs.first?.wires.count, 2)
    }

    func test_multipleWires_firstWireName() throws {
        let result = try parse(
            "product \"X\" = Linker(input: [\"a.o\": Compiler(path: 'a').output, \"b.o\": Compiler(path: 'b').output]).output"
        )
        XCTAssertEqual(result["X"]?.inputs.first?.wires[0].name, "a.o")
    }

    func test_multipleWires_secondWireName() throws {
        let result = try parse(
            "product \"X\" = Linker(input: [\"a.o\": Compiler(path: 'a').output, \"b.o\": Compiler(path: 'b').output]).output"
        )
        XCTAssertEqual(result["X"]?.inputs.first?.wires[1].name, "b.o")
    }

    func test_multipleInputPorts_count() throws {
        let result = try parse("""
            product "X" = Tool(
                config: ["c": Configuration().output],
                input : ["f": StaticFile(path: 'f').output]
            ).output
            """)
        XCTAssertEqual(result["X"]?.inputs.count, 2)
    }

    func test_multipleInputPorts_portNames() throws {
        let result = try parse("""
            product "X" = Tool(
                config: ["c": Configuration().output],
                input : ["f": StaticFile(path: 'f').output]
            ).output
            """)
        let portNames = result["X"]?.inputs.map(\.portName) ?? []
        XCTAssertTrue(portNames.contains("config"))
        XCTAssertTrue(portNames.contains("input"))
    }

    // MARK: - Zero-param function

    func test_zeroParamFunc_callSite_isInlined() throws {
        let result = try parse("""
            func path() = 'src/hello.c'
            product "X" = StaticFile(path: path()).output
            """)
        XCTAssertEqual(result["X"]?.properties.first?.value, "src/hello.c")
    }

    // MARK: - One-param function, positional call

    func test_oneParamFunc_positional_typeName() throws {
        let result = try parse("""
            func file(path) = StaticFile(path: path).output
            product "X" = file('src/hello.c')
            """)
        XCTAssertEqual(result["X"]?.typeName, "StaticFile")
    }

    func test_oneParamFunc_positional_argValue() throws {
        let result = try parse("""
            func file(path) = StaticFile(path: path).output
            product "X" = file('src/hello.c')
            """)
        XCTAssertEqual(result["X"]?.properties.first?.value, "src/hello.c")
    }

    func test_oneParamFunc_positional_port() throws {
        let result = try parse("""
            func file(path) = StaticFile(path: path).output
            product "X" = file('src/hello.c')
            """)
        XCTAssertEqual(result["X"]?.outputPort, "output")
    }

    // MARK: - One-param function, named call

    func test_oneParamFunc_namedArg_argValue() throws {
        let result = try parse("""
            func file(path) = StaticFile(path: path).output
            product "X" = file(path: 'src/hello.c')
            """)
        XCTAssertEqual(result["X"]?.properties.first?.value, "src/hello.c")
    }

    // MARK: - Two-param function

    func test_twoParamFunc_positionalArgs() throws {
        let result = try parse("""
            func make(name, ext) = Artifact(name: name, ext: ext).output
            product "X" = make('foo', 'o')
            """)
        let node = try XCTUnwrap(result["X"])
        XCTAssertEqual(node.properties.first(where: { $0.key == "name" })?.value, "foo")
        XCTAssertEqual(node.properties.first(where: { $0.key == "ext" })?.value, "o")
    }

    // MARK: - Forward reference

    func test_forwardReference_productBeforeFunc() throws {
        let result = try parse("""
            product "X" = file('src/hello.c')
            func file(path) = StaticFile(path: path).output
            """)
        XCTAssertEqual(result["X"]?.typeName, "StaticFile")
        XCTAssertEqual(result["X"]?.properties.first?.value, "src/hello.c")
    }

    // MARK: - Parameter shadowing

    func test_parameterShadowing_localOverridesGlobal() throws {
        let result = try parse("""
            func path() = 'global/path'
            func file(path) = StaticFile(path: path).output
            product "X" = file('local/path')
            """)
        XCTAssertEqual(result["X"]?.properties.first?.value, "local/path")
    }

    // MARK: - Comments

    func test_lineComment_isIgnored() throws {
        let result = try parse("""
            // This is a comment
            product "X" = StaticFile(path: 'hello').output
            // Another comment
            """)
        XCTAssertNotNil(result["X"])
    }

    func test_inlineComment_isIgnored() throws {
        let result = try parse("""
            func path() = 'hello' // inline comment after body
            product "X" = StaticFile(path: path()).output
            """)
        XCTAssertNotNil(result["X"])
    }

    // MARK: - Multiple products

    func test_multipleProducts_count() throws {
        let result = try parse("""
            product "A" = StaticFile(path: 'a').output
            product "B" = StaticFile(path: 'b').output
            """)
        XCTAssertEqual(result.count, 2)
    }

    func test_multipleProducts_keysPresent() throws {
        let result = try parse("""
            product "A" = StaticFile(path: 'a').output
            product "B" = StaticFile(path: 'b').output
            """)
        XCTAssertNotNil(result["A"])
        XCTAssertNotNil(result["B"])
    }

    func test_multipleProducts_independentValues() throws {
        let result = try parse("""
            product "A" = StaticFile(path: 'a').output
            product "B" = StaticFile(path: 'b').output
            """)
        XCTAssertEqual(result["A"]?.properties.first?.value, "a")
        XCTAssertEqual(result["B"]?.properties.first?.value, "b")
    }

    // MARK: - Double-quoted strings

    func test_doubleQuotedString_inProperty() throws {
        let result = try parse("product \"X\" = StaticFile(path: \"src/hello.c\").output")
        XCTAssertEqual(result["X"]?.properties.first?.value, "src/hello.c")
    }

    func test_singleQuotedProductName() throws {
        // Product names support single-quoted names via the lexer.
        let result = try parse("product 'My.Product' = StaticFile(path: 'hello').output")
        XCTAssertNotNil(result["My.Product"])
    }

    // MARK: - Full spec example

    private let specExample = """
        // code comments allowed

        func path() = 'input:/swift/Package.swift'

        // note: the "path" symbol resolves to the parameter, not the global function.
        func file(path) = StaticFile(path: path).output

        func result(path) = SwiftPackageReader(
          configuration: ['config': Configuration().output],
          packageFile: ["Package.swift": file(path)]
        ).packageJSON

        product "Package.json" = result(path())
        product "Extra.json" = result(path: 'input:/swift/Extra/Package.swift')
        """

    func test_specExample_packageJson_typeName() throws {
        let result = try parse(specExample)
        XCTAssertEqual(result["Package.json"]?.typeName, "SwiftPackageReader")
    }

    func test_specExample_packageJson_outputPort() throws {
        let result = try parse(specExample)
        XCTAssertEqual(result["Package.json"]?.outputPort, "packageJSON")
    }

    func test_specExample_packageJson_inputPortCount() throws {
        let result = try parse(specExample)
        XCTAssertEqual(result["Package.json"]?.inputs.count, 2)
    }

    func test_specExample_configurationWire_name() throws {
        let result = try parse(specExample)
        let node = try XCTUnwrap(result["Package.json"])
        let port = try XCTUnwrap(node.inputs.first(where: { $0.portName == "configuration" }))
        XCTAssertEqual(port.wires.first?.name, "config")
    }

    func test_specExample_configurationWire_upstreamType() throws {
        let result = try parse(specExample)
        let node = try XCTUnwrap(result["Package.json"])
        let port = try XCTUnwrap(node.inputs.first(where: { $0.portName == "configuration" }))
        XCTAssertEqual(port.wires.first?.node.typeName, "Configuration")
    }

    func test_specExample_configurationWire_upstreamPort() throws {
        let result = try parse(specExample)
        let node = try XCTUnwrap(result["Package.json"])
        let port = try XCTUnwrap(node.inputs.first(where: { $0.portName == "configuration" }))
        XCTAssertEqual(port.wires.first?.node.outputPort, "output")
    }

    func test_specExample_packageFileWire_name() throws {
        let result = try parse(specExample)
        let node = try XCTUnwrap(result["Package.json"])
        let port = try XCTUnwrap(node.inputs.first(where: { $0.portName == "packageFile" }))
        XCTAssertEqual(port.wires.first?.name, "Package.swift")
    }

    func test_specExample_packageFileWire_staticFileType() throws {
        let result = try parse(specExample)
        let node = try XCTUnwrap(result["Package.json"])
        let port = try XCTUnwrap(node.inputs.first(where: { $0.portName == "packageFile" }))
        XCTAssertEqual(port.wires.first?.node.typeName, "StaticFile")
    }

    func test_specExample_packageFileWire_pathArg() throws {
        let result = try parse(specExample)
        let node = try XCTUnwrap(result["Package.json"])
        let port = try XCTUnwrap(node.inputs.first(where: { $0.portName == "packageFile" }))
        let staticFile = try XCTUnwrap(port.wires.first?.node)
        XCTAssertEqual(staticFile.properties.first?.value, "input:/swift/Package.swift")
    }

    func test_specExample_extraJson_differentPath() throws {
        let result = try parse(specExample)
        let node = try XCTUnwrap(result["Extra.json"])
        let port = try XCTUnwrap(node.inputs.first(where: { $0.portName == "packageFile" }))
        let staticFile = try XCTUnwrap(port.wires.first?.node)
        XCTAssertEqual(staticFile.properties.first?.value, "input:/swift/Extra/Package.swift")
    }

    func test_specExample_extraJson_sameStructureAsPackageJson() throws {
        let result = try parse(specExample)
        let pkgNode   = try XCTUnwrap(result["Package.json"])
        let extraNode = try XCTUnwrap(result["Extra.json"])
        // Both products should resolve to SwiftPackageReader with the same port layout
        XCTAssertEqual(pkgNode.typeName,   extraNode.typeName)
        XCTAssertEqual(pkgNode.outputPort, extraNode.outputPort)
        XCTAssertEqual(pkgNode.inputs.count, extraNode.inputs.count)
    }

    // MARK: - Error cases

    func test_error_undefinedIdentifier_inNodeProperty() {
        XCTAssertThrowsError(try parse(
            "product \"X\" = StaticFile(path: missing).output"
        ))
    }

    func test_error_undefinedIdentifier_inFunctionBody() {
        XCTAssertThrowsError(try parse("""
            func foo(x) = StaticFile(path: y).output
            product "X" = foo('hello')
            """))
    }

    func test_error_wrongArgumentCount_tooMany() {
        XCTAssertThrowsError(try parse("""
            func noArgs() = 'literal'
            product "X" = noArgs('extra').output
            """))
    }

    func test_error_positionalArgInNodeConstruction() {
        XCTAssertThrowsError(try parse(
            "product \"X\" = StaticFile('hello').output"
        ))
    }

    func test_error_wireSyntaxInFunctionCall() {
        XCTAssertThrowsError(try parse("""
            func foo(x) = StaticFile(path: x).output
            product "X" = foo(x: ["k": StaticFile(path: 'a').output])
            """))
    }

    func test_error_productResolvesToString() {
        XCTAssertThrowsError(try parse("""
            func str() = 'just a string'
            product "X" = str()
            """))
    }

    func test_error_unterminatedString() {
        XCTAssertThrowsError(try parse(
            "product \"X\" = StaticFile(path: 'unterminated)"
        ))
    }

    func test_error_unknownTokenAtTopLevel() {
        XCTAssertThrowsError(try parse(
            "StaticFile(path: 'hello')"
        ))
    }

    // MARK: - package <folder>

    /// B-10. A formula names the package it builds; the package's generated formula is
    /// merged in before resolution, so its products are the formula's products and its
    /// funcs are callable from the formula's own definitions.
    private func parse(_ source: String, packageFormulas: [String: String]) throws -> [String: GraphSpecNode] {
        try FormulaFile.parse(source, basePath: Path("input:/repo"),
                              wildcardExpander: { _ in [] },
                              packageFormulaReader: { packageFormulas[$0] })
    }

    func test_aPackagesProductsBecomeTheFormulasProducts() throws {
        let result = try parse("package <.>", packageFormulas: [
            "input:/repo": "product 'libX.a' = StaticFile(path: 'input:/repo/x').output",
        ])

        XCTAssertEqual(result["libX.a"]?.typeName, "StaticFile")
    }

    func test_theFormulaCanCallThePackagesFuncsAndAddProducts() throws {
        let result = try parse("""
            package <.>
            product 'extra' = compilerX()
            """, packageFormulas: [
            "input:/repo": """
                func compilerX() = StaticFile(path: 'input:/repo/x').output
                product 'libX.a' = compilerX()
                """,
        ])

        XCTAssertEqual(Set(result.keys), ["libX.a", "extra"])
        XCTAssertEqual(result["extra"]?.typeName, "StaticFile")
    }

    /// The package folder is a path literal, resolved like every other: `<pkg>` under the
    /// formula's folder, `<.>` the folder itself.
    func test_thePackageFolderIsResolvedAgainstTheFormulasFolder() throws {
        var asked: [String] = []
        _ = try FormulaFile.parse("package <Sub/pkg>", basePath: Path("input:/repo"),
                                  wildcardExpander: { _ in [] },
                                  packageFormulaReader: { asked.append($0); return nil })

        XCTAssertEqual(asked, ["input:/repo/Sub/pkg"])
    }

    /// Until the package's formula is on the wire nothing can be resolved — the formula's
    /// own products may call the package's funcs — so the result is empty and the caller,
    /// having been asked for the folder, wires it and returns later.
    func test_aPackageWhoseFormulaIsNotYetAvailableYieldsNoProducts() throws {
        let result = try parse("""
            package <.>
            product 'extra' = compilerX()
            """, packageFormulas: [:])

        XCTAssertTrue(result.isEmpty)
    }

    func test_twoPackageReferencesAreRejected() {
        XCTAssertThrowsError(try parse("package <a>\npackage <b>", packageFormulas: [:])) { error in
            XCTAssertTrue(String(describing: error).contains("one package"), "got \(error)")
        }
    }

    /// A func or product the formula defines under a generated name is an error, not a
    /// silent override: the author cannot see the names the package generates.
    func test_aNameDefinedByBothTheFormulaAndThePackageIsRejected() {
        XCTAssertThrowsError(try parse("""
            package <.>
            func compilerX() = StaticFile(path: 'input:/repo/y').output
            """, packageFormulas: [
            "input:/repo": "func compilerX() = StaticFile(path: 'input:/repo/x').output",
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("compilerX"), "got \(error)")
        }
    }
}
