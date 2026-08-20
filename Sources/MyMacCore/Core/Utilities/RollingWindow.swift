/// Fixed-capacity ring buffer used for the in-memory chart history.
///
/// Nothing is persisted: keeping a few hundred `Double`s per metric costs a few
/// kilobytes and avoids any background database writes.
public struct RollingWindow<Element>: Sendable where Element: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Elements in chronological order (oldest first).
    public var values: [Element] {
        guard storage.count == capacity else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var last: Element? { storage.isEmpty ? nil : storage[(head + storage.count - 1) % storage.count] }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}
