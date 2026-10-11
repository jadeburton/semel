// ReplyStream.swift
// SemelServer
//
// The slicer that decides when a part of a reply is due (B-137); where a part goes is the
// transport's `ReplyStream`. Three replies stream — `list`, `remove` and `errors`, the
// ones that carry the graph in their JSON — and the rule on `DaemonResponse` is the
// contract: the same case repeated, every part but the last marked as continuing.

import Foundation
import SemelProtocol
import SemelTransport

/// Fills one streamable reply item by item, and sends what it holds as a part whenever the
/// next item would take the reply over a frame's JSON section, so a reply's size is bounded
/// by nothing while every frame stays under the cap. What it holds when the handler is done
/// is the last slice, returned as the reply: a reply that fits one frame is that frame, as
/// it would be had nothing streamed.
///
/// **Measured, not counted.** Each item is encoded on its own to learn its size. A count of
/// items against a conservative size per item would be cheaper and wrong: an error record's
/// message has no bound, and a path has none the protocol states, so any per-item figure is
/// either too small to be safe or so large that ordinary replies split for nothing. An item
/// encodes to the same bytes alone as inside the array — keys are sorted and nothing depends
/// on context — so the sum of the items, a comma each and the envelope is the frame's JSON.
/// The price is a second pass of the encoder over the reply, small beside the walk of the
/// graph that produced it.
final class ReplySlicer<Item: Encodable> {

    /// Room for everything around the items: the role and case keys, the labels, the
    /// brackets. Under a hundred bytes for each case that streams; a kilobyte so that a
    /// label added later does not need anyone to recount.
    static var envelopeAllowance: Int { 1_024 }

    /// What the items of one part may add up to.
    static var budget: Int { Int(Frame.maximumJSONLength) - envelopeAllowance }

    /// The verb, for the error that names a single item too large for any frame.
    private let verb:         String
    private let stream:       any ReplyStream
    private let makeResponse: ([Item]) -> DaemonResponse

    private var slice:      [Item] = []
    private var sliceBytes = 0

    init(verb: String, stream: any ReplyStream, makeResponse: @escaping ([Item]) -> DaemonResponse) {
        self.verb         = verb
        self.stream       = stream
        self.makeResponse = makeResponse
    }

    /// Takes the next item, sending what came before it as a part when there is no room.
    /// One item too large for a frame on its own cannot be sliced, and is answered as
    /// `replyTooLarge` with the size its one-item reply would have had.
    func append(_ item: Item) throws {
        // The comma that separates it from the item before.
        let itemBytes = try MessageCoder.encode(item).count + 1
        guard itemBytes <= Self.budget else {
            let alone = try MessageCoder.encode(Response.daemon(makeResponse([item]))).count
            throw HandlerFailure.replyTooLarge(request: verb, bytes: alone)
        }
        if sliceBytes + itemBytes > Self.budget {
            try stream.send(part: .daemon(makeResponse(slice)))
            slice.removeAll(keepingCapacity: true)
            sliceBytes = 0
        }
        slice.append(item)
        sliceBytes += itemBytes
    }

    func append<Items: Sequence>(contentsOf items: Items) throws where Items.Element == Item {
        for item in items {
            try append(item)
        }
    }

    /// The last slice, as the reply's last frame. A part goes out only when an item does
    /// not fit beside it, and that item stays, so this is empty only for a reply with none.
    var last: DaemonResponse {
        makeResponse(slice)
    }
}

/// One path `remove` took, as the slicer measures it: the reply carries files and folders
/// in two lists, and one budget covers both, so the item is either and encodes as the path
/// it puts in its list.
enum RemovedPath: Encodable {
    case file(String)
    case folder(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .file(let path), .folder(let path):
            try container.encode(path)
        }
    }

    /// The reply for a slice, each path in its list, in the order they were taken.
    static func response(_ slice: [RemovedPath]) -> DaemonResponse {
        var files:   [String] = []
        var folders: [String] = []
        for removed in slice {
            switch removed {
            case .file(let path):   files.append(path)
            case .folder(let path): folders.append(path)
            }
        }
        return .remove(removedFiles: files, removedFolders: folders)
    }
}
