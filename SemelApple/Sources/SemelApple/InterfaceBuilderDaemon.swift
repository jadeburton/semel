//
//  InterfaceBuilderDaemon.swift
//  SemelApple
//
//  What `ibtool` and `actool` are told so that a run never shares Interface Builder's
//  daemon with another (B-152).
//

/// `ibtool` and `actool` are clients of `ibtoold`. By default a client takes a daemon from a
/// per-user pool that every run on the machine shares, and the daemon keeps state between
/// clients: its working directory.
///
/// Measured on Xcode 26.6, 2026-10-11. An `actool` request leaves its daemon in the
/// client's working directory. A later `ibtool` client in another folder that gets the
/// same daemon has its relative paths resolved against that directory, not its own, and
/// fails with `Interface Builder could not open the document … because it does not exist`.
/// That was eleven of Sequel Ace's xibs, against a catalog compiled just before. If that
/// directory has been removed, every client fails with `IBCurrentDirectoryPath …
/// currentDirectoryPath is unexpectedly nil`. That is what a removed sandbox did, and it
/// went on until the daemons exited after about two minutes idle. Neither setting `PWD`
/// nor passing the full environment changes this, and starting the daemon first from a
/// lasting folder does not either: a daemon starts in `/`, and each request moves it.
///
/// `IBToolNeverDeque=YES`, an environment variable both clients read, makes a client start
/// a daemon of its own instead of taking one from the pool. That daemon leaves nothing
/// behind and touches no pooled daemon. With it, six parallel `ibtool` runs and three
/// `actool` runs passed with relative paths, while a pooled daemon sat in a folder nobody
/// used. Paths stay relative to the sandbox, which is all `ToolSandbox` allows on a
/// command line. The cost is a daemon started per run, about 0.6 s, where a pooled daemon
/// answers at once.
///
/// The variable is fixed, not a setting: it changes how the tool is reached, not what it
/// writes.
enum InterfaceBuilderDaemon {
    static let environment = ["IBToolNeverDeque": "YES"]
}
