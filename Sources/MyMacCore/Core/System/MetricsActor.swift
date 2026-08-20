/// All metric collectors run on this single serial executor.
///
/// Sampling is cheap but stateful: every collector keeps the previous kernel
/// counters in order to compute a delta. Confining them to one global actor
/// keeps that state race-free without one lock (or one actor) per collector,
/// and guarantees none of it ever touches the main actor.
@globalActor
public actor MetricsActor {
    public static let shared = MetricsActor()
}

extension MetricsActor {
    /// Hops onto the metrics actor to build or drive actor-isolated collectors.
    @MetricsActor
    public static func run<T>(_ body: @MetricsActor () throws -> T) async rethrows -> T {
        try body()
    }
}
