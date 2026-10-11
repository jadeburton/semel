//
//  NibArchive.swift
//  SemelApple
//
//  The binary form ibtool compiles a xib or a storyboard's scenes to, read and written
//  back: what `NibCanonicaliser` puts in canonical form (B-154).
//
//  A NIBArchive is the magic `NIBArchive`, ten little-endian 32-bit words — two versions,
//  then a count and an offset for each of four tables — and the tables: objects (a class
//  index, the index of the object's first value and its count), keys (names), values (a
//  key index, a type and the value's bytes) and class names (a name, NUL-terminated as
//  written, and the indices of the classes to fall back on). Counts and lengths are
//  variable-length integers, seven bits a byte, least significant first, the last byte
//  marked by its high bit. An object refers to another by its index, a value of type 10.
//

import Foundation
import SemelNodeKit

struct NibArchive: Equatable {

    static let magic = Array("NIBArchive".utf8)

    /// A value's type, as the archive numbers them.
    enum ValueType: UInt8 {
        case int8 = 0, int16 = 1, int32 = 2, int64 = 3, isTrue = 4, isFalse = 5, float = 6, double = 7
        case data = 8, isNil = 9, object = 10

        /// The bytes a value of this type holds after its type, nil for one whose length
        /// precedes it.
        var fixedLength: Int? {
            switch self {
            case .int8:                     return 1
            case .int16:                    return 2
            case .int32, .float, .object:   return 4
            case .int64, .double:           return 8
            case .isTrue, .isFalse, .isNil: return 0
            case .data:                     return nil
            }
        }
    }

    struct Value: Equatable {
        var key: Int
        var type: ValueType
        var payload: [UInt8]

        /// The object a reference names, nil for any other value.
        var reference: Int? {
            guard type == .object, payload.count == 4 else {
                return nil
            }
            return Int(UInt32(payload[0]) | UInt32(payload[1]) << 8 | UInt32(payload[2]) << 16 | UInt32(payload[3]) << 24)
        }

        static func referring(to object: Int, key: Int) -> Value {
            Value(key: key, type: .object, payload: NibArchive.littleEndian(UInt32(object)))
        }
    }

    struct Object: Equatable {
        var classIndex: Int
        var fields: [Value]
    }

    struct ClassName: Equatable {
        /// As written, with its terminating NUL.
        var name: [UInt8]
        var fallbacks: [Int]

        /// The name without the NUL the archive writes after it.
        var text: String {
            String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    var formatVersion: UInt32
    var coderVersion: UInt32
    var objects: [Object]
    var keyTable: [[UInt8]]
    var classes: [ClassName]

    init(formatVersion: UInt32, coderVersion: UInt32, objects: [Object], keyTable: [[UInt8]], classes: [ClassName]) {
        self.formatVersion = formatVersion
        self.coderVersion  = coderVersion
        self.objects       = objects
        self.keyTable      = keyTable
        self.classes       = classes
    }

    /// Whether `bytes` begin as a NIBArchive does.
    static func isArchive(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: magic)
    }

    // MARK: - Reading

    init(bytes: [UInt8]) throws {
        guard Self.isArchive(bytes), bytes.count >= 50 else {
            throw NibProblem.notANibArchive
        }
        var reader = Reader(bytes: bytes, position: Self.magic.count)
        let header = try (0..<10).map { _ in try reader.word() }
        formatVersion = header[0]
        coderVersion  = header[1]
        let (objectCount, objectOffset) = (Int(header[2]), Int(header[3]))
        let (keyCount, keyOffset)       = (Int(header[4]), Int(header[5]))
        let (valueCount, valueOffset)   = (Int(header[6]), Int(header[7]))
        let (classCount, classOffset)   = (Int(header[8]), Int(header[9]))

        reader.position = objectOffset
        var ranges: [(classIndex: Int, first: Int, count: Int)] = []
        for _ in 0..<objectCount {
            ranges.append((try reader.varint(), try reader.varint(), try reader.varint()))
        }
        reader.position = keyOffset
        var keys: [[UInt8]] = []
        for _ in 0..<keyCount {
            keys.append(try reader.bytes(count: try reader.varint()))
        }
        reader.position = valueOffset
        var values: [Value] = []
        for _ in 0..<valueCount {
            let key = try reader.varint()
            let rawType = try reader.byte()
            guard let type = ValueType(rawValue: rawType) else {
                throw NibProblem.unknownValueType(type: Int(rawType), offset: reader.position - 1)
            }
            let length = try type.fixedLength ?? reader.varint()
            values.append(Value(key: key, type: type, payload: try reader.bytes(count: length)))
        }
        reader.position = classOffset
        var classes: [ClassName] = []
        for _ in 0..<classCount {
            let length = try reader.varint()
            let fallbackCount = try reader.varint()
            let fallbacks = try (0..<fallbackCount).map { _ in Int(try reader.word()) }
            classes.append(ClassName(name: try reader.bytes(count: length), fallbacks: fallbacks))
        }

        var objects: [Object] = []
        for range in ranges {
            guard range.classIndex < classes.count, range.first >= 0, range.first + range.count <= values.count else {
                throw NibProblem.indexOutOfRange
            }
            objects.append(Object(classIndex: range.classIndex, fields: Array(values[range.first..<(range.first + range.count)])))
        }
        for object in objects {
            for value in object.fields {
                guard value.key < keys.count, (value.reference ?? 0) < objects.count else {
                    throw NibProblem.indexOutOfRange
                }
            }
        }
        self.objects = objects
        self.keyTable = keys
        self.classes = classes
    }

    // MARK: - Writing

    /// The archive's bytes, its tables in the order objects, keys, values, classes, each
    /// object's values together and in object order.
    func bytes() -> [UInt8] {
        var objectTable: [UInt8] = []
        var keyBytes: [UInt8] = []
        var valueTable: [UInt8] = []
        var classTable: [UInt8] = []
        var valueCount = 0
        for object in objects {
            objectTable += Self.varint(object.classIndex) + Self.varint(valueCount) + Self.varint(object.fields.count)
            for value in object.fields {
                valueTable += Self.varint(value.key) + [value.type.rawValue]
                if value.type.fixedLength == nil {
                    valueTable += Self.varint(value.payload.count)
                }
                valueTable += value.payload
            }
            valueCount += object.fields.count
        }
        for key in keyTable {
            keyBytes += Self.varint(key.count) + key
        }
        for className in classes {
            classTable += Self.varint(className.name.count) + Self.varint(className.fallbacks.count)
            classTable += className.fallbacks.flatMap { Self.littleEndian(UInt32($0)) }
            classTable += className.name
        }
        let objectOffset = Self.magic.count + 40
        let keyOffset    = objectOffset + objectTable.count
        let valueOffset  = keyOffset + keyBytes.count
        let classOffset  = valueOffset + valueTable.count
        let header = [formatVersion, coderVersion,
                      UInt32(objects.count), UInt32(objectOffset), UInt32(keyTable.count), UInt32(keyOffset),
                      UInt32(valueCount), UInt32(valueOffset), UInt32(classes.count), UInt32(classOffset)]
        return Self.magic + header.flatMap(Self.littleEndian) + objectTable + keyBytes + valueTable + classTable
    }

    static func varint(_ number: Int) -> [UInt8] {
        var remaining = number
        var encoded: [UInt8] = []
        while true {
            let low = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining == 0 {
                encoded.append(low | 0x80)
                return encoded
            }
            encoded.append(low)
        }
    }

    static func littleEndian(_ word: UInt32) -> [UInt8] {
        [UInt8(word & 0xff), UInt8(word >> 8 & 0xff), UInt8(word >> 16 & 0xff), UInt8(word >> 24 & 0xff)]
    }

    // MARK: - A cursor over the bytes

    private struct Reader {
        let bytes: [UInt8]
        var position: Int

        mutating func byte() throws -> UInt8 {
            guard position < bytes.count else {
                throw NibProblem.truncated(offset: position)
            }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func bytes(count: Int) throws -> [UInt8] {
            guard count >= 0, position + count <= bytes.count else {
                throw NibProblem.truncated(offset: position)
            }
            defer { position += count }
            return Array(bytes[position..<(position + count)])
        }

        mutating func word() throws -> UInt32 {
            try bytes(count: 4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }

        mutating func varint() throws -> Int {
            var result = 0
            var shift = 0
            while true {
                let next = try byte()
                guard shift < 56 else {
                    throw NibProblem.truncated(offset: position)
                }
                result |= Int(next & 0x7f) << shift
                shift += 7
                if next & 0x80 != 0 {
                    return result
                }
            }
        }
    }
}
