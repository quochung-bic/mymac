import Foundation
import Testing
@testable import MyMacCore

/// Regression cover for the two network faults found in the 2026-08-20 audit.
@Suite("Network interface accounting")
struct NetworkInterfaceAccountingTests {
    @Test func physicalInterfacesCountTowardTheTotal() {
        for name in ["en0", "en1", "anpi0"] {
            #expect(NetworkCollector.countsTowardTotal(name), "\(name) carries real traffic")
        }
    }

    /// A packet crossing a VPN is counted by the kernel twice: once on the
    /// tunnel and again on the physical device underneath it. Adding both
    /// reported roughly double the traffic that actually moved.
    @Test func tunnelsAndBridgesAreLeftOutOfTheTotal() {
        for name in ["utun0", "utun5", "ipsec0", "ppp0", "bridge0", "gif0", "stf0", "ap1"] {
            #expect(!NetworkCollector.countsTowardTotal(name),
                    "\(name) is layered on another interface and would double-count")
        }
    }

    @Test func loopbackAndPeerToPeerRadiosAreExcludedEverywhere() {
        for name in ["lo0", "awdl0", "llw0"] {
            #expect(!NetworkCollector.countsTowardTotal(name))
            #expect(!NetworkCollector.isWorthListing(name))
        }
    }

    /// A tunnel is still shown in the per-interface breakdown even though it is
    /// not summed — seeing that a VPN is carrying the traffic is the point.
    @Test func tunnelsStillAppearInThePerInterfaceBreakdown() {
        #expect(NetworkCollector.isWorthListing("utun5"))
        #expect(NetworkCollector.isWorthListing("bridge0"))
    }

    /// `anpi` starts with the same two letters as the Internet Sharing `ap`
    /// interface and must not be caught by the prefix match.
    @Test func prefixMatchingDoesNotCatchUnrelatedNames() {
        #expect(NetworkCollector.countsTowardTotal("anpi0"))
        #expect(!NetworkCollector.countsTowardTotal("ap1"))
    }
}

@Suite("Network monitor lifecycle", .serialized)
struct NetworkMonitorLifecycleTests {
    /// Polls instead of sleeping a fixed amount. `NWPathMonitor` delivers its
    /// first update on its own queue, and under a loaded test run that can take
    /// well past any constant short enough to keep the suite quick.
    private func awaitConnected(_ collector: NetworkCollector,
                                within limit: Duration = .seconds(5)) async -> NetworkStats {
        let deadline = ContinuousClock().now.advanced(by: limit)
        var stats = await collector.sample()
        while !stats.isConnected, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            stats = await collector.sample()
        }
        return stats
    }

    /// `NWPathMonitor` is single-use: once cancelled it never delivers another
    /// update. Reusing one across a stop/start cycle left the collector with a
    /// dead monitor, so it stopped noticing every path change from then on —
    /// Wi-Fi to Ethernet, a VPN coming up, the link dropping.
    ///
    /// Asserted on the monitor itself rather than on the sample, because the
    /// cached path values survive a stop: a dead monitor keeps answering with
    /// the last thing it heard, which is exactly why this looked fine.
    @Test func aStoppedCollectorGetsALiveMonitorWhenRestarted() async throws {
        let collector = await MetricsActor.run { NetworkCollector() }

        await collector.start()
        let before = await awaitConnected(collector)
        try #require(before.isConnected, "this test needs a live connection to mean anything")
        #expect(await collector.isMonitoring)

        await collector.stop()
        #expect(await collector.isMonitoring == false, "stop must release the monitor")

        await collector.start()
        #expect(await collector.isMonitoring,
                "a restarted collector must hold a live monitor, not the cancelled one")

        let after = await awaitConnected(collector)
        #expect(after.isConnected)
        #expect(after.interfaceKind == before.interfaceKind)

        await collector.stop()
    }

    /// Even without an explicit `start()`, a sample re-arms the monitor. This is
    /// what makes a late `stop()` from an already-cancelled sampling loop
    /// self-correcting instead of permanent.
    @Test func aSampleRearmsTheMonitorOnItsOwn() async throws {
        let collector = await MetricsActor.run { NetworkCollector() }
        await collector.stop()

        let stats = await awaitConnected(collector)

        #expect(stats.interfaceName != nil, "sampling must re-arm a stopped monitor")

        await collector.stop()
    }
}
