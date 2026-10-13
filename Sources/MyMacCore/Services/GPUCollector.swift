import Foundation
import IOKit

/// GPU utilisation from the `IOAccelerator` entries in the IORegistry, which
/// need no permission and no subprocess.
///
/// The statistics dictionary is vendor-specific. Apple Silicon reports
/// `Device Utilization %`; some Intel and AMD drivers report `GPU Activity(%)`
/// instead. Each key is tried in order, and an accelerator that reports none of
/// them is left out rather than shown as idle.
public enum GPUCollector {
    private static let utilizationKeys = ["Device Utilization %", "GPU Activity(%)"]
    private static let memoryKeys = ["In use system memory", "vramUsedBytes"]

    /// Every GPU the registry describes, in registry order.
    public static func readAll() -> [GPUStats] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [GPUStats] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  let statistics = properties["PerformanceStatistics"] as? [String: Any]
            else { continue }
            if let gpu = parse(properties: properties, statistics: statistics,
                               fallbackName: "GPU \(result.count + 1)") {
                result.append(gpu)
            }
        }
        return result
    }

    static func parse(properties: [String: Any], statistics: [String: Any],
                      fallbackName: String) -> GPUStats? {
        guard let percent = utilizationKeys.lazy.compactMap({ number(statistics[$0]) }).first else { return nil }
        let name = (properties["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        let memory = memoryKeys.lazy.compactMap { number(statistics[$0]) }.first
        return GPUStats(name: name,
                        utilization: min(1, max(0, percent / 100)),
                        memoryInUse: memory.map { UInt64(max(0, $0)) })
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
