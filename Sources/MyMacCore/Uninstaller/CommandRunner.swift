import Foundation

/// Runs an external program with an argument vector.
///
/// There is no shell anywhere in here: `Process` is given an executable URL and
/// an array of arguments, so nothing a package name contains can ever be
/// interpreted as syntax. Names are validated anyway, because defence in depth
/// costs one regular expression.
public enum CommandRunner {
    public enum Failure: Error, Sendable, Equatable {
        case executableNotFound
        case invalidArgument(String)
        case failed(status: Int32, output: String)
        case timedOut

        public var message: String {
            switch self {
            case .executableNotFound: "The tool is not installed where this app looks for it."
            case .invalidArgument(let value): "Refused an unsafe argument: \(value)"
            case .failed(_, let output): output.isEmpty ? "The tool reported an error." : output
            case .timedOut: "The tool did not finish in time."
            }
        }
    }

    /// Package names across every ecosystem here are ASCII words with a small
    /// set of separators. Anything else is refused rather than escaped, and a
    /// leading character that is not alphanumeric is refused too — that is what
    /// would let a name be mistaken for a flag.
    private static let allowedCharacters = Set("abcdefghijklmnopqrstuvwxyz"
        + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._+-/")

    public static func validate(_ argument: String) throws {
        // A leading "@" is allowed for scoped npm packages; a leading "-" is
        // what would let a name be mistaken for a flag, and stays refused.
        guard let first = argument.first, first.isLetter || first.isNumber || first == "@",
              argument != "@",
              argument.count <= 214,
              argument.allSatisfy(allowedCharacters.contains)
        else { throw Failure.invalidArgument(argument) }
    }

    public static func firstExecutable(among candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// - Returns: combined standard output and standard error, trimmed.
    @discardableResult
    public static func run(executable: URL, arguments: [String],
                           timeout: Duration = .seconds(180)) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure.executableNotFound
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // A minimal, predictable environment. The app is launched by Finder, so
        // inheriting the shell's PATH is not an option anyway.
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            // Stops npm and friends from emitting progress bars and colour codes.
            "CI": "1",
            "NO_COLOR": "1",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Nothing is ever written to the child's standard input. Left inherited,
        // a tool that decides to ask a question would sit there for ever with
        // nobody to answer it.
        process.standardInput = FileHandle.nullDevice

        // Drain the pipe as it fills, on Foundation's own queue. A full pipe
        // buffer blocks the child, so reading has to run alongside the wait
        // rather than before it — the previous version read to EOF first, which
        // meant it only ever returned once the child had already exited.
        let output = OutputCollector(pipe.fileHandleForReading)

        // Armed before `run()`: assigning a termination handler to a process
        // that has already exited never fires it.
        let exit = ExitWaiter()
        process.terminationHandler = { exit.finish($0.terminationStatus) }

        try process.run()
        let pid = process.processIdentifier

        // The deadline starts here, before anything can block. Previously it was
        // created after the read had already returned, so it could only fire
        // once the child was gone — exactly when it is not needed. A wedged
        // package manager held the actor, and the interface, for ever.
        //
        // Only the pid crosses into the task: `Process` is not `Sendable`, and a
        // signal is all that terminating it amounts to anyway.
        let deadline = Task {
            try await Task.sleep(for: timeout)
            guard !exit.hasFinished else { return }
            exit.markTimedOut()
            kill(pid, SIGTERM)
            // SIGTERM is a request. A tool that ignores it gets one grace
            // period, then the blunt instrument.
            try await Task.sleep(for: .seconds(5))
            guard !exit.hasFinished else { return }
            kill(pid, SIGKILL)
        }

        let status = await exit.value()
        deadline.cancel()

        let text = String(decoding: await output.value(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if exit.didTimeOut { throw Failure.timedOut }
        guard status == 0 else {
            throw Failure.failed(status: status, output: text)
        }
        return text
    }
}

/// Bridges `Process.terminationHandler` — which fires on an arbitrary thread,
/// possibly before anyone has started waiting — to one `async` resumption.
private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?
    private var timedOut = false

    var hasFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return status != nil
    }

    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    func markTimedOut() {
        lock.lock(); defer { lock.unlock() }
        timedOut = true
    }

    func finish(_ value: Int32) {
        lock.lock()
        guard status == nil else { return lock.unlock() }
        status = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }

    func value() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// Accumulates a child's combined output as it arrives, and resumes once the
/// pipe reaches end of file — which happens when the child and Foundation have
/// both let go of the write end.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var isClosed = false
    private var continuation: CheckedContinuation<Data, Never>?

    init(_ handle: FileHandle) {
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                close()
                return
            }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }
    }

    private func close() {
        lock.lock()
        guard !isClosed else { return lock.unlock() }
        isClosed = true
        let waiting = continuation
        let collected = data
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: collected)
    }

    func value() async -> Data {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isClosed {
                let collected = data
                lock.unlock()
                continuation.resume(returning: collected)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
