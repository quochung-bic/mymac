import Foundation

public struct GPUStats: Sendable, Equatable {
    public let name: String
    /// 0...1.
    public let utilization: Double
    /// Memory the driver reports in use; `nil` when it does not say.
    public let memoryInUse: UInt64?

    public init(name: String, utilization: Double, memoryInUse: UInt64?) {
        self.name = name
        self.utilization = utilization
        self.memoryInUse = memoryInUse
    }
}
