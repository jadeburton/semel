//
//  ServerSession.swift
//  SemelEndToEndTests
//
//  One `semelserv` over one home: started with SEMEL_HOME and SEMEL_SOCKET pointing
//  into it, its socket waited for, and stopped with SIGTERM, which must exit zero and
//  leave no socket file — the same three facts SemelservExecutableTests pins. A session
//  given a `Perturbation` also carries what it varies and starts where it says.
//

import Foundation
import SemelTestSupport

final class ServerSession {

    let home: URL
    let socketPath: String
    /// Applied to the server and, through `environment`, to the client that talks to it.
    let perturbation: Perturbation?
    private var process: ManagedProcess?

    init(home: URL, perturbation: Perturbation? = nil) {
        self.home = home
        self.perturbation = perturbation
        socketPath = home.appendingPathComponent("semelserv.sock").path
    }

    /// The two variables, plus whatever a perturbation varies. The caller passes this to
    /// `semel` as well, so client and server agree on the home and see the same
    /// surroundings.
    var environment: [String: String] {
        ["SEMEL_HOME": home.path, "SEMEL_SOCKET": socketPath]
            .merging(perturbation?.variables ?? [:]) { _, perturbed in perturbed }
    }

    var logTail: String { process?.outputTail() ?? "" }

    func start() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = ManagedProcess(executable: EndToEndRun.binary("semelserv"), arguments: [],
                                     environment: environment, currentDirectory: perturbation?.workingDirectory)
        try process.start()
        self.process = process
        guard SocketWait.wait(forSocketAt: socketPath, timeout: 30) else {
            process.kill()
            _ = process.waitForExit(timeout: 5)
            throw EndToEndFailure(step: "start server", message: "no socket at \(socketPath) after 30 s",
                                  commandLine: process.commandLine, outputTail: process.outputTail())
        }
    }

    /// SIGTERM; a clean exit is part of what is tested.
    func stop() throws {
        guard let process else {
            return
        }
        process.terminate()
        guard let status = process.waitForExit(timeout: 30) else {
            process.kill()
            _ = process.waitForExit(timeout: 5)
            throw EndToEndFailure(step: "stop server", message: "did not exit within 30 s of SIGTERM",
                                  commandLine: process.commandLine, serverLogTail: process.outputTail())
        }
        guard status == 0 else {
            throw EndToEndFailure(step: "stop server", message: "exit status \(status) on SIGTERM",
                                  commandLine: process.commandLine, status: status, serverLogTail: process.outputTail())
        }
        guard !FileManager.default.fileExists(atPath: socketPath) else {
            throw EndToEndFailure(step: "stop server", message: "socket file still there after exit: \(socketPath)")
        }
    }

    /// For a failure path: whatever it takes, no evidence expected.
    func killIfRunning() {
        process?.kill()
        _ = process?.waitForExit(timeout: 5)
    }
}
