//
//  ProductsDirectory.swift
//  SemelTestSupport
//
//  `swift test` builds a package's executables into the same directory as its test
//  bundles, so a test finds a binary by looking beside its own bundle.
//

import Foundation

public enum ProductsDirectory {

    /// The directory holding `bundleURL`'s bundle and the executables built beside it.
    public static func beside(bundleURL: URL) -> URL {
        bundleURL.deletingLastPathComponent()
    }

    /// The executable `name` built beside the bundle at `bundleURL`. Whether it exists is
    /// the caller's question: a test skips when it does not, naming the path.
    public static func executable(named name: String, besideBundleAt bundleURL: URL) -> URL {
        beside(bundleURL: bundleURL).appendingPathComponent(name)
    }
}
