import Foundation
import Testing
@testable import MyMacCore

@Suite("GPU statistics")
struct GPUCollectorTests {
    @Test func readsAnAppleSiliconAccelerator() throws {
        let gpu = try #require(GPUCollector.parse(
            properties: ["model": "Apple M2", "IOClass": "AGXAcceleratorG14G"],
            statistics: ["Device Utilization %": 26, "Renderer Utilization %": 25,
                         "Tiler Utilization %": 27, "In use system memory": 1_076_051_968],
            fallbackName: "GPU 1"))
        #expect(gpu.name == "Apple M2")
        #expect(gpu.utilization == 0.26)
        #expect(gpu.memoryInUse == 1_076_051_968)
    }

    @Test func fallsBackToTheOlderIntelKeyAndDiscreteMemory() throws {
        let gpu = try #require(GPUCollector.parse(
            properties: ["model": "AMD Radeon Pro 5500M"],
            statistics: ["GPU Activity(%)": 40, "vramUsedBytes": 2_000_000_000],
            fallbackName: "GPU 1"))
        #expect(gpu.utilization == 0.4)
        #expect(gpu.memoryInUse == 2_000_000_000)
    }

    @Test func prefersTheDeviceFigureWhenBothAreReported() throws {
        let gpu = try #require(GPUCollector.parse(
            properties: [:],
            statistics: ["Device Utilization %": 10, "GPU Activity(%)": 90],
            fallbackName: "GPU 1"))
        #expect(gpu.utilization == 0.1)
        #expect(gpu.name == "GPU 1", "no model reported, so the fallback names it")
    }

    @Test func clampsAnOutOfRangeReading() throws {
        let gpu = try #require(GPUCollector.parse(
            properties: [:], statistics: ["Device Utilization %": 140], fallbackName: "GPU"))
        #expect(gpu.utilization == 1)
    }

    @Test func anAcceleratorWithNoUtilisationIsSkippedNotShownAsZero() {
        #expect(GPUCollector.parse(properties: ["model": "X"],
                                   statistics: ["Alloc system memory": 1], fallbackName: "GPU") == nil)
        #expect(GPUCollector.parse(properties: [:], statistics: [:], fallbackName: "GPU") == nil)
    }

    @Test func liveCollectorNeverReturnsOutOfRangeValues() {
        for gpu in GPUCollector.readAll() {
            print("GPU \(gpu.name) \(Int(gpu.utilization * 100))% mem=\(gpu.memoryInUse.map(Format.bytes) ?? "-")")
            #expect((0...1).contains(gpu.utilization))
            #expect(!gpu.name.isEmpty)
        }
    }
}
