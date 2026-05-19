import Foundation
import GRDB

public struct NodeOutputValue: Codable, FetchableRecord, PersistableRecord {
    public enum Columns {
        public static let nodeID = Column(CodingKeys.nodeID)
        public static let port = Column(CodingKeys.port)
        public static let kind = Column(CodingKeys.kind)
        public static let dataObjectHash = Column(CodingKeys.dataObjectHash)
        public static let metadata = Column(CodingKeys.metadata)
        public static let lengthIfStream = Column(CodingKeys.lengthIfStream)
    }

    public enum ValueKind: UInt8, Codable {
        case value = 1
        case pending = 2
        case error = 5
    }

    public var nodeID: ObjectID
    public var port: UInt8
    public var kind: ValueKind
    public var dataObjectHash: DataObjectHash?
    public var metadata: String?
    public var lengthIfStream: Int?

    public init(nodeID: ObjectID, port: UInt8, kind: ValueKind, dataObjectHash: DataObjectHash?, metadata: String?, lengthIfStream: Int? = nil) {
        self.nodeID = nodeID
        self.port = port
        self.kind = kind
        self.dataObjectHash = dataObjectHash
        self.metadata = metadata
        self.lengthIfStream = lengthIfStream
    }

    // NodeOutputValue uses a natural key instead of the usual "id" surrogate key.
    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "NodeOutputValue", options: .ifNotExists) { t in
                t.column("nodeID", .integer).notNull().indexed()
                t.column("port", .integer).notNull()
                t.column("kind", .integer).notNull()
                t.column("dataObjectHash", .text) // nullable
                t.column("metadata", .text) // nullable
                t.column("lengthIfStream", .integer)
                t.primaryKey(["nodeID", "port"])
            }
        }
    }
}

extension NodeOutputValue {

    public enum StreamError: Error {
        /// The stream file does not exist on disk but is expected to.
        case streamFileNotFound(String)
        /// The on-disk file is shorter than `lengthIfStream` — the file is corrupt / missing bytes.
        case streamFileShorterThanExpected(onDisk: Int, expected: Int)
        /// The caller requested a byte range that exceeds the recorded stream length.
        case readOutOfBounds(offset: UInt64, length: UInt64, streamLength: Int)
        /// A low-level I/O error (wraps the underlying error).
        case ioError(Error)
    }

    // MARK: - Stream file location

    /// Root directory where all stream files are stored.
    /// Uses the app's Application Support directory so files survive across runs.
    private static var streamsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("build_system/streams", isDirectory: true)
    }

    private static func urlForStream(nodeID: ObjectID, port: UInt8) -> URL {
        let filename = "\(nodeID)-\(port).stream"
        return streamsDirectory.appendingPathComponent(filename)
    }

    // MARK: - Append

    /// Appends `data` to this output value's stream file, then increments `lengthIfStream`.
    ///
    /// `lengthIfStream` is the source-of-truth for the logical end of the stream.
    /// If the on-disk file is *longer* than `lengthIfStream` (e.g. a previous write was not
    /// committed to the DB), the file is first truncated to `lengthIfStream` before appending.
    /// If the on-disk file is *shorter* than `lengthIfStream`, the data is corrupt and an error
    /// is thrown.
    public mutating func appendBytesToStream(data: Data) throws {
        let fileURL = Self.urlForStream(nodeID: nodeID, port: port)
        let fileManager = FileManager.default

        // Ensure the streams directory exists.
        try fileManager.createDirectory(at: Self.streamsDirectory,
                                        withIntermediateDirectories: true)

        let expectedLength = lengthIfStream ?? 0

        if fileManager.fileExists(atPath: fileURL.path) {
            // Reconcile on-disk length with the DB-recorded length.
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            let onDiskLength = (attributes[.size] as? Int) ?? 0

            if onDiskLength > expectedLength {
                // A previous un-committed write left extra bytes — truncate back to the
                // DB-recorded length before appending.
                let fileHandle = try FileHandle(forWritingTo: fileURL)
                defer { try? fileHandle.close() }
                try fileHandle.truncate(atOffset: UInt64(expectedLength))
            } else if onDiskLength < expectedLength {
                throw StreamError.streamFileShorterThanExpected(onDisk: onDiskLength,
                                                                expected: expectedLength)
            }
            // onDiskLength == expectedLength: nothing to reconcile, fall through to append.

            let fileHandle = try FileHandle(forWritingTo: fileURL)
            defer { try? fileHandle.close() }
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)

        } else {
            // No file exists yet — only valid if the recorded length is also zero.
            if expectedLength > 0 {
                throw StreamError.streamFileShorterThanExpected(onDisk: 0,
                                                                expected: expectedLength)
            }
            // Create the file with the initial data.
            try data.write(to: fileURL, options: .atomic)
        }

        lengthIfStream = expectedLength + data.count
    }

    // MARK: - Read

    /// Reads `length` bytes starting at `offset` from this output value's stream file.
    ///
    /// - Throws: `StreamError.streamFileNotFound` if the file does not exist.
    /// - Throws: `StreamError.readOutOfBounds` if `offset + length` exceeds `lengthIfStream`.
    public func readBytesFromStream(offset: UInt64, length: UInt64) throws -> Data {
        let fileURL = Self.urlForStream(nodeID: nodeID, port: port)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw StreamError.streamFileNotFound(fileURL.path)
        }

        let recordedLength = lengthIfStream ?? 0

        guard offset + length <= UInt64(recordedLength) else {
            throw StreamError.readOutOfBounds(offset: offset,
                                              length: length,
                                              streamLength: recordedLength)
        }

        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: offset)
        guard let data = try fileHandle.read(upToCount: Int(length)) else {
            return Data()
        }
        return data
    }
}

extension DatabaseLayer {

    public func selectAllNodeOutputValues(limit: Int) throws -> [NodeOutputValue] {
        try dbQueue.read { db in
            try NodeOutputValue
                .limit(limit)
                .order(Column("nodeID").asc)
                .fetchAll(db)
        }
    }

    // Select all NodeOutputValues associated with the given Node
    public func selectAllNodeOutputValues(nodeID: ObjectID) throws -> [NodeOutputValue] {
        try dbQueue.read { db in
            try NodeOutputValue.filter(NodeOutputValue.Columns.nodeID == nodeID).fetchAll(db)
        }
    }

    public func selectNodeOutputValue(nodeID: ObjectID, port: UInt8) throws -> NodeOutputValue? {
        try dbQueue.read { db in
            try NodeOutputValue.filter(NodeOutputValue.Columns.nodeID == nodeID &&
                                       NodeOutputValue.Columns.port == port).fetchOne(db)
        }
    }

    public func insertOrReplaceNodeOutputValue(_ nodeOutputValue: NodeOutputValue) throws {
        try dbQueue.write { db in
            try nodeOutputValue.save(db)
        }
    }

    public func deleteNodeOutputValue(nodeID: ObjectID, port: UInt8) throws -> Bool {
        try dbQueue.write { db in
            try NodeOutputValue
                .filter(NodeOutputValue.Columns.nodeID == nodeID && NodeOutputValue.Columns.port == port)
                .deleteAll(db) > 0
        }
    }
}

public extension NodeOutputValue {
    func description() -> String {
        "NodeOutputValue: nodeID=\(nodeID), port=\(port), dataObjectHash=\(String(describing: dataObjectHash))"
    }
}
