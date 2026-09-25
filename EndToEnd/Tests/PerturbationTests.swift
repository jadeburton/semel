//
//  PerturbationTests.swift
//  SemelEndToEndTests
//

import XCTest

final class PerturbationTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("perturbation-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Both directories the perturbation names are made under the run's own root, so the
    /// build's temporary files and its working directory are swept with the root.
    func test_theDirectoriesItNamesExistUnderTheRoot() throws {
        let root = try makeRoot()
        let perturbation = try Perturbation.under(root: root)

        let temporary = try XCTUnwrap(perturbation.variables["TMPDIR"])
        XCTAssertTrue(temporary.hasPrefix(root.path + "/"), temporary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary))
        XCTAssertTrue(perturbation.workingDirectory.path.hasPrefix(root.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: perturbation.workingDirectory.path))
    }

    /// The locale is one the machine has — the check is what keeps a tool from rejecting
    /// it — and a UTF-8 one either way, so the perturbation changes collation and number
    /// formatting without changing the encoding a tool reads its inputs in.
    func test_theLocaleIsInstalledAndIsUTF8() throws {
        let locale = Perturbation.installedLocale
        XCTAssertTrue(locale.hasSuffix(".UTF-8"), locale)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/locale")
        process.arguments = ["-a"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let listed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        XCTAssertTrue(listed.split(separator: "\n").map(String.init).contains(locale),
                      "locale -a does not list \(locale)")
    }

    /// Every variable the perturbation varies is in the description, so a failure says
    /// what to set by hand to see the difference again.
    func test_theDescriptionNamesEveryVariableItVaries() throws {
        let perturbation = try Perturbation.under(root: try makeRoot())
        for name in perturbation.variables.keys {
            XCTAssertTrue(perturbation.description.contains(name), "\(name) is not in \(perturbation.description)")
        }
        XCTAssertTrue(perturbation.description.contains(perturbation.workingDirectory.path))
    }

    /// A perturbed session hands both processes what it varies, and the home it was
    /// opened over survives it: `SEMEL_HOME` and `SEMEL_SOCKET` are the session's own.
    func test_aPerturbedSessionCarriesTheVariablesBesideTheHome() throws {
        let root = try makeRoot()
        let perturbation = try Perturbation.under(root: root)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let session = ServerSession(home: home, perturbation: perturbation)

        XCTAssertEqual(session.environment["SEMEL_HOME"], home.path)
        XCTAssertEqual(session.environment["SEMEL_SOCKET"], session.socketPath)
        for (name, value) in perturbation.variables {
            XCTAssertEqual(session.environment[name], value)
        }
    }
}
