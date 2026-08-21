import Foundation

/// Rate-limits a progress callback that fires from a background actor.
///
/// The scanners report every few hundred files, and the cleanup engine reports
/// once per item. Each report used to spawn a `Task { @MainActor in … }`, so a
/// deep scan or a run over thousands of cache folders queued hundreds of hops a
/// second onto the main actor to redraw a progress bar that moves a pixel.
///
/// A screen refreshes sixty times a second; anything past that is work nobody
/// can see. `Sendable` and lock-guarded because the callback is not isolated to
/// any one actor.
final class ProgressThrottle: @unchecked Sendable {
    private let interval: Duration
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private var lastPublish: ContinuousClock.Instant?

    init(every interval: Duration = .milliseconds(50)) {
        self.interval = interval
    }

    /// - Returns: whether enough time has passed to be worth drawing again.
    func shouldPublish() -> Bool {
        let now = clock.now
        lock.lock()
        defer { lock.unlock() }
        if let lastPublish, now - lastPublish < interval { return false }
        lastPublish = now
        return true
    }

    /// Lets the next report through whatever the clock says. Used for the final
    /// one, which must land however soon it follows its predecessor.
    func reset() {
        lock.lock()
        lastPublish = nil
        lock.unlock()
    }
}
