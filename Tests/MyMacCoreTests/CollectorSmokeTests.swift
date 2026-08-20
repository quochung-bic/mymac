import Testing
import Foundation
@testable import MyMacCore

@Suite("Live collectors")
struct CollectorSmokeTests {
    @Test func cpuReportsPlausibleUsage() async throws {
        let collector = await MetricsActor.run { CPUCollector() }
        _ = await collector.sample()
        try await Task.sleep(for: .milliseconds(400))
        let stats = await collector.sample()
        print("CPU usage=\(stats.usage) user=\(stats.user) sys=\(stats.system) idle=\(stats.idle) cores=\(stats.coreCount) perCore=\(stats.perCore.count) load=\(stats.loadAverage.oneMinute)")
        #expect(stats.usage >= 0 && stats.usage <= 1)
        #expect(stats.perCore.count == stats.coreCount || !stats.perCore.isEmpty)
        let sum: Double = stats.user + stats.system + stats.idle + stats.niceTime
        #expect(abs(sum - 1.0) < 0.01)
    }

    @Test func memoryMatchesPhysicalRAM() async {
        let collector = await MetricsActor.run { MemoryCollector() }
        let stats = await collector.sample()
        print("MEM total=\(Format.bytes(stats.total)) used=\(Format.bytes(stats.used)) app=\(Format.bytes(stats.app)) wired=\(Format.bytes(stats.wired)) comp=\(Format.bytes(stats.compressed)) cached=\(Format.bytes(stats.cached)) swap=\(Format.bytes(stats.swapUsed))/\(Format.bytes(stats.swapTotal)) pressure=\(stats.pressure.label)")
        #expect(stats.total == ProcessInfo.processInfo.physicalMemory)
        #expect(stats.used > 0 && stats.used <= stats.total)
    }

    @Test func diskListsBootVolume() async {
        let collector = await MetricsActor.run { DiskCollector() }
        let stats = await collector.sample()
        for volume in stats.volumes {
            print("VOL \(volume.name) total=\(Format.bytes(volume.total)) avail=\(Format.bytes(volume.available)) used=\(Format.percent(volume.usedFraction)) internal=\(volume.isInternal) fs=\(volume.fileSystem ?? "?")")
        }
        #expect(!stats.volumes.isEmpty)
    }

    @Test func batteryDegradesGracefully() async {
        let collector = await MetricsActor.run { BatteryCollector() }
        let stats = await collector.sample()
        print("BATTERY \(String(describing: stats))")
        if let stats { #expect(stats.charge >= 0 && stats.charge <= 1) }
    }

    @Test func networkReportsInterfaces() async throws {
        let collector = await MetricsActor.run { NetworkCollector() }
        await collector.start()
        _ = await collector.sample()
        try await Task.sleep(for: .milliseconds(600))
        let stats = await collector.sample()
        print("NET iface=\(stats.interfaceName ?? "nil") kind=\(stats.interfaceKind) down=\(Format.throughput(stats.downloadThroughput)) up=\(Format.throughput(stats.uploadThroughput)) connected=\(stats.isConnected)")
        await collector.stop()
        #expect(stats.downloadThroughput >= 0)
    }

    @Test func processesIncludeThisTestRunner() async throws {
        let collector = await MetricsActor.run { ProcessCollector() }
        _ = await collector.sample()
        try await Task.sleep(for: .milliseconds(400))
        let processes = await collector.sample()
        let top = ProcessSorter.sort(processes, by: .memory).prefix(5)
        for process in top {
            print("PROC \(process.pid) \(process.name) cpu=\(process.cpuUsage.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a") mem=\(process.memoryFootprint.map(Format.bytes) ?? "n/a") kind=\(process.kind.rawValue)")
        }
        print("PROC total=\(processes.count) readable=\(processes.filter { $0.memoryFootprint != nil }.count)")
        #expect(processes.count > 10)
        #expect(processes.contains { $0.pid == getpid() })
    }
}
