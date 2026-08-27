import Foundation
import Testing
@testable import MyMacCore

/// The process table re-sorts on every sample and again on every click of a
/// column header, with a list the size of a real machine's process table. The
/// comparator is therefore on a hot path and gets a budget like the collectors.
@Suite("Sorting cost", .serialized)
struct SortingCostTests {
    /// Shaped like a real machine: a few hundred readable processes, a third
    /// the kernel refuses to describe, and a great many tied at zero CPU —
    /// which is what drags the tie-break into the comparison.
    private func machineSizedList(count: Int = 680) -> [ProcessSample] {
        (0..<count).map { index in
            let readable = index % 3 != 0
            return ProcessSample(
                id: pid_t(index + 1),
                name: "process-\(index % 97)",
                kind: index % 5 == 0 ? .system : .background,
                cpuUsage: readable ? (index % 11 == 0 ? Double(index % 40) / 100 : 0) : nil,
                memoryFootprint: readable ? UInt64((index % 53) * 1_000_000) : nil,
                isResponding: true
            )
        }
    }

    private func time(_ label: String, iterations: Int = 20, _ body: () -> Void) -> Double {
        body()
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<iterations { body() }
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let perCall = seconds / Double(iterations) * 1000
        print(String(format: "SORT %-24s %8.3f ms/call", (label as NSString).utf8String!, perCall))
        return perCall
    }

    /// Skipped on CI, and on a machine that is busy with something else.
    ///
    /// This is a wall-clock budget, so it measures the machine as much as the
    /// comparator: with a UI test run or a build in the background the same
    /// code measures five times slower and the suite goes red over nothing.
    /// Loosening the number instead would defeat the point — 8 ms is the
    /// figure that makes a header click feel instant, and a budget nobody
    /// trusts is worse than one that only runs where it means something.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                   "a wall-clock budget needs a quiet machine"))
    func sortingAMachineSizedListIsFastEnoughToDoOnEveryKeystroke() {
        let processes = machineSizedList()
        var worst = 0.0
        for key in ProcessSortKey.allCases {
            for reversed in [false, true] {
                let cost = time("\(key.rawValue)\(reversed ? " reversed" : "")") {
                    _ = ProcessSorter.sort(processes, by: key, reversed: reversed)
                }
                worst = max(worst, cost)
            }
        }
        // A click on a column header should feel instant. Anything past a few
        // milliseconds is visible, and the list is re-sorted twice per redraw.
        #expect(worst < 8, "sorting is the slowest thing the process table does")
    }
}
