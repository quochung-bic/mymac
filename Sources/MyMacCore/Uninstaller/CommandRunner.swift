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

        try process.run()

        let handle = pipe.fileHandleForReading
        // Read to end before waiting: a full pipe buffer would deadlock a
        // process that is still writing.
        let data = try await Task.detached(priority: .utility) {
            try handle.readToEnd() ?? Data()
        }.value

        let deadline = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        deadline.cancel()

        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure.failed(status: process.terminationStatus, output: output)
        }
        return output
    }
}
