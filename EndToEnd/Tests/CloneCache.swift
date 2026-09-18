//
//  CloneCache.swift
//  SemelEndToEndTests
//

import Foundation

enum CloneCache {
    static func checkout(name: String, url: String, commit: String) throws -> URL {
        throw EndToEndFailure(step: "materialise", message: "external projects are not fetched yet")
    }
}
