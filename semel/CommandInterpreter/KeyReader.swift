// KeyReader.swift
// semel
//
// The key that ends a `watch` (B-95). The prompt reads whole lines through `readLine()`,
// which returns only on Return; a watch ends on any key, so for its length the terminal
// is taken out of line mode and read one byte at a time, then put back as it was.

import Foundation

/// How a key wait ended.
enum KeyWait: Equatable {
    /// A key was pressed — or standard input ended, which ends the wait the same way.
    case keyPressed
    /// The caller's condition came true before any key did.
    case stopped
}

/// Waits for one key. Behind a protocol so the interpreter never reads the real terminal
/// in a test, as `IndicatorLine` takes its `write` and its `now`.
protocol KeyReader {
    /// Whether there is a terminal to read a key from at all. A script's standard input is
    /// a pipe or a file, where nobody is going to press anything.
    var isTerminal: Bool { get }

    /// Blocks until a key is pressed or `stop` returns true, whichever is first. `stop` is
    /// asked often — every tenth of a second on the terminal — from the calling thread.
    func waitForKey(orUntil stop: () -> Bool) throws -> KeyWait
}

/// A terminal setting that could not be read, changed or polled; the call and the
/// system's reason, which is what there is to act on.
enum KeyReaderError: Error, CustomStringConvertible {
    case terminalCall(name: String, errorNumber: Int32)

    var description: String {
        switch self {
        case .terminalCall(let name, let errorNumber):
            return "the terminal could not be read one key at a time: \(name) failed: \(String(cString: strerror(errorNumber)))"
        }
    }
}

/// Standard input at a terminal, in raw mode for the length of one wait.
///
/// Echo off, so the key does not appear on the progress line; canonical mode off, so a
/// key arrives without Return. Signals off too: Control-C is the key most people press to
/// stop looking at something, and with `ISIG` left on it would kill the client with echo
/// still off, leaving a shell that does not show what is typed. With it off, Control-C is
/// a key like any other and ends the watch.
///
/// The settings are put back with `TCSAFLUSH`, which also discards what is still unread:
/// the rest of an arrow key's escape sequence, or what someone typed after the key that
/// ended the watch, which would otherwise arrive at the prompt as the start of a command.
struct TerminalKeyReader: KeyReader {

    /// How long one poll waits before `stop` is asked again: short enough that a settle
    /// ending the watch is not seen late, long enough to cost nothing.
    static let pollMilliseconds: Int32 = 100

    let fileDescriptor: Int32

    init() {
        self.init(fileDescriptor: STDIN_FILENO)
    }

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    var isTerminal: Bool {
        isatty(fileDescriptor) == 1
    }

    func waitForKey(orUntil stop: () -> Bool) throws -> KeyWait {
        var saved = termios()
        guard tcgetattr(fileDescriptor, &saved) == 0 else {
            throw KeyReaderError.terminalCall(name: "tcgetattr", errorNumber: errno)
        }
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
        // One byte is a read, and a read waits for it: `poll` has already said one is there.
        withUnsafeMutableBytes(of: &raw.c_cc) { characters in
            characters[Int(VMIN)]  = 1
            characters[Int(VTIME)] = 0
        }
        guard tcsetattr(fileDescriptor, TCSANOW, &raw) == 0 else {
            throw KeyReaderError.terminalCall(name: "tcsetattr", errorNumber: errno)
        }
        defer { tcsetattr(fileDescriptor, TCSAFLUSH, &saved) }

        while !stop() {
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Self.pollMilliseconds)
            if ready < 0 {
                // A signal — a resized window — interrupts the poll and nothing else.
                guard errno == EINTR else {
                    throw KeyReaderError.terminalCall(name: "poll", errorNumber: errno)
                }
                continue
            }
            guard ready > 0 else {
                continue
            }
            var byte: UInt8 = 0
            guard read(fileDescriptor, &byte, 1) >= 0 else {
                guard errno == EINTR else {
                    throw KeyReaderError.terminalCall(name: "read", errorNumber: errno)
                }
                continue
            }
            // A byte, or none at the end of input: either way nobody is left to wait for.
            return .keyPressed
        }
        return .stopped
    }
}
