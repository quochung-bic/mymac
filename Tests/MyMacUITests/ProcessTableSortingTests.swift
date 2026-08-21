import Foundation
import MyMacCore
import Testing
@testable import MyMacUI

/// Regression cover for P3-16 in the 2026-08-20 audit: the process table's
/// column headers did nothing, and sorting lived in a segmented picker on the
/// toolbar. Clicking a header is what anyone on a Mac tries first.
///
/// The mapping is the part worth pinning: each key has a natural direction —
/// biggest offender first for CPU and memory, alphabetical for a name — so
/// which direction a header is asking for depends on the column.
@MainActor
@Suite("Process table sorting")
struct ProcessTableSortingTests {
    private func mapped(_ order: [KeyPathComparator<ProcessSample>]) -> (key: ProcessSortKey, reversed: Bool) {
        ProcessListView.sorting(for: order)
    }

    @Test func descendingCpuIsTheSorterSNaturalOrder() {
        let result = mapped([KeyPathComparator(\.cpuSortValue, order: .reverse)])
        #expect(result.key == .cpu)
        #expect(result.reversed == false, "biggest first is what .cpu already means")
    }

    @Test func ascendingCpuFlipsIt() {
        let result = mapped([KeyPathComparator(\.cpuSortValue, order: .forward)])
        #expect(result.key == .cpu)
        #expect(result.reversed)
    }

    @Test func ascendingNameIsTheSorterSNaturalOrder() {
        let result = mapped([KeyPathComparator(\.name, order: .forward)])
        #expect(result.key == .name)
        #expect(result.reversed == false, "A to Z is what .name already means")
    }

    @Test func descendingNameFlipsIt() {
        let result = mapped([KeyPathComparator(\.name, order: .reverse)])
        #expect(result.key == .name)
        #expect(result.reversed)
    }

    @Test func memoryAndPidMapToTheirOwnKeys() {
        #expect(mapped([KeyPathComparator(\.memorySortValue, order: .reverse)]).key == .memory)
        #expect(mapped([KeyPathComparator(\.id, order: .forward)]).key == .pid)
    }

    @Test func noOrderAtAllFallsBackToBusiestFirst() {
        let result = mapped([])
        #expect(result.key == .cpu)
        #expect(result.reversed == false)
    }

    /// The reason the table does not sort itself: a process the kernel refused
    /// to describe has no CPU figure, and it must not float to the top of an
    /// ascending sort just because `nil` maps to a small number.
    @Test func unreadableProcessesStayLastWhicheverWayTheColumnPoints() {
        let readable = ProcessSample(id: 1, name: "alpha", kind: .application,
                                     cpuUsage: 0.5, memoryFootprint: 100, isResponding: true)
        let unreadable = ProcessSample(id: 2, name: "beta", kind: .system,
                                       cpuUsage: nil, memoryFootprint: nil, isResponding: true)

        for order: SortOrder in [.forward, .reverse] {
            let sorting = mapped([KeyPathComparator(\.cpuSortValue, order: order)])
            let sorted = ProcessSorter.sort([unreadable, readable], by: sorting.key, reversed: sorting.reversed)
            #expect(sorted.last?.id == unreadable.id,
                    "unreadable must sort last with order \(order)")
        }
    }
}
