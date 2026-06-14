
//
//  NodeDescriptor.swift
//  build_system
//

import Foundation

// The world starts empty. Then the Input File System and Output File Systems are added. These are accessed by their string names when needed.
// Then the ProjectFinder Node is added. This is created with one static input but will create more dynamic inputs later. It has no outputs.
// Its responsibility is to observe the entire Input File System, searching for project files, package files, or anything that describes how to build
// a product or products. For each of these, a corresponding dynamic input is created (or just "exists", since these are a function of the input FS).
// Each dynamic input has an Expect value describing a graph whose root is the output of a PackageBuilder whose static input references the
// corresponding project file in the Input File System. In this way, ProjectFinder can have hundreds or thousands of dynamic inputs, each wired to
// a ProjectBuilder. Each ProjectBuilder has one or more dynamic inputs. If the project has e.g. 5 build products defined, there will be 5 dynamic
// inputs and one static input (for the project file itself.) Each dynamic input wires to a Product Node. A Product Node has one static input with
// an Expects value describing a complete build graph required to produce that particular product. The build graph is typically a Linker connected
// to N Compiler Nodes, each in turn connected to one Preprocessor Node, which in turn connects to one source file in the Input File System.
//
// All Nodes are held alive by their Output wires, with two exceptions: 1) a Node with no Outputs lives forever; 2) a Node within the Input File
// System lives until its parent is deleted or an explicit delete comes from outside the system.
//
// Any Node can be queried to obtain its "Flat Graph". This is a description of all its inputs, recursively.
// Crucially, this the excludes dynamic inputs of all Nodes. As an optimization, these Flat Graphs are cached in the database for each Node.
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
    // When a NodeFunction is instantiated for the first time and attached to a new Node,
    // its static Ports are automatically created based on the current NodeFunctionDescriptor.
    //
    // In contrast, dynamic ports are created automatically when a NodeFunction outputs
    // a ":dynamic-ports" keyed value during processing.
    //
    // This value contains a list of input and output ports along with "expected" schema
    // information for inputs.
    // This value is not written to a Port object in the database. Instead, it is
    // immediately parsed and applied to the overall Port configuration of the Node,
    // together with the NodeFunctionDescriptor's static port configuration.
    let staticInputPorts: [String]
    let staticOutputPorts: [String]
}
