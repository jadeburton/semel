
//
//  NodeDescriptor.swift
//  build_system
//

import Foundation

// Static ports are fully connected during creation and so do not declare "expect" metadata. Dynamic ports are also present after initialization,
// however there is no actual database representation for either dynamic or static input ports; they exist only in the code. Only wires connected
// to them indicate their presence in the database. Output ports may have both wires and persisted output values in the database.
//
// Dynamic input ports (output ports cannot be dynamic) can declare a list of expected input Wires, each with a unique string name, and each
// with an Expects value. Although dynamic input ports cannot be created or deleted after creation of the Node, the NodeFunction can modify the
// Expected list of each, causing instant rewiring immediately after the process() execution step.
// This metadata is not stored in the database directly. The NodeFunction outputs it as though it were any other output value. The subsystem
// then compares the expected wires with the actual wires. If there are wires missing, they are created and connected. If there are surplus wires,
// they are deleted, which may cause a cascading delete of upstream Nodes.
//
// The world starts empty. Then the Input File System and Output File Systems are added. These are accessed by their string names when needed.
// Then the ProjectFinder Node is added.
// This is created with one static input port called "fileSystemRoot" and one dynamic input port called "projectBuilders". The Node has no outputs.
// Its responsibility is to observe the entire Input File System, searching for project files, package files, or anything that describes how to build
// a product or products. For each of these, a corresponding wire to the dynamic input is created (or just "exists", since these are a function of
// the input FS).
//
// The dynamic input port of the ProjectFinder has zero or more Wire Expectation values, each describing a graph whose root is the output of a
// PackageBuilder, whose static input ("projectFile") references the corresponding project file in the Input File System.
//
// Each ProjectBuilder also has a dynamic input port called "products". If the project has e.g. 5 build products defined, there will be 5 named
// wires going to this dynamic input port. Each dynamic input wires to the output of a Product Node. A Product Node has one static input that is
// connected to the complete build graph required to produce that particular product. The build graph is typically a Linker connected to N
// Compiler Nodes, each in turn connected to one Preprocessor Node, which in turn connects to one source file in the Input File System.
//
// All Nodes are held alive by their Output wires, with two exceptions: 1) a Node with no Outputs lives forever; 2) a Node within the Input File
// System lives until its parent is deleted or an explicit delete comes from outside the system.
//
// When the user deletes a file in the input file system, its Node is deleted from the input file system - unless there are one or more wires
// referencing it.
// In that case it is not removed from the graph; it is made to have nil content. This means the file is "missing" but there is a representation
// in the graph for it. When the user lists files it will be marked as missing instead of deleted. Deleting the project file that references the
// file should cause the graph to delete the wires to the input file, at which point it can be truly deleted.
//
// Any Node can be queried to obtain its "Flat Graph". This is a description of all its inputs, recursively.
// Crucially, this excludes the dynamic inputs of all Nodes. As an optimization, these Flat Graphs are cached in the database for each Node.
// Once a Node is created, it is guaranteed that the graph of all upstream (input) Nodes will never change, with the exception of dynamic inputs,
// which can change. An example is the dynamic inputs of a Preprocessor, wiring into newly found header files. These header files are a function of
// the input source file and are therefore elided from the Flat Graph.
//
// There is a function that can be called to fetch a Node by its Flat Graph. This search is done via the cached Flat Graph value in the database.
// If no such Node exists, one is automatically created and all of its upstream/input Nodes are also atomically created.
// Because the process of connecting an input wire to a Node calls the Flat-Graph-matching function to obtain the Node, the system reuses existing
// fragments of the graph where it can, instead of creating new branches.

// Each NodeFunction provides a NodeFunctionDescriptor, which is derived from hard-coded
// values and values passed to the NodeFunction's initializer such as e.g. a file path.
struct NodeFunctionDescriptor {
    // A static port is one that cannot change after the NodeFunction has been created.
    // This is important, because changing static ports would break downstream Nodes that
    // rely on an exact upstream/input graph shape.
    let staticInputPorts: [String]
    let outputPorts: [String]
    let dynamicInputPorts: [String]
}
