import Foundation
import Testing
@testable import MyMacCore

@Suite("Extended metrics")
struct ExtendedMetricsTests {
    @Test func systemInfoIdentifiesTheMachine() {
        let info = SystemInfo.current
        print("SYS chip=\(info.chip) model=\(info.model) cores=\(info.coreSummary) phys=\(info.physicalCores) logical=\(info.logicalCores) ram=\(Format.bytes(info.physicalMemory)) uptime=\(Format.uptime(info.uptime)) os=\(info.operatingSystem)")
        #expect(!info.chip.isEmpty)
        #expect(info.logicalCores > 0)
        #expect(info.physicalMemory > 0)
        #expect(info.uptime > 0)
    }

    @Test func cpuReportsTasksAndThreads() async throws {
        let collector = await MetricsActor.run { CPUCollector() }
        _ = await collector.sample()
        try await Task.sleep(for: .milliseconds(300))
        let stats = await collector.sample()
        print("CPU tasks=\(stats.taskCount.map(String.init) ?? "nil") threads=\(stats.threadCount.map(String.init) ?? "nil")")
        #expect(stats.taskCount ?? 0 > 10)
        #expect(stats.threadCount ?? 0 > (stats.taskCount ?? 0))
    }

    @Test func memoryReportsPagingActivity() async throws {
        let collector = await MetricsActor.run { MemoryCollector() }
        _ = await collector.sample()
        try await Task.sleep(for: .milliseconds(500))
        let stats = await collector.sample()
        print("MEM swapIn=\(Format.throughput(stats.swapInRate)) swapOut=\(Format.throughput(stats.swapOutRate)) pageIn=\(Int(stats.pageInRate))/s pageOut=\(Int(stats.pageOutRate))/s ratio=\(String(format: "%.2f", stats.compressionRatio))x")
        #expect(stats.swapInRate >= 0)
        #expect(stats.compressionRatio >= 1 || stats.compressionRatio == 0)
    }

    @Test func diskReportsOperationsAndPurgeable() async throws {
        let collector = await MetricsActor.run { DiskCollector() }
        _ = await collector.sample()
        try await Task.sleep(for: .milliseconds(500))
        let stats = await collector.sample()
        print("DISK readOps=\(Int(stats.readOperations))/s writeOps=\(Int(stats.writeOperations))/s session=\(Format.bytes(stats.sessionRead))/\(Format.bytes(stats.sessionWritten))")
        for volume in stats.volumes {
            print("  \(volume.name): purgeable=\(Format.bytes(volume.purgeable)) available=\(Format.bytes(volume.available))")
        }
        #expect(stats.readOperations >= 0)
    }

    @Test func networkReportsAddressesAndPackets() async throws {
        let collector = await MetricsActor.run { NetworkCollector() }
        await collector.start()
        _ = await collector.sample()
        try await Task.sleep(for: .milliseconds(700))
        let stats = await collector.sample()
        print("NET router=\(stats.router ?? "nil") dns=\(stats.dnsServers) vpn=\(stats.usesVPN) expensive=\(stats.isExpensive) lifetime=\(Format.bytes(stats.lifetimeReceived))/\(Format.bytes(stats.lifetimeSent))")
        if let wifi = stats.wifi {
            print("WIFI rssi=\(wifi.rssi) noise=\(wifi.noise) snr=\(wifi.signalToNoise) rate=\(wifi.transmitRate) ch=\(wifi.channel) \(wifi.band) \(wifi.channelWidth)MHz quality=\(wifi.quality) bar=\(String(format: "%.2f", wifi.strengthFraction))")
        }
        print("NET iface=\(stats.interfaceName ?? "nil") addresses=\(stats.addresses) pkts=\(Int(stats.packetsInRate))/\(Int(stats.packetsOutRate)) errs=\(stats.errorsIn)/\(stats.errorsOut) drops=\(stats.drops) link=\(stats.linkSpeed) mtu=\(stats.mtu) activeInterfaces=\(stats.interfaces.map(\.id))")
        await collector.stop()
        #expect(stats.mtu > 0 || stats.interfaceName == nil)
    }

    @Test func batteryReportsPowerAndAdapter() async {
        let collector = await MetricsActor.run { BatteryCollector() }
        guard let stats = await collector.sample() else {
            print("BATTERY none (desktop)")
            return
        }
        print("BATTERY charge=\(Format.percent(stats.charge)) V=\(stats.voltage.map { String(format: "%.2f", $0) } ?? "nil") A=\(stats.amperage.map { String(format: "%.2f", $0) } ?? "nil") W=\(stats.powerDraw.map { String(format: "%.1f", $0) } ?? "nil") mAh=\(stats.currentCapacity.map(String.init) ?? "nil")/\(stats.designCapacity.map(String.init) ?? "nil") adapter=\(stats.adapterName ?? "nil") \(stats.adapterWatts.map(String.init) ?? "?")W lowPower=\(stats.isLowPowerMode)")
        #expect(stats.charge >= 0 && stats.charge <= 1)
    }
}

@Suite("Public address")
struct PublicAddressTests {
    @Test func readsTheTraceFormat() throws {
        let body = """
        fl=1176f52
        h=www.cloudflare.com
        ip=203.0.113.7
        ts=1787200785.000
        loc=VN
        """
        let address = try #require(PublicAddressService.parse(body))
        #expect(address.ip == "203.0.113.7")
        #expect(address.country == "VN")
    }

    @Test func refusesABodyWithoutAnAddress() {
        #expect(PublicAddressService.parse("h=example.com\nts=1") == nil)
        #expect(PublicAddressService.parse("") == nil)
        #expect(PublicAddressService.parse("ip=") == nil)
    }

    @Test func treatsAnUnknownCountryAsAbsent() throws {
        let address = try #require(PublicAddressService.parse("ip=203.0.113.7\nloc=XX"))
        #expect(address.country == nil)
    }
}

@Suite("Network sampling stability")
struct NetworkSamplingStabilityTests {
    /// A throttle counter that grew without bound overflowed on the first
    /// sample and took the whole app down with it.
    @Test func manySamplesWithTheRadioRequestedDoNotOverflow() async throws {
        let collector = await MetricsActor.run { NetworkCollector() }
        await collector.start()
        defer { Task { await collector.stop() } }

        await MetricsActor.run {
            for _ in 0..<200 { _ = collector.sample(includeRadio: true) }
            for _ in 0..<200 { _ = collector.sample(includeRadio: false) }
        }
        let stats = await MetricsActor.run { collector.sample(includeRadio: true) }
        #expect(stats.downloadThroughput >= 0)
    }
}

@Suite("Per-process CPU accuracy")
struct ProcessCPUAccuracyTests {
    /// `proc_pid_rusage` reports mach ticks, not nanoseconds. On Apple Silicon
    /// that is a factor of ~24, so a busy process read as barely working.
    @Test func measuresAFullyBusyThreadAsAboutOneCore() async throws {
        let collector = await MetricsActor.run { ProcessCollector() }
        _ = await collector.sample()

        // Burn one core for half a second on a background thread.
        let spinner = Task.detached(priority: .userInitiated) {
            let deadline = Date().addingTimeInterval(0.6)
            var total = 0
            while Date() < deadline { total &+= (0..<2000).reduce(0, &+) }
            return total
        }
        _ = await spinner.value

        let processes = await collector.sample()
        let mine = try #require(processes.first { $0.pid == getpid() })
        let cpu = try #require(mine.cpuUsage)
        print("SELF cpu=\(Format.processCPU(cpu))")

        // Deliberately loose: on a loaded machine the spinner gets less than a
        // whole core, and the bug being guarded against reported ~0.04 here, so
        // a low bar still catches it without flaking.
        #expect(cpu > 0.3, "a thread spinning flat out must read as a large fraction of a core")
        #expect(cpu < Double(ProcessInfo.processInfo.activeProcessorCount))
    }
}
