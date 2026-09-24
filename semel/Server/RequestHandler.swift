// RequestHandler.swift
// SemelServer
//
// The bottleneck. Everything a client can ask of the engine arrives here as a typed
// `Request` and leaves as a typed `Response`; nothing else in the server touches the
// graph on a client's behalf. In one process the in-process connection calls it; with a
// socket, the listener does. Either way the handler does not know.
//
// Requests are handled on one serial queue, which is the role the REPL thread plays
// against the engine's background task: GRDB's queue and the task-local transaction
// nesting already make that safe, so two clients issuing commands at once take turns.

import Foundation
import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol

public final class RequestHandler {

    let engine:   BuildEngine
    let database: DatabaseLayer

    private let databasePath: String
    private let queue = DispatchQueue(label: "semelserv.requests")

    /// Where events go. Weak, because the in-process connection is both the sink and the
    /// owner of this handler.
    ///
    /// Whoever installs a sink must also retain it; a server whose sink is not owned by a
    /// connection keeps it alive itself, or events vanish without an error.
    public weak var eventSink: EventSink?

    public init(engine: BuildEngine, database: DatabaseLayer, databasePath: String) {
        self.engine       = engine
        self.database     = database
        self.databasePath = databasePath
        installReporters()
    }

    // MARK: - Entry point

    public func handle(_ request: Request, body: Data?, session: Session) -> (Response, Data?) {
        // A wait observes; it does not mutate. Off the queue so a client waiting for the
        // graph to settle does not hold every other client's commands behind it.
        // It parks the caller's thread, which must therefore not be one of the cooperative pool's — the engine's loop runs there and would have nothing left to settle on.
        if case .daemon(.wait) = request {
            engine.waitUntilIdleBlocking()
            return (.daemon(.ok), nil)
        }

        return queue.sync { () -> (Response, Data?) in
            switch request {
            case .hello(let hello):
                return (.hello(answer(hello)), nil)
            case .daemon(let daemonRequest):
                return handleDaemon(daemonRequest, body: body, session: session)
            }
        }
    }

    /// Unwinds whatever the session left open, so a client that vanished mid-push cannot
    /// leave the engine's work signals suppressed.
    public func endSession(_ session: Session) {
        queue.sync {
            while session.openBatchDepth > 0 {
                engine.endBatch()
                session.batchClosed()
            }
        }
    }

    // MARK: - Hello

    private func answer(_ hello: Hello) -> HelloResponse {
        guard hello.protocolVersion == ProtocolVersion.current else {
            return .rejected(reason: .versionMismatch(client: hello.protocolVersion, server: ProtocolVersion.current))
        }
        guard hello.role == .daemon else {
            return .rejected(reason: .roleNotOffered(role: hello.role))
        }
        return .accepted(serverVersion: Semel.version, databasePath: databasePath)
    }

    // MARK: - Daemon dispatch

    private func handleDaemon(_ request: DaemonRequest, body: Data?, session: Session) -> (Response, Data?) {
        do {
            switch request {
            case .list(let fileSystem, let pattern):
                return (.daemon(try list(fileSystem: fileSystem, pattern: pattern)), nil)
            case .beginBatch:
                engine.beginBatch()
                session.batchOpened()
                return (.daemon(.ok), nil)
            case .endBatch:
                guard session.openBatchDepth > 0 else {
                    return (.daemon(.ok), nil)
                }
                engine.endBatch()
                session.batchClosed()
                return (.daemon(.ok), nil)
            case .pushFile(let path, let mode):
                return (.daemon(try pushFile(path: path, mode: mode, body: body ?? Data())), nil)
            case .pushFolder(let path):
                return (.daemon(try pushFolder(path: path)), nil)
            case .remove(let pattern):
                return (.daemon(try remove(pattern: pattern)), nil)
            case .fetch(let fileSystem, let path):
                let (response, bytes) = try fetch(fileSystem: fileSystem, path: path)
                return (.daemon(response), bytes)
            case .errors:
                return (.daemon(.errors(records: try errorRecords())), nil)
            case .tools:
                return (.daemon(.tools(namespaces: toolNamespaces())), nil)
            case .reset:
                try engine.reset()
                return (.daemon(.ok), nil)
            case .nudge:
                try engine.nudge()
                return (.daemon(.ok), nil)
            case .wait:
                // Answered in `handle`, before the queue. Unreachable here, and the switch
                // wants every case.
                return (.daemon(.ok), nil)
            case .debug:
                return (.daemon(.debug), Data(try engine.graphDescription().utf8))
            case .subscribe:
                session.isSubscribed = true
                return (.daemon(.ok), nil)
            }
        } catch let failure as HandlerFailure {
            return (.error(failure.response), nil)
        } catch let error as NodeError {
            return (.error(.nodeError(description: "\(error)")), nil)
        } catch let error as any UnrecoverableError {
            // The machine, not the request, is broken. The handler runs first — under the
            // default handler it stops the process, as it does anywhere else — and a server
            // that installs its own handler gets to answer the client before it exits.
            FatalErrors.handler(error)
            return (.error(.unrecoverable(message: "\(error)")), nil)
        } catch {
            return (.error(.nodeError(description: error.localizedDescription)), nil)
        }
    }

    // MARK: - Engine verbs

    /// Every failure the graph is holding, cascades folded onto their causes and ordered —
    /// all of it decided by `ErrorReport`, which the idle-time event goes through too, so
    /// the reply and the event list the same failures the same way. The selection is the
    /// only difference: this verb is asked for everything, where the event reports what is
    /// newly appearing.
    private func errorRecords() throws -> [ErrorRecord] {
        ErrorReport.entries(forErrorPorts: try database.outputPort.selectAllErrors(),
                            database: database,
                            select: { _, messages in messages })
            .map { ErrorRecord($0.entry) }
    }

    /// The installed tools per namespace, unrendered; the client prints them as config
    /// text. A namespace whose tool is missing has no descriptors, which the client
    /// prints as a comment. Both sources are dictionaries, so the order is imposed here.
    private func toolNamespaces() -> [ToolNamespaceRecord] {
        let installed = ToolRunnerRegistry.instance.registeredDescriptors

        return ToolNamespaceRegistry.all.map { entry in
            let machineSettings = entry.machineSettings()
            let descriptors = installed
                .filter { $0.name == entry.toolName }
                .sorted { ($0.version, $0.platform, $0.architecture) < ($1.version, $1.platform, $1.architecture) }
                .map { descriptor in
                    ToolDescriptorRecord(name:            descriptor.name,
                                         version:         descriptor.version,
                                         platform:        descriptor.platform,
                                         architecture:    descriptor.architecture,
                                         machineSettings: machineSettings)
                }
            return ToolNamespaceRecord(namespace: entry.namespace, toolName: entry.toolName, descriptors: descriptors)
        }
    }

    // MARK: - Events

    /// The engine's reports become events. The closures capture the handler weakly so an
    /// engine outliving its handler (tests swap handlers) does not keep it alive.
    private func installReporters() {
        engine.errorReporter = { [weak self] entries in
            self?.eventSink?.deliver(.daemon(.errors(records: entries.map(ErrorRecord.init))))
        }
        engine.noticeReporter = { [weak self] line in
            self?.eventSink?.deliver(.daemon(.notice(line: line)))
        }
    }

    // MARK: - Shared helpers for the file verbs

    /// The root folder of one of the two virtual file systems.
    func rootFolder(_ fileSystem: FileSystemKind) throws -> NodeRecord {
        switch fileSystem {
        case .input:  return try engine.inputFileSystem
        case .output: return try engine.outputFileSystem
        }
    }
}

/// A failure the handler can name precisely, thrown from a verb and turned into the
/// matching `ErrorResponse` by the dispatcher.
enum HandlerFailure: Error {
    case pathNotFound(path: String)
    case notAFolder(path: String)
    case node(description: String)

    var response: ErrorResponse {
        switch self {
        case .pathNotFound(let path):     return .pathNotFound(path: path)
        case .notAFolder(let path):       return .notAFolder(path: path)
        case .node(let description):      return .nodeError(description: description)
        }
    }
}

extension ErrorRecord {

    /// The wire form of an engine entry. Mirrored rather than shared, because the
    /// protocol package must not import the engine.
    init(_ entry: ErrorReport.Entry) {
        self.init(label:   entry.label,
                  entries: entry.items.map { ErrorEntry(ports: $0.ports, message: $0.message) },
                  downstreamCarrierCount: entry.downstreamCarrierCount)
    }
}
