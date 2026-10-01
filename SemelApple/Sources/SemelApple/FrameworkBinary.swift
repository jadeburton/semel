//
//  FrameworkBinary.swift
//  SemelApple
//
//  What a framework's binary is, read from its first bytes (B-77 item 3, 12). A framework
//  is a folder whatever its binary is, and the folder says nothing about the one thing a
//  bundle has to know: whether the binary is a dynamic library, which the app loads from
//  its `Frameworks` folder at run time and so must embed and sign, or a static archive,
//  which `-framework` links into the executable and which nothing loads afterwards.
//  CodeEditLanguages' `CodeLanguages_Container.framework` is the second: a fat file of two
//  `ar` archives, every grammar compiled in.

import Foundation

enum FrameworkBinary: Equatable {
    /// A Mach-O dynamic library, thin or fat: embedded, and found through the runpath.
    case dynamicLibrary
    /// An `ar` archive, thin or fat, or a relocatable object: linked in, never embedded.
    case staticArchive

    /// Why a binary is neither, by case.
    enum Unrecognised: Error, Equatable, CustomStringConvertible {
        case unreadable
        case unknownMagic(String)
        /// A Mach-O file of a type no framework links as: an executable, a bundle.
        case machOFileType(UInt32)
        /// A fat file whose slices are not all one kind.
        case mixedSlices

        var description: String {
            switch self {
            case .unreadable:
                return "its binary could not be read"
            case .unknownMagic(let magic):
                return "its binary is neither Mach-O nor an archive (it begins \(magic))"
            case .machOFileType(let fileType):
                return "its binary is a Mach-O file of type \(fileType), neither a dynamic library nor an object"
            case .mixedSlices:
                return "its binary is a fat file whose architectures are not all dynamic libraries or all archives"
            }
        }
    }

    static let archiveMagic = Data("!<arch>\n".utf8)

    /// The kind of the binary `read` reads, given an offset and a byte count: the first
    /// bytes, and for a fat file each architecture's first bytes where its header puts
    /// them. Nothing else is read, so a 375 MB archive costs a few reads.
    static func kind(reading read: (_ offset: UInt64, _ count: Int) -> Data?) throws -> FrameworkBinary {
        guard let head = read(0, 4096), head.count >= 8 else {
            throw Unrecognised.unreadable
        }
        switch Self.bigEndian32(head, at: 0) {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            let isWide        = Self.bigEndian32(head, at: 0) == 0xCAFE_BABF
            let architectures = Int(Self.bigEndian32(head, at: 4))
            let entrySize     = isWide ? 32 : 20
            let headerSize    = 8 + architectures * entrySize
            // A fat file holds a handful; a count past this is not a fat header at all.
            let mostArchitectures = 64
            guard architectures > 0, architectures <= mostArchitectures, let header = head.count >= headerSize ? head : read(0, headerSize),
                  header.count >= headerSize else {
                throw Unrecognised.unreadable
            }
            var kinds = Set<FrameworkBinary>()
            for index in 0..<architectures {
                let entry  = 8 + index * entrySize
                let offset = isWide ? Self.bigEndian64(header, at: entry + 8) : UInt64(Self.bigEndian32(header, at: entry + 8))
                guard let slice = read(offset, 16), slice.count >= 8 else {
                    throw Unrecognised.unreadable
                }
                kinds.insert(try thinKind(of: slice))
            }
            guard kinds.count == 1, let kind = kinds.first else {
                throw Unrecognised.mixedSlices
            }
            return kind
        default:
            return try thinKind(of: head)
        }
    }

    /// One architecture's kind, from its first 16 bytes.
    private static func thinKind(of bytes: Data) throws -> FrameworkBinary {
        if bytes.prefix(archiveMagic.count) == archiveMagic {
            return .staticArchive
        }
        let fileTypeOffset = 12
        let fileType: UInt32
        switch Self.bigEndian32(bytes, at: 0) {
        // Written in the host's order, little-endian on every Mac Semel builds for.
        case 0xCFFA_EDFE, 0xCEFA_EDFE:
            guard bytes.count >= fileTypeOffset + 4 else {
                throw Unrecognised.unreadable
            }
            fileType = Self.littleEndian32(bytes, at: fileTypeOffset)
        case 0xFEED_FACF, 0xFEED_FACE:
            guard bytes.count >= fileTypeOffset + 4 else {
                throw Unrecognised.unreadable
            }
            fileType = Self.bigEndian32(bytes, at: fileTypeOffset)
        default:
            throw Unrecognised.unknownMagic(bytes.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        let relocatableObject: UInt32 = 1
        let dynamicLibrary:    UInt32 = 6
        let dynamicStub:       UInt32 = 9
        switch fileType {
        case dynamicLibrary, dynamicStub: return .dynamicLibrary
        case relocatableObject:           return .staticArchive
        default:                          throw Unrecognised.machOFileType(fileType)
        }
    }

    private static func bigEndian32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else {
            return 0
        }
        let start = data.startIndex + offset
        return data[start ..< start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else {
            return 0
        }
        let start = data.startIndex + offset
        return data[start ..< start + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func bigEndian64(_ data: Data, at offset: Int) -> UInt64 {
        guard data.count >= offset + 8 else {
            return 0
        }
        let start = data.startIndex + offset
        return data[start ..< start + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
