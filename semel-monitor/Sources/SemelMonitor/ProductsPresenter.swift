// ProductsPresenter.swift
// SemelMonitor
//
// The products window's life, apart from its pixels: opened for a card or for *Products…*,
// read from the engine off the main queue, read again after every settle while it is open,
// and the person's selection and export applied to its model. The window and `--print`
// are the two front ends of one presenter, as they are of one `Monitor`.

import Foundation
import SemelCLI
import SemelProtocol
import SemelTransport

/// Where the window reads `output:` and writes an export: the engine, through the prompt's
/// own code.
public protocol ProductsSource: AnyObject {
    func snapshot() throws -> ProductsSnapshot
    func export(_ request: ExportRequest, into destination: String) throws -> ExportResult
}

/// What an export came to: how many files were written, nil when there was nothing to
/// export, and the lines `export` printed on the way, which say what went wrong.
public struct ExportResult: Equatable, Sendable {
    public let written: Int?
    public let messages: [String]

    public init(written: Int?, messages: [String]) {
        self.written  = written
        self.messages = messages
    }
}

/// The engine as a `ProductsSource`: a connection of its own beside the subscription — a
/// subscriber's connection carries events, and this one carries requests and their replies —
/// with a `CommandInterpreter` on it, so the listing and the export are the prompt's. Opened
/// when first needed and again after it drops. Not thread-safe: the presenter calls it on
/// one queue.
public final class EngineProducts: ProductsSource {

    private let socketPath: String
    private var connection: SocketConnection?
    private var interpreter: CommandInterpreter?
    private var printed: [String] = []

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func snapshot() throws -> ProductsSnapshot {
        try usingSession { try ProductsSnapshot.read(through: $0) }
    }

    public func export(_ request: ExportRequest, into destination: String) throws -> ExportResult {
        try usingSession { interpreter in
            printed = []
            let written = try interpreter.export(folder: request.folder, selecting: request.selection, into: destination)
            return ExportResult(written: written, messages: printed)
        }
    }

    private func usingSession<Answer>(_ body: (CommandInterpreter) throws -> Answer) throws -> Answer {
        do {
            return try body(try session())
        } catch {
            connection?.close()
            connection  = nil
            interpreter = nil
            throw error
        }
    }

    private func session() throws -> CommandInterpreter {
        if let interpreter, connection?.isOpen == true {
            return interpreter
        }
        connection?.close()
        let connection  = try SocketConnection.connect(to: socketPath)
        let interpreter = CommandInterpreter(connection: connection, baseDirectory: NSHomeDirectory())
        interpreter.output = { [weak self] line in self?.printed.append(line) }
        self.connection = connection
        _ = try interpreter.connect(subscribing: false)
        self.interpreter = interpreter
        return interpreter
    }
}

public final class ProductsPresenter {

    public enum Display: Equatable, Sendable {
        case closed
        /// Opened, and the first reading not back yet.
        case loading
        case shown(ProductsWindowModel)
        /// The engine could not be read: there is none, or it went.
        case failed(String)
    }

    public private(set) var display = Display.closed

    /// The card the window was opened for, nil for *Products…*.
    public private(set) var openedFor: Card?

    /// Every new display, on the main queue; `isOpening` for the first after an open, which
    /// is what `--print` writes.
    public var onDisplay: (_ display: Display, _ isOpening: Bool) -> Void = { _, _ in }

    private let source: any ProductsSource
    private let queue = DispatchQueue(label: "semel-monitor.products")

    /// The card whose settle the marks are for, as of the latest request.
    private var marks: Card?
    private var isReading = false
    private var readsAgain = false
    private var announcesNext = false
    /// Moves on every open and close, so a reading begun for an earlier window is dropped.
    private var generation = 0

    public init(source: any ProductsSource) {
        self.source = source
    }

    /// Opens the window for `card` — a click's, or nil for *Products…* — its marks those of
    /// `marks`, the settle the person was last told of. Call on the main queue.
    public func open(for card: Card?, marks: Card?) {
        generation   += 1
        openedFor     = card
        self.marks    = card ?? marks
        display       = .loading
        announcesNext = true
        isReading     = false
        readsAgain    = false
        onDisplay(.loading, false)
        read()
    }

    /// A settle ended: an open window reads `output:` again, marked for `marks`, the newest
    /// card.
    public func settleEnded(marks newMarks: Card?) {
        guard display != .closed else {
            return
        }
        marks = newMarks
        read()
    }

    public func close() {
        generation += 1
        display     = .closed
        openedFor   = nil
    }

    public func select(_ section: ProductsSection) {
        update { $0.select(section) }
    }

    public func selectRows(_ paths: Set<String>) {
        update { $0.selectRows(paths) }
    }

    /// Writes the window's export into `destination`, off the main queue, and answers on it.
    public func export(_ request: ExportRequest, into destination: String,
                       completion: @escaping (Result<ExportResult, Error>) -> Void) {
        queue.async { [source] in
            let result = Result { try source.export(request, into: destination) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Reading

    /// One reading at a time; a settle during one asks for one more after it, and the
    /// readings between collapse into that one.
    private func read() {
        guard !isReading else {
            readsAgain = true
            return
        }
        isReading = true
        let generation = generation
        queue.async { [source] in
            let result = Result { try source.snapshot() }
            DispatchQueue.main.async { [weak self] in self?.finishReading(result, generation: generation) }
        }
    }

    private func finishReading(_ result: Result<ProductsSnapshot, Error>, generation readFor: Int) {
        guard readFor == generation else {
            return
        }
        isReading = false
        switch result {
        case .success(let snapshot):
            if case .shown(var model) = display {
                model.refresh(with: snapshot, card: marks)
                display = .shown(model)
            } else {
                display = .shown(ProductsWindowModel(snapshot: snapshot, card: marks))
            }
        case .failure(let error):
            display = .failed(Self.reason(for: error))
        }
        let isOpening = announcesNext
        announcesNext = false
        onDisplay(display, isOpening)
        if readsAgain {
            readsAgain = false
            read()
        }
    }

    private func update(_ change: (inout ProductsWindowModel) -> Void) {
        guard case .shown(var model) = display else {
            return
        }
        change(&model)
        display = .shown(model)
        onDisplay(display, false)
    }

    /// No engine is the common case — the window opened with none, or it stopped — and is
    /// said as the status item says it.
    static func reason(for error: Error) -> String {
        switch error {
        case ConnectionError.unavailable, ConnectionError.closed, TransportError.closed:
            return "No engine"
        default:
            return "\(error)"
        }
    }
}
