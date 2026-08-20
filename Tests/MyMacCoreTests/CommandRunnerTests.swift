import Foundation
import Testing
@testable import MyMacCore

/// Regression cover for the `CommandRunner` faults found in the 2026-08-20
/// audit. The timeout existed but could never fire, because the deadline was
/// armed only after a blocking read to end-of-file had already returned.
@Suite("Command runner", .serialized)
struct CommandRunnerTests {
    private let sleepTool = URL(fileURLWithPath: "/bin/sleep")
    private let echoTool = URL(fileURLWithPath: "/bin/echo")
    private let catTool = URL(fileURLWithPath: "/bin/cat")
    private let falseTool = URL(fileURLWithPath: "/usr/bin/false")

    @Test func returnsOutputOfACommandThatSucceeds() async throws {
        let output = try await CommandRunner.run(executable: echoTool, arguments: ["hello there"])
        #expect(output == "hello there")
    }

    @Test func reportsTheStatusOfACommandThatFails() async throws {
        await #expect(throws: CommandRunner.Failure.self) {
            try await CommandRunner.run(executable: falseTool, arguments: [])
        }
    }

    /// The fault itself. Before the fix this test would have hung for the full
    /// thirty seconds, because nothing could interrupt the read.
    @Test func aHungCommandIsCutOffAtTheDeadline() async throws {
        let clock = ContinuousClock()
        let started = clock.now

        await #expect(throws: CommandRunner.Failure.timedOut) {
            try await CommandRunner.run(executable: sleepTool,
                                        arguments: ["30"],
                                        timeout: .milliseconds(400))
        }

        let elapsed = clock.now - started
        #expect(elapsed < .seconds(10),
                "the deadline must end the wait, not the command's own runtime")
    }

    /// The other half of the same rewrite. A child that writes more than the
    /// pipe buffer holds (64 KB) blocks until someone drains it, so the read has
    /// to run alongside the wait rather than after it.
    @Test func outputLargerThanThePipeBufferDoesNotDeadlock() async throws {
        let temp = try TemporaryDirectory()
        let payload = String(repeating: "abcdefghij", count: 100_000)  // ~1 MB
        let file = temp.url.appendingPathComponent("large.txt")
        try Data(payload.utf8).write(to: file)

        let output = try await CommandRunner.run(executable: catTool,
                                                 arguments: [file.path],
                                                 timeout: .seconds(20))
        #expect(output.count == payload.count)
        #expect(output.hasPrefix("abcdefghij"))
    }

    /// A tool that decides to prompt would otherwise inherit our standard input
    /// and wait for an answer nobody is there to give.
    @Test func standardInputIsClosedSoNothingCanWaitOnAPrompt() async throws {
        let output = try await CommandRunner.run(executable: catTool,
                                                 arguments: [],
                                                 timeout: .seconds(5))
        #expect(output.isEmpty, "cat with no arguments reads stdin, which must be at EOF")
    }
}
