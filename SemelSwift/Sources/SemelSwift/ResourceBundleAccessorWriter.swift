// ResourceBundleAccessorWriter.swift
// SemelSwift
//
// The resource bundle accessor SwiftPM generates for an Objective-C target with resources
// (B-55 item 8).

import Foundation
import SemelNodeKit
import SemelDatabaseModels

/// `SWIFTPM_MODULE_BUNDLE` for a C-family target with resources and Objective-C sources:
/// `ResourceBundleAccessorWriter(moduleName: 'ObjCKit', bundleName: 'CPackage_ObjCKit')`.
///
/// SwiftPM writes two files into such a target's derived sources: a header declaring
/// `NSBundle* <Module>_SWIFTPM_MODULE_BUNDLE(void)` with the macro calling it, forced into
/// every compile of the target with `-include`, and an Objective-C source defining the
/// function, compiled as one of the target's objects. A target whose code reads its
/// resources through the macro does not compile without them. Only a target compiling
/// Objective-C or Objective-C++ gets them, since the accessor needs Foundation; a C or C++
/// target with resources gets a bundle and no accessor, as under SwiftPM. The converter
/// decides which targets; this node only writes the two files.
///
/// The header is SwiftPM's byte for byte, but for the newline that ends it. The source is
/// not: SwiftPM's looks beside the main bundle's executable and then falls back to the
/// absolute path of its own build folder, which names a machine and a sandbox. This one
/// looks where the Swift accessor `SwiftCompiler` writes looks — beside the main bundle's
/// executable, in its `Contents/Resources`, beside the code of the target — keeps what it
/// found, and raises naming the bundle when it finds none, as the Swift accessor stops.
///
/// Like `ModuleMapWriter`, a source: no input ports, published when created and never
/// again, since the properties are its identity.
struct ResourceBundleAccessorWriter: Node {
    public static let kind: UInt = 47

    /// `resource_bundle_accessor.h`, the file forced into every compile of the target.
    static let headerPort = "header"
    /// `resource_bundle_accessor.m`, compiled as one of the target's objects.
    static let sourcePort = "source"

    /// The target's c99 name, which prefixes the accessor function: `ObjCKit`.
    static let moduleNameProperty = "moduleName"
    /// The bundle's name without its extension, `<Package>_<Target>`
    /// (`FormulaIdentifier.resourceBundleName`).
    static let bundleNameProperty = "bundleName"

    /// The names SwiftPM gives the two files among a target's derived sources.
    static let headerFileName = "resource_bundle_accessor.h"
    static let sourceFileName = "resource_bundle_accessor.m"

    public static let descriptor = NodeDescriptor(inputPorts: [], outputPorts: [headerPort, sourcePort])

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public func didCreate() throws -> ProcessOutput? {
        let (moduleName, bundleName) = try Self.names(properties: thisNode.properties)
        return ProcessOutput(outputValues: [Self.headerPort: .value(try Self.header(moduleName: moduleName).intern()),
                                            Self.sourcePort: .value(try Self.source(moduleName: moduleName,
                                                                                     bundleName: bundleName).intern())],
                             inputWireSpecs: [:])
    }

    /// Never reached in a working graph: a node declaring no input ports is not scheduled.
    public func process(input: ProcessInput) throws -> ProcessOutput {
        throw NodeError.sourceCannotProcess(type: "\(Self.self)")
    }

    static func names(properties: [String: String]) throws -> (moduleName: String, bundleName: String) {
        guard let moduleName = properties[moduleNameProperty], !moduleName.isEmpty else {
            throw ErrorCondition.propertyMissing(type: "ResourceBundleAccessorWriter", property: moduleNameProperty, alternatives: [])
        }
        guard let bundleName = properties[bundleNameProperty], !bundleName.isEmpty else {
            throw ErrorCondition.propertyMissing(type: "ResourceBundleAccessorWriter", property: bundleNameProperty, alternatives: [])
        }
        return (moduleName, bundleName)
    }

    /// SwiftPM's header. Guarded by `__OBJC__`, so a C or C++ source of the same target,
    /// which is given it too, sees nothing.
    static func header(moduleName: String) -> String {
        """
        #if __OBJC__
        #import <Foundation/Foundation.h>

        #if __cplusplus
        extern "C" {
        #endif

        NSBundle* \(moduleName)_SWIFTPM_MODULE_BUNDLE(void);

        #define SWIFTPM_MODULE_BUNDLE \(moduleName)_SWIFTPM_MODULE_BUNDLE()

        #if __cplusplus
        }
        #endif
        #endif

        """
    }

    /// The accessor's definition, as this build lays a bundle out. The finder class gives
    /// `bundleForClass:` the code of this target, prefixed by the module's name so that two
    /// targets' finders are two classes.
    static func source(moduleName: String, bundleName: String) -> String {
        let finder = "\(moduleName)_SemelResourceBundleFinder"
        let bundleFileName = escaped("\(bundleName).bundle")
        return """
        #import <Foundation/Foundation.h>

        @interface \(finder) : NSObject
        @end

        @implementation \(finder)
        @end

        NSBundle* \(moduleName)_SWIFTPM_MODULE_BUNDLE(void) {
            static NSBundle *moduleBundle = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                NSURL *mainBundleURL = [[NSBundle mainBundle] bundleURL];
                NSArray<NSURL *> *candidates = @[
                    mainBundleURL,
                    [mainBundleURL URLByAppendingPathComponent:@"Contents/Resources"],
                    [[NSBundle bundleForClass:[\(finder) class]] bundleURL],
                ];
                for (NSURL *candidate in candidates) {
                    NSBundle *bundle = [NSBundle bundleWithURL:[candidate URLByAppendingPathComponent:@"\(bundleFileName)"]];
                    if (bundle != nil) {
                        moduleBundle = bundle;
                        return;
                    }
                }
            });
            if (moduleBundle == nil) {
                [NSException raise:NSInternalInconsistencyException format:@"unable to find bundle named %@", @"\(bundleFileName)"];
            }
            return moduleBundle;
        }

        """
    }

    /// An Objective-C string literal escapes a quote and a backslash, as C's does.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
