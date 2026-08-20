import Foundation
import Testing
@testable import MyMacCore

@Suite("Process watcher")
struct ProcessWatcherTests {
    private func sample(_ pid: pid_t, name: String = "worker",
                        cpu: Double?, memory: UInt64? = 100_000_000) -> ProcessSample {
        ProcessSample(id: pid, name: name, kind: .application,
                      cpuUsage: cpu, memoryFootprint: memory, isResponding: true)
    }

    private func feed(_ watcher: inout ProcessWatcher, _ samples: [ProcessSample],
                      times: Int) -> [ProcessAlert] {
        var alerts: [ProcessAlert] = []
        for _ in 0..<times { alerts = watcher.observe(samples) }
        return alerts
    }

    @Test func staysQuietUntilTheBehaviourIsSustained() {
        var watcher = ProcessWatcher()
        let busy = [sample(101, cpu: 1.5)]

        #expect(feed(&watcher, busy, times: 7).isEmpty, "seven samples is not yet sustained")
        #expect(!feed(&watcher, busy, times: 1).isEmpty, "the eighth completes the window")
    }

    @Test func ignoresASingleSpike() {
        var watcher = ProcessWatcher()
        _ = feed(&watcher, [sample(101, cpu: 0.02)], times: 7)
        let alerts = watcher.observe([sample(101, cpu: 3.0)])
        #expect(alerts.isEmpty, "a computer being briefly busy is not a fault")
    }

    @Test func ignoresAnAverageThatHidesQuietSamples() {
        var watcher = ProcessWatcher()
        // Alternating idle and very busy averages above the threshold, but the
        // process is plainly not stuck.
        for index in 0..<16 {
            _ = watcher.observe([sample(101, cpu: index.isMultiple(of: 2) ? 0.05 : 2.0)])
        }
        #expect(watcher.observe([sample(101, cpu: 2.0)]).isEmpty)
    }

    @Test func reportsSustainedCPUWithItsDuration() {
        var watcher = ProcessWatcher()
        let alerts = feed(&watcher, [sample(101, name: "render", cpu: 1.2)], times: 8)
        let alert = try! #require(alerts.first)

        guard case .sustainedCPU(let average, let seconds) = alert.reason else {
            Issue.record("expected a CPU alert")
            return
        }
        #expect(abs(average - 1.2) < 0.001)
        #expect(seconds == 16)
        #expect(alert.process.name == "render")
        #expect(alert.headline.contains("120%"))
    }

    @Test func reportsMemoryThatKeepsGrowing() {
        var watcher = ProcessWatcher()
        var alerts: [ProcessAlert] = []
        for step in 0..<9 {
            let footprint = UInt64(3_000_000_000 + step * 300_000_000)
            alerts = watcher.observe([sample(101, cpu: 0.01, memory: footprint)])
        }
        let alert = try! #require(alerts.first)
        guard case .growingMemory(let growth, let current) = alert.reason else {
            Issue.record("expected a memory alert")
            return
        }
        #expect(growth >= 1_000_000_000)
        #expect(current >= 3_000_000_000)
    }

    @Test func leavesSmallProcessesAloneHoweverFastTheyGrow() {
        var watcher = ProcessWatcher()
        var alerts: [ProcessAlert] = []
        for step in 0..<12 {
            alerts = watcher.observe([sample(101, cpu: 0.01, memory: UInt64(step) * 100_000_000)])
        }
        #expect(alerts.isEmpty, "growth below the floor is not worth reporting")
    }

    @Test func forgetsAProcessThatExited() {
        var watcher = ProcessWatcher()
        _ = feed(&watcher, [sample(101, cpu: 1.5)], times: 7)
        // The PID disappears, then comes back on a different, quiet process.
        _ = watcher.observe([])
        #expect(watcher.observe([sample(101, name: "other", cpu: 1.5)]).isEmpty,
                "a recycled PID must not inherit the old process's history")
    }

    @Test func ignoresProcessesWithNoReadableStatistics() {
        var watcher = ProcessWatcher()
        #expect(feed(&watcher, [sample(101, cpu: nil, memory: nil)], times: 12).isEmpty)
    }
}

@Suite("Process termination")
struct ProcessTerminationTests {
    @Test func refusesToSignalProtectedProcesses() {
        #expect(ProcessTerminator.isProtected(1))
        #expect(ProcessTerminator.isProtected(0))
        #expect(ProcessTerminator.isProtected(getpid()), "never quit ourselves from the process list")
        #expect(!ProcessTerminator.isProtected(getpid() + 10_000))
    }

    @Test func refusingIsAnErrorNotASilentNoOp() {
        #expect(throws: ProcessTerminator.Failure.refusedProtectedProcess) {
            try ProcessTerminator.terminate(pid: 1)
        }
        #expect(throws: ProcessTerminator.Failure.refusedProtectedProcess) {
            try ProcessTerminator.terminate(pid: getpid(), force: true)
        }
    }

    @Test func recognisesAProcessThatIsGone() {
        // A PID far above the current one is almost certainly unused.
        #expect(!ProcessTerminator.isRunning(pid: 900_000))
        #expect(ProcessTerminator.isRunning(pid: getpid()))
    }
}
