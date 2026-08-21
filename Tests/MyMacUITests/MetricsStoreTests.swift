import Foundation
import MyMacCore
import Testing
@testable import MyMacUI

/// The app-layer half of P1-1 in the 2026-08-20 audit.
///
/// `MetricsStore` is what made the network fault reachable: it stops sampling
/// outright when the last scope goes away and starts again when a new one
/// arrives. That cycle is a supported, documented state — "with both readouts
/// off … sampling stops entirely" — not an edge case, so it is pinned here.
@MainActor
@Suite("Metrics store scopes", .serialized)
struct MetricsStoreScopeTests {
    @Test func samplingStartsWithTheFirstScopeAndStopsWithTheLast() async {
        let store = MetricsStore()
        #expect(store.isRunning == false, "nothing on screen, nothing sampled")

        store.retain(.menuBar)
        #expect(store.isRunning)

        store.release(.menuBar)
        #expect(store.isRunning == false)
    }

    /// The cycle that broke network monitoring: everything released, then
    /// something asks again.
    @Test func samplingRestartsAfterEverythingHasBeenReleased() async {
        let store = MetricsStore()
        store.retain(.menuBar)
        store.release(.menuBar)
        #expect(store.isRunning == false)

        store.retain(.detail)
        #expect(store.isRunning, "a scope taken after a full stop must start sampling again")

        store.release(.detail)
    }

    @Test func scopesAreCountedSoOverlappingViewsDoNotStopEachOther() async {
        let store = MetricsStore()
        store.retain(.detail)
        store.retain(.detail)

        store.release(.detail)
        #expect(store.isRunning, "one of two holders letting go is not the last one")

        store.release(.detail)
        #expect(store.isRunning == false)
    }

    @Test func releasingAnUnheldScopeChangesNothing() async {
        let store = MetricsStore()
        store.retain(.menuBar)

        store.release(.processes)
        #expect(store.isRunning, "releasing something never taken must not stop sampling")

        store.release(.menuBar)
        #expect(store.isRunning == false)
    }

    /// A process list nobody is looking at should not keep stale rows around,
    /// and a recycled PID must not inherit an old process's alert history.
    @Test func lettingGoOfTheProcessScopeDiscardsItsData() async {
        let store = MetricsStore()
        store.retain(.processes)
        store.release(.processes)

        #expect(store.processes.isEmpty)
        #expect(store.alerts.isEmpty)
    }

    @Test func theMenuBarScopeFollowsTheSettingRatherThanTheView() async {
        let store = MetricsStore()

        store.setMenuBarActive(true)
        #expect(store.isRunning)

        // Idempotent: the status item's view is destroyed and recreated by
        // macOS whenever the menu bar hides, and that must not release it.
        store.setMenuBarActive(true)
        store.setMenuBarActive(false)
        #expect(store.isRunning == false)
    }
}
