import Foundation
import Testing
@testable import MyMacCore

@Suite("CPU math")
struct CPUMathTests {
    private func ticks(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32 = 0) -> CPUCollector.Ticks {
        CPUCollector.Ticks(user: user, system: system, idle: idle, nice: nice)
    }

    @Test func dividesTheIntervalBetweenStates() {
        let result = CPUCollector.fractions(
            current: ticks(user: 300, system: 200, idle: 500),
            previous: ticks(user: 100, system: 100, idle: 300)
        )
        // Deltas are 200 user, 100 system, 200 idle out of 500 ticks.
        #expect(abs(result.user - 0.4) < 0.0001)
        #expect(abs(result.system - 0.2) < 0.0001)
        #expect(abs(result.idle - 0.4) < 0.0001)
    }

    @Test func fractionsAlwaysSumToOne() {
        let result = CPUCollector.fractions(
            current: ticks(user: 17, system: 23, idle: 41, nice: 7),
            previous: ticks(user: 1, system: 2, idle: 3, nice: 4)
        )
        let sum: Double = result.user + result.system + result.idle + result.nice
        #expect(abs(sum - 1.0) < 0.0001)
    }

    @Test func survivesCounterWraparound() {
        // The kernel's tick counters are 32-bit and do wrap in long uptimes.
        let result = CPUCollector.fractions(
            current: ticks(user: 10, system: 0, idle: 10),
            previous: ticks(user: .max - 9, system: 0, idle: .max - 9)
        )
        #expect(abs(result.user - 0.5) < 0.0001)
        #expect(abs(result.idle - 0.5) < 0.0001)
    }

    @Test func reportsIdleWhenNoTimeHasPassed() {
        let sample = ticks(user: 5, system: 5, idle: 5)
        let result = CPUCollector.fractions(current: sample, previous: sample)
        #expect(result.idle == 1)
        #expect(result.user == 0)
    }
}

@Suite("Memory math")
struct MemoryMathTests {
    private func stats(app: UInt64, wired: UInt64, compressed: UInt64,
                       cached: UInt64, total: UInt64) -> MemoryStats {
        MemoryStats(total: total, app: app, wired: wired, compressed: compressed,
                    cached: cached, free: 0, swapUsed: 0, swapTotal: 0, pressure: .low)
    }

    @Test func usedMemoryExcludesEvictableFileCache() {
        let sample = stats(app: 4_000, wired: 2_000, compressed: 1_000, cached: 8_000, total: 16_000)
        #expect(sample.used == 7_000)
        #expect(sample.available == 9_000)
        #expect(abs(sample.usedFraction - 7.0 / 16.0) < 0.0001)
    }

    @Test func neverReportsNegativeAvailableMemory() {
        let sample = stats(app: 20_000, wired: 0, compressed: 0, cached: 0, total: 16_000)
        #expect(sample.available == 0)
    }

    @Test func derivedPressureTracksUnevictablePages() {
        #expect(MemoryCollector.derivedPressure(compressed: 1, wired: 1, total: 100) == .low)
        #expect(MemoryCollector.derivedPressure(compressed: 30, wired: 30, total: 100) == .moderate)
        #expect(MemoryCollector.derivedPressure(compressed: 50, wired: 40, total: 100) == .high)
        #expect(MemoryCollector.derivedPressure(compressed: 0, wired: 0, total: 0) == .low)
    }

    @Test func pressureLevelsOrderCorrectly() {
        #expect(MemoryPressure.low < MemoryPressure.moderate)
        #expect(MemoryPressure.moderate < MemoryPressure.high)
    }
}

@Suite("Disk math")
struct DiskMathTests {
    @Test func usedSpaceIsCapacityMinusReclaimableSpace() {
        let volume = VolumeStats(id: "1", name: "Macintosh HD", url: URL(fileURLWithPath: "/"),
                                 total: 1_000, available: 250, isInternal: true,
                                 isRemovable: false, fileSystem: "APFS")
        #expect(volume.used == 750)
        #expect(abs(volume.usedFraction - 0.75) < 0.0001)
    }

    @Test func handlesAVolumeReportingZeroCapacity() {
        let volume = VolumeStats(id: "1", name: "Empty", url: URL(fileURLWithPath: "/"),
                                 total: 0, available: 0, isInternal: false,
                                 isRemovable: true, fileSystem: nil)
        #expect(volume.usedFraction == 0)
    }
}

@Suite("Process sorting")
struct ProcessSortingTests {
    private let processes = [
        ProcessSample(id: 3, name: "Zebra", kind: .application, cpuUsage: 0.10, memoryFootprint: 300, isResponding: true),
        ProcessSample(id: 1, name: "alpha", kind: .background, cpuUsage: 0.50, memoryFootprint: 100, isResponding: true),
        ProcessSample(id: 2, name: "Mango", kind: .system, cpuUsage: nil, memoryFootprint: nil, isResponding: true),
        ProcessSample(id: 4, name: "beta", kind: .application, cpuUsage: 0.25, memoryFootprint: 900, isResponding: true),
    ]

    @Test func sortsByCPUDescendingWithUnreadableProcessesLast() {
        let sorted = ProcessSorter.sort(processes, by: .cpu)
        #expect(sorted.map(\.name) == ["alpha", "beta", "Zebra", "Mango"])
    }

    @Test func sortsByMemoryDescendingWithUnreadableProcessesLast() {
        let sorted = ProcessSorter.sort(processes, by: .memory)
        #expect(sorted.map(\.name) == ["beta", "Zebra", "alpha", "Mango"])
    }

    @Test func sortsByNameCaseInsensitively() {
        let sorted = ProcessSorter.sort(processes, by: .name)
        #expect(sorted.map(\.name) == ["alpha", "beta", "Mango", "Zebra"])
    }

    @Test func reversingKeepsUnreadableProcessesOutOfTheWayOfTheEye() {
        let sorted = ProcessSorter.sort(processes, by: .cpu, reversed: true)
        #expect(sorted.first?.name == "Mango")
        #expect(sorted.last?.name == "alpha")
    }

    @Test func sortIsStableForEqualValues() {
        let tied = [
            ProcessSample(id: 9, name: "same", kind: .background, cpuUsage: 0.1, memoryFootprint: 5, isResponding: true),
            ProcessSample(id: 2, name: "same", kind: .background, cpuUsage: 0.1, memoryFootprint: 5, isResponding: true),
        ]
        #expect(ProcessSorter.sort(tied, by: .cpu).map(\.id) == [2, 9])
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test func formatsBytesWithoutSpellingOutZero() {
        #expect(Format.bytes(Int64(0)) == "0 bytes")
        #expect(Format.bytes(Int64(-5)) == "0 bytes")
        #expect(Format.bytes(Int64(2_000_000_000)).contains("GB"))
    }

    @Test func formatsPercentagesAsWholeNumbers() {
        #expect(Format.percent(0.184) == "18%")
        #expect(Format.percent(1) == "100%")
        #expect(Format.percent(.nan) == "—")
    }

    @Test func formatsThroughputWithASensibleFloor() {
        #expect(Format.throughput(0) == "0 KB/s")
        #expect(Format.throughput(0.4) == "0 KB/s")
        #expect(Format.throughput(5_000_000).hasSuffix("/s"))
    }

    @Test func formatsDurations() {
        #expect(Format.duration(0) == "—")
        #expect(Format.duration(45) == "45 min")
        #expect(Format.duration(120) == "2 hr")
        #expect(Format.duration(135) == "2 hr 15 min")
    }
}

@Suite("Rolling window")
struct RollingWindowTests {
    @Test func keepsChronologicalOrderAfterWrapping() {
        var window = RollingWindow<Int>(capacity: 3)
        for value in 1...5 { window.append(value) }
        #expect(window.values == [3, 4, 5])
        #expect(window.last == 5)
        #expect(window.count == 3)
    }

    @Test func staysEmptyUntilFilled() {
        var window = RollingWindow<Int>(capacity: 4)
        #expect(window.isEmpty)
        window.append(7)
        #expect(window.values == [7])
        window.removeAll()
        #expect(window.isEmpty)
    }
}

@Suite("Process CPU formatting")
struct ProcessCPUFormattingTests {
    @Test func keepsADecimalForSmallValues() {
        #expect(Format.processCPU(0.004) == "0.4%")
        #expect(Format.processCPU(0.099) == "9.9%")
    }

    @Test func dropsTheDecimalOnceItIsNoiseFree() {
        #expect(Format.processCPU(0.15) == "15%")
        #expect(Format.processCPU(1.6) == "160%", "a busy multithreaded process exceeds one core")
    }

    @Test func collapsesGenuineZero() {
        #expect(Format.processCPU(0) == "0%")
        #expect(Format.processCPU(0.0001) == "0%")
        #expect(Format.processCPU(.nan) == "—")
    }
}

@Suite("Wi-Fi signal")
struct WiFiSignalTests {
    private func signal(rssi: Int, noise: Int = -90) -> WiFiSignal {
        WiFiSignal(rssi: rssi, noise: noise, transmitRate: 300, channel: 40,
                   band: "5 GHz", channelWidth: 80)
    }

    @Test func describesQualityTheWayAPersonWould() {
        #expect(signal(rssi: -45).quality == "Excellent")
        #expect(signal(rssi: -65).quality == "Good")
        #expect(signal(rssi: -75).quality == "Fair")
        #expect(signal(rssi: -88).quality == "Weak")
    }

    @Test func signalToNoiseIsTheGapBetweenThem() {
        #expect(signal(rssi: -61, noise: -89).signalToNoise == 28)
    }

    @Test func strengthFractionStaysInRange() {
        #expect(signal(rssi: -20).strengthFraction == 1)
        #expect(signal(rssi: -100).strengthFraction == 0)
        let middling = signal(rssi: -62).strengthFraction
        #expect(middling > 0.4 && middling < 0.6)
    }
}
