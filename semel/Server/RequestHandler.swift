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
        // A batch left open by the process before this one can no longer be committed or
        // refused; what it pushed stands, as it did before batches had journals.
        FatalErrors.attempt { try BatchJournal.discardAll() }
    }

    // MARK: - Entry point

    /// Answers one request. A reply that streams (`list`, `remove`, `errors`) sends its
    /// parts through `replyStream` as it goes, and what is returned is its last.
    public func handle(_ request: Request, body: Data?, session: Session,
                       replyStream: any ReplyStream) -> (Response, Data?) {
        handle(prepare(request, body: body), session: session, replyStream: replyStream)
    }

    /// The part of answering a request that reads no row, done before the request takes
    /// the queue: a push's bytes are hashed and stored here, on the caller's thread and
    /// every core, and the queue is handed the hashes. On the queue that would be a tenth
    /// of what a cold push of a tree costs the one queue every client takes turns on; off
    /// it, a connection prepares its next request while the queue records the one before
    /// (`ServerConnection`).
    func prepare(_ request: Request, body: Data?) -> PreparedRequest {
        switch request {
        case .daemon(.pushFiles(let headers)):
            return PreparedRequest(request: request, body: nil,
                                   interned: Result { try interned(headers, body: body ?? Data()) })
        case .daemon(.pushFile(let path, let mode)):
            let header = PushedFileHeader(path: path, mode: mode, length: body?.count ?? 0)
            return PreparedRequest(request: request, body: nil,
                                   interned: Result { try interned([header], body: body ?? Data()) })
        default:
            return PreparedRequest(request: request, body: body, interned: nil)
        }
    }

    /// Answers a request `prepare` has prepared.
    func handle(_ prepared: PreparedRequest, session: Session, replyStream: any ReplyStream) -> (Response, Data?) {
        let request = prepared.request
        let body    = prepared.body

        // A wait observes; it does not mutate. Off the queue so a client waiting for the
        // graph to settle does not hold every other client's commands behind it.
        // It parks the caller's thread, which must therefore not be one of the cooperative pool's — the engine's loop runs there and would have nothing left to settle on.
        if case .daemon(.wait) = request {
            engine.waitUntilIdleBlocking()
            return (.daemon(.ok), nil)
        }

        switch (request, prepared.interned) {
        case (.daemon(.pushFiles), let interned?):
            return pushFiles(interned, session: session)
        case (.daemon(.pushFile(let path, _)), let interned?):
            return pushFile(interned, path: path, session: session)
        default:
            break
        }

        return queue.sync { () -> (Response, Data?) in
            switch request {
            case .hello(let hello):
                return (.hello(answer(hello)), nil)
            case .daemon(let daemonRequest):
                return handleDaemon(daemonRequest, body: body, session: session, replyStream: replyStream)
            }
        }
    }

    /// Commits whatever batch the session left open, so a client that vanished mid-push
    /// cannot leave the engine's work signals suppressed. Committed as a `commit` would be,
    /// through the lock barrier: a batch the barrier refuses is taken back, and with nobody
    /// left to tell, the log says so.
    public func endSession(_ session: Session) {
        queue.sync {
            while session.openBatchDepth > 0 {
                do {
                    try closeBatch(session)
                } catch {
                    Debug.warn("the batch a closed connection left open was not committed: \(error)")
                }
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

    private func handleDaemon(_ request: DaemonRequest, body: Data?, session: Session,
                              replyStream: any ReplyStream) -> (Response, Data?) {
        answering {
            switch request {
            case .list(let fileSystem, let pattern):
                return (.daemon(try list(fileSystem: fileSystem, pattern: pattern, replyStream: replyStream)), nil)
            case .beginBatch:
                try openBatch(session)
                return (.daemon(.ok), nil)
            case .endBatch:
                try closeBatch(session)
                return (.daemon(.ok), nil)
            case .pushFile, .pushFiles:
                // Answered in `handle`, which interns the bytes before the queue. Unreachable
                // here, and the switch wants every case.
                return (.daemon(.ok), nil)
            case .pushSymbolicLink(let path, let target, let referent):
                return (.daemon(try pushSymbolicLink(path: path, target: target, referent: referent, body: body ?? Data(),
                                                     session: session)), nil)
            case .pushFolder(let path):
                return (.daemon(try pushFolder(path: path, session: session)), nil)
            case .contentRoots(let path):
                return (.daemon(.contentRoots), try contentRoots(path: path))
            case .folderChildren(let paths):
                return (.daemon(.folderChildren), try folderChildren(paths: paths))
            case .remove(let pattern):
                return (.daemon(try remove(pattern: pattern, replyStream: replyStream, session: session)), nil)
            case .fetch(let fileSystem, let path):
                let (response, bytes) = try fetch(fileSystem: fileSystem, path: path)
                return (.daemon(response), bytes)
            case .errors(let product):
                // Sliced once the report is whole: `ErrorReport` orders and folds over
                // every failure at once, so there is nothing to send before it is done.
                let slicer = ReplySlicer<ErrorRecord>(verb: "errors", stream: replyStream) { .errors(records: $0) }
                try slicer.append(contentsOf: try errorRecords(stopping: product))
                return (.daemon(slicer.last), nil)
            case .check:
                let report = GraphCheck.run(database: database)
                return (.daemon(.check(scheduledNodes: report.scheduledNodeCount)),
                        try MessageCoder.encode(report.findings.map(CheckFinding.init)))
            case .collect:
                let collection = try engine.collectUnreferencedObjects()
                return (.daemon(.collected(removed: collection.removed, removedBytes: collection.removedBytes,
                                           kept: collection.kept)), nil)
            case .tools(let platformName):
                // A name this server does not know answers as macOS rather than failing:
                // the reply says what is installed either way, and the client validated it.
                let platform = Platform(rawValue: platformName) ?? .macos
                return (.daemon(.tools(namespaces: toolNamespaces(platform: platform))), nil)
            case .reset(let clearCache):
                let archivedGraphPath = try engine.reset(clearCache: clearCache)
                return (.daemon(.reset(archivedGraphPath: archivedGraphPath)), nil)
            case .nudge:
                try engine.nudge()
                return (.daemon(.ok), nil)
            case .wait:
                // Answered in `handle`, before the queue. Unreachable here, and the switch
                // wants every case.
                return (.daemon(.ok), nil)
            case .explain(let fileSystem, let path):
                return (.daemon(.explain(explanation: try explain(fileSystem: fileSystem, path: path))), nil)
            case .debug(let cacheKey):
                guard let cacheKey else {
                    return (.daemon(.debug), Data(try engine.graphDescription().utf8))
                }
                return (.daemon(.debug), Data(engine.cacheEntryDescription(key: cacheKey).utf8))
            case .subscribe:
                session.isSubscribed = true
                return (.daemon(.ok), nil)
            // Locked folders and checkpoints (B-146), in RequestHandler+Batches.swift.
            case .checkpoint(let name):
                return (.daemon(try checkpoint(named: name)), nil)
            case .checkpoints:
                return (.daemon(try checkpointList()), nil)
            case .restore(let name):
                return (.daemon(try restore(named: name, session: session)), nil)
            }
        }
    }

    // MARK: - Push

    /// One file: a batch of one, answered as itself.
    private func pushFile(_ interned: Result<[InternedFile], Error>, path: String, session: Session) -> (Response, Data?) {
        answering {
            let files = try interned.get()
            switch try queue.sync(execute: { try pushFiles(files, session: session) }).first {
            case .stored(let didChange):
                return (.daemon(.pushFile(didChange: didChange)), nil)
            case .failed(let error):
                return (.error(error), nil)
            case nil:
                throw HandlerFailure.malformed(description: "\(path) was not recorded")
            }
        }
    }

    /// A batch: every file interned off the queue (`prepare`), then recorded on it in
    /// order, in one turn. A failure to intern is the whole request's — a body the headers
    /// do not cut, or a store that cannot be written — and a failure to record is that
    /// file's alone.
    private func pushFiles(_ interned: Result<[InternedFile], Error>, session: Session) -> (Response, Data?) {
        answering {
            let files = try interned.get()
            return (.daemon(.pushFiles(outcomes: try queue.sync(execute: { try pushFiles(files, session: session) }))), nil)
        }
    }

    /// `PushInterner.intern`, with a body the headers do not account for answered as the
    /// malformed request it is rather than as a node's failure.
    private func interned(_ headers: [PushedFileHeader], body: Data) throws -> [InternedFile] {
        do {
            return try PushInterner.intern(headers, body: body)
        } catch let failure as PushedFilesError {
            throw HandlerFailure.malformed(description: failure.description)
        }
    }

    // MARK: - Answering

    /// Runs `work` and turns what it throws into the reply that says so.
    private func answering(_ work: () throws -> (Response, Data?)) -> (Response, Data?) {
        do {
            return try work()
        } catch {
            return (.error(Self.errorResponse(for: error)), nil)
        }
    }

    /// The reply to a failure, by what kind of failure it is.
    static func errorResponse(for error: Error) -> ErrorResponse {
        switch error {
        case let failure as HandlerFailure:
            return failure.response
        case let error as CheckpointError:
            return checkpointResponse(for: error)
        case let error as NodeError:
            return .nodeError(description: "\(error)")
        case let error as any UnrecoverableError:
            // The machine, not the request, is broken. The handler runs first — under the
            // default handler it stops the process, as it does anywhere else — and a server
            // that installs its own handler gets to answer the client before it exits.
            FatalErrors.handler(error)
            return .unrecoverable(message: "\(error)")
        default:
            // Interpolated, as the client prints its own errors: `localizedDescription` of a
            // Swift error that is not a `LocalizedError` is "The operation couldn't be
            // completed", a type name and a case number.
            return .nodeError(description: "\(error)")
        }
    }

    // MARK: - Engine verbs

    /// Every failure the graph is holding, cascades folded onto their causes and ordered —
    /// all of it decided by `ErrorReport`, which the idle-time event goes through too, so
    /// the reply and the event list the same failures the same way. The selection is the
    /// only difference: this verb is asked for everything, where the event reports what is
    /// newly appearing.
    ///
    /// Each record names the products downstream of its nodes, through one walk for the
    /// whole answer (B-142). With `product` — a path relative to the output root — only the
    /// records stopping it are answered: the product itself, or for a tree product's folder
    /// any entry below it. The walk still starts from every failure, since which of them
    /// reach the product is what it finds out, but what is sent is what was asked for.
    private func errorRecords(stopping product: String?) throws -> [ErrorRecord] {
        let asked = product.map { (Path(FileSystemName.output) / Path($0)).string }
        if let asked, !(try ProductReach.isProduct(asked, database: database)) {
            throw HandlerFailure.notAProduct(path: asked)
        }

        let reported = ErrorReport.entries(forErrorPorts: try ErrorReport.portsToReport(database: database),
                                           database: database,
                                           select: { _, messages in messages })
        var reach = ProductReach(database: database)
        return ErrorReport.namingProducts(of: reported, reach: &reach)
            .map(\.entry)
            .filter { entry in asked.map { asked in entry.products.contains { $0.isNamed(by: asked) } } ?? true }
            .map(ErrorRecord.init)
    }

    /// Why the last settle did what it did to the node at `path` (B-91). A path with no node
    /// is an error naming it, whether or not anything has settled; a node with no settle
    /// behind it — nothing has done work since this server started — answers nil, which
    /// the client says in words rather than as a node nothing touched.
    private func explain(fileSystem: FileSystemKind, path: String) throws -> Explanation? {
        guard let nodeRecord = try rootFolder(fileSystem).childNode(path: Path(path)) else {
            let rootName = fileSystem == .input ? FileSystemName.input : FileSystemName.output
            throw HandlerFailure.pathNotFound(path: "\(rootName)/\(path)")
        }
        return engine.explain(nodeID: try nodeRecord.requireID()).map(Explanation.init)
    }

    /// The installed tools per namespace, unrendered; the client prints them as config
    /// text. A namespace whose tool is missing has no descriptors, which the client
    /// prints as a comment. Both sources are dictionaries, so the order is imposed here.
    private func toolNamespaces(platform: Platform) -> [ToolNamespaceRecord] {
        let installed = ToolRunnerRegistry.instance.registeredDescriptors

        // What the graph reads: the prefix of every resident ConfigFilter. A listing is
        // best effort, so a database that cannot answer leaves nothing selected.
        let selectedPrefixes = Set(((try? database.node.select(kind: ConfigFilter.kind)) ?? [])
            .compactMap { $0.properties[ConfigFilter.prefixProperty] })

        return ToolNamespaceRegistry.all.map { entry in
            let machineSettings = entry.machineSettings(platform)
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
            return ToolNamespaceRecord(namespace: entry.namespace, toolName: entry.toolName, descriptors: descriptors,
                                       selected: selectedPrefixes.contains(entry.namespace))
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
        // After the error reporter in the engine's own order, so a subscriber reads the
        // failures and then the line that counts them.
        engine.settleReporter = { [weak self] summary in
            self?.eventSink?.deliver(.daemon(.settled(scheduled: summary.scheduled,
                                                      computed:  summary.computed,
                                                      fromCache: summary.fromCache,
                                                      errors:    summary.errors)))
        }
        // Last in that same order: what the settle produced is read under the summary of
        // what the settle did.
        engine.artifactReporter = { [weak self] changes in
            self?.eventSink?.deliver(.daemon(.artifacts(appeared:    changes.appeared,
                                                        changed:     changes.changed,
                                                        disappeared: changes.disappeared)))
        }
        // Between the two, as often as the pass changes state (B-95).
        engine.progressReporter = { [weak self] report in
            let running = report.running.map { ActiveNode(type: $0.typeName, name: $0.name) }
            self?.eventSink?.deliver(.daemon(.progress(record: ProgressRecord(scheduled: report.scheduled,
                                                                              computed:  report.computed,
                                                                              fromCache: report.fromCache,
                                                                              pending:   report.pending,
                                                                              running:   running))))
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
    case notAProduct(path: String)
    case node(description: String)
    case malformed(description: String)
    /// One item of a streamed reply too large for a frame on its own (`ReplySlicer`).
    case replyTooLarge(request: String, bytes: Int)
    /// The lock barrier refused the batch at its outermost `commit` (B-146).
    case batchRejected(BatchRejection)

    var response: ErrorResponse {
        switch self {
        case .pathNotFound(let path):     return .pathNotFound(path: path)
        case .notAFolder(let path):       return .notAFolder(path: path)
        case .notAProduct(let path):      return .notAProduct(path: path)
        case .node(let description):      return .nodeError(description: description)
        case .malformed(let description): return .malformedRequest(description: description)
        case .replyTooLarge(let request, let bytes):
            return .replyTooLarge(request: request, bytes: bytes, limit: Int(Frame.maximumJSONLength))
        case .batchRejected(let rejection):
            return .batchRejected(folder:   rejection.folder.string,
                                  lock:     rejection.lock.string,
                                  expected: LockExpectation(rejection.expected),
                                  found:    rejection.found,
                                  paths:    rejection.paths.map(\.string))
        }
    }
}

extension ErrorRecord {

    /// The wire form of an engine entry. Mirrored rather than shared, because the
    /// protocol package must not import the engine.
    init(_ entry: ErrorReport.Entry) {
        self.init(label:   entry.label,
                  entries: entry.items.map {
                      ErrorEntry(ports: $0.ports, message: $0.message, missingSource: $0.missingSource,
                                 writers: $0.writers.map { SourceWriter(command: $0.command, folder: $0.folder) })
                  },
                  downstreamCarrierCount: entry.downstreamCarrierCount,
                  nodeCount: entry.nodeCount,
                  products: entry.products.map { StoppedProduct(path: $0.path, treeFolder: $0.treeFolder) })
    }
}

extension Explanation {

    /// The wire form of the engine's walk, mirrored for the reason `ErrorRecord` is.
    init(_ explanation: SettleExplanation) {
        self.init(nodes: explanation.entries.map { entry in
                      ExplainedNode(label:   entry.label,
                                    outcome: ExplainedNode.Outcome(entry.state),
                                    isNew:   entry.isNew,
                                    causes:  entry.causes.map { cause in
                                        ExplainedCause(port:        cause.port,
                                                       wire:        cause.wire,
                                                       change:      ExplainedCause.Change(cause.change),
                                                       sourceLabel: cause.sourceLabel,
                                                       source:      cause.sourceIndex)
                                    },
                                    unlistedCauses: entry.unlistedCauses)
                  },
                  omittedNodes: explanation.omittedNodes,
                  nodeLimit:    explanation.nodeLimit,
                  depthLimit:   explanation.depthLimit)
    }
}

extension ExplainedNode.Outcome {

    /// Case by case, so a state added to the engine's walk does not compile until the
    /// wire has a name for it.
    init(_ state: SettleExplanation.State) {
        switch state {
        case .computed:  self = .computed
        case .fromCache: self = .fromCache
        case .notRun:    self = .notRun
        case .changed:   self = .changed
        case .untouched: self = .untouched
        }
    }
}

extension ExplainedCause.Change {

    init(_ change: SettleRecord.Change) {
        switch change {
        case .changed:      self = .changed
        case .connected:    self = .connected
        case .disconnected: self = .disconnected
        case .unchanged:    self = .unchanged
        }
    }
}

extension CheckFinding {

    /// The wire form of one of the engine's findings, mirrored for the same reason.
    init(_ finding: GraphCheck.Finding) {
        self.init(kind: Kind(finding.kind), subject: finding.subject, sentence: finding.sentence)
    }
}

extension CheckFinding.Kind {

    /// Case by case, so an invariant added to `GraphCheck` does not compile until the wire
    /// has a name for it.
    init(_ kind: GraphCheck.Kind) {
        switch kind {
        case .danglingWire:          self = .danglingWire
        case .missingOutputPort:     self = .missingOutputPort
        case .staleIdentity:         self = .staleIdentity
        case .unlinkedNodeType:      self = .unlinkedNodeType
        case .productWithNoProducer: self = .productWithNoProducer
        case .missingManifestChild:  self = .missingManifestChild
        case .errorWithoutMessage:   self = .errorWithoutMessage
        case .unreadableCacheKey:    self = .unreadableCacheKey
        case .graphCouldNotBeRead:   self = .graphCouldNotBeRead
        }
    }
}

/// A request with what can be done before it takes the handler's queue already done: for a
/// push, its files hashed and in the object store, or the failure that stopped them.
struct PreparedRequest {
    let request:  Request
    /// Nil for a push, whose bytes are in the store by now.
    let body:     Data?
    /// A push's files, interned; nil for any other request.
    let interned: Result<[InternedFile], Error>?
}
