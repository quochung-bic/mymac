import Foundation
import Testing
@testable import MyMacCore

/// Sampling has to be cheap enough to run every second without being noticeable.
/// These are diagnostics as much as assertions.
@Suite("Sampling cost", .serialized)
struct SamplingCostTests {
    private func time(_ label: String, iterations: Int = 20, _ body: () -> Void) -> Double {
        body()
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<iterations { body() }
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let perCall = seconds / Double(iterations) * 1000
        print(String(format: "COST %-16s %8.3f ms/call", (label as NSString).utf8String!, perCall))
        return perCall
    }

    @Test func fastSampleIsCheap() async {
        let monitor = SystemMonitor()
        await monitor.start()
        defer { Task { await monitor.stop() } }

        let cpu = await MetricsActor.run { CPUCollector() }
        let memory = await MetricsActor.run { MemoryCollector() }
        let network = await MetricsActor.run { NetworkCollector() }

        let cpuCost = await MetricsActor.run { time("cpu") { _ = cpu.sample() } }
        let memoryCost = await MetricsActor.run { time("memory") { _ = memory.sample() } }
        let networkCost = await MetricsActor.run { time("network") { _ = network.sample() } }

        #expect(cpuCost < 5)
        #expect(memoryCost < 5)
        #expect(networkCost < 5)
    }

    @Test func slowSampleIsAcceptable() async {
        let disk = await MetricsActor.run { DiskCollector() }
        let battery = await MetricsActor.run { BatteryCollector() }

        let diskCost = await MetricsActor.run { time("disk", iterations: 5) { _ = disk.sample() } }
        let batteryCost = await MetricsActor.run { time("battery", iterations: 5) { _ = battery.sample() } }

        #expect(diskCost < 250)
        #expect(batteryCost < 50)
    }

    @Test func processSampleIsBoundedEnoughForTwoSecondUpdates() async {
        let processes = await MetricsActor.run { ProcessCollector() }
        let cost = await MetricsActor.run { time("processes", iterations: 5) { _ = processes.sample() } }
        #expect(cost < 400)
    }
}
