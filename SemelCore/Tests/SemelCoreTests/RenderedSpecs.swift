//
//  RenderedSpecs.swift
//  SemelCoreTests
//

import SemelNodeKit

extension Dictionary where Key == String, Value == GraphSpecNode {
    /// The trees as the spec text they render to, for assertions written against text.
    var rendered: [String: String] { mapValues { $0.asString(omitOutputPort: false) } }
}
