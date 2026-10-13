import Foundation
import Testing
@testable import MyMacCore

@Suite("Thermal level")
struct ThermalLevelTests {
    @Test func mapsEverySystemState() {
        #expect(ThermalLevel(.nominal) == .nominal)
        #expect(ThermalLevel(.fair) == .fair)
        #expect(ThermalLevel(.serious) == .serious)
        #expect(ThermalLevel(.critical) == .critical)
    }

    @Test func levelsOrderFromCoolestToHottest() {
        #expect(ThermalLevel.allCases.sorted() == [.nominal, .fair, .serious, .critical])
    }

    @Test func everyLevelExplainsItself() {
        for level in ThermalLevel.allCases {
            #expect(!level.label.isEmpty)
            #expect(level.explanation.contains(level.label))
        }
    }
}

@Suite("Process disk activity")
struct ProcessDiskActivityTests {
    private func process(_ id: pid_t, _ name: String, disk: Double?) -> ProcessSample {
        ProcessSample(id: id, name: name, kind: .background, cpuUsage: 0.1,
                      memoryFootprint: 1, isResponding: true, diskRate: disk)
    }

    @Test func heaviestWriterSortsFirstAndUnreadableLast() {
        let rows = [process(1, "idle", disk: 0), process(2, "denied", disk: nil),
                    process(3, "busy", disk: 5_000_000)]
        let sorted = ProcessSorter.sort(rows, by: .disk)
        #expect(sorted.map(\.name) == ["busy", "idle", "denied"])
    }

    @Test func reversingKeepsUnreadableLast() {
        let rows = [process(1, "idle", disk: 0), process(2, "denied", disk: nil),
                    process(3, "busy", disk: 5_000_000)]
        let sorted = ProcessSorter.sort(rows, by: .disk, reversed: true)
        #expect(sorted.map(\.name) == ["idle", "busy", "denied"])
    }
}
