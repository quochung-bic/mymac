import Darwin
import Foundation
import IOKit
import IOKit.storage

/// Volume capacity from `URLResourceValues`, plus block-device throughput from
/// the IORegistry.
///
/// Capacity is deliberately *not* computed by walking the filesystem: the
/// resource keys answer the same question in constant time.
@MetricsActor
public final class DiskCollector {
    private struct IOCounters {
        var read: UInt64 = 0
        var written: UInt64 = 0
        var readOperations: UInt64 = 0
        var writeOperations: UInt64 = 0
    }

    private var previousIO: IOCounters?
    private var sessionRead: UInt64 = 0
    private var sessionWritten: UInt64 = 0
    private var previousIOTimestamp: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    private static let resourceKeys: Set<URLResourceKey> = [
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsInternalKey,
        .volumeIsRemovableKey,
        .volumeIsBrowsableKey,
        .volumeIsLocalKey,
        .volumeAvailableCapacityKey,
        .volumeIsEjectableKey,
        .volumeUUIDStringKey,
        .volumeLocalizedFormatDescriptionKey,
    ]

    /// Constructible from anywhere; every method that touches state is isolated.
    public nonisolated init() {}

    public func sample() -> DiskStats {
        let counters = Self.readBlockStorageCounters()
        var read = 0.0
        var write = 0.0
        var readOperations = 0.0
        var writeOperations = 0.0
        let now = clock.now
        if let counters, let previous = previousIO, let previousTimestamp = previousIOTimestamp {
            let elapsed = Double((now - previousTimestamp).components.seconds)
                + Double((now - previousTimestamp).components.attoseconds) / 1e18
            if elapsed > 0.05 {
                let deltaRead = counters.read &- previous.read
                let deltaWrite = counters.written &- previous.written
                read = Double(deltaRead) / elapsed
                write = Double(deltaWrite) / elapsed
                readOperations = Double(counters.readOperations &- previous.readOperations) / elapsed
                writeOperations = Double(counters.writeOperations &- previous.writeOperations) / elapsed
                sessionRead &+= deltaRead
                sessionWritten &+= deltaWrite
            }
        }
        if let counters {
            previousIO = counters
            previousIOTimestamp = now
        }

        return DiskStats(volumes: Self.volumes(),
                         readThroughput: max(0, read),
                         writeThroughput: max(0, write),
                         readOperations: max(0, readOperations),
                         writeOperations: max(0, writeOperations),
                         sessionRead: sessionRead,
                         sessionWritten: sessionWritten)
    }

    static func volumes() -> [VolumeStats] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(resourceKeys),
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url -> VolumeStats? in
            // A volume can vanish between enumeration and inspection; that is a
            // normal event on a Mac with external disks, not an error.
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.volumeIsBrowsable ?? true,
                  // Network shares report capacity of the far end, which is not
                  // this Mac's storage; showing it would be misleading.
                  values.volumeIsLocal ?? true,
                  let total = values.volumeTotalCapacity, total > 0
            else { return nil }

            let available = values.volumeAvailableCapacityForImportantUsage ?? 0
            // The gap between plain free space and what macOS calls available
            // is content it can purge on demand — caches, local snapshots.
            let plainFree = Int64(values.volumeAvailableCapacity ?? 0)
            let purgeable = max(0, min(Int64(total), available) - plainFree)
            return VolumeStats(
                id: values.volumeUUIDString ?? url.path,
                name: values.volumeName ?? url.lastPathComponent,
                url: url,
                total: Int64(total),
                available: min(Int64(total), max(0, available)),
                isInternal: values.volumeIsInternal ?? false,
                isRemovable: (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false),
                fileSystem: values.volumeLocalizedFormatDescription,
                purgeable: purgeable
            )
        }
        .sorted { lhs, rhs in
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Sums the byte counters every `IOBlockStorageDriver` publishes. This is
    /// the same source `iostat` reads, without spawning a process each second.
    private static func readBlockStorageCounters() -> IOCounters? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var counters = IOCounters()
        var found = false
        while case let drive = IOIteratorNext(iterator), drive != 0 {
            defer { IOObjectRelease(drive) }
            guard let properties = IORegistryEntryCreateCFProperty(
                drive, kIOBlockStorageDriverStatisticsKey as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            found = true
            if let read = properties[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber {
                counters.read &+= read.uint64Value
            }
            if let written = properties[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber {
                counters.written &+= written.uint64Value
            }
            if let reads = properties[kIOBlockStorageDriverStatisticsReadsKey] as? NSNumber {
                counters.readOperations &+= reads.uint64Value
            }
            if let writes = properties[kIOBlockStorageDriverStatisticsWritesKey] as? NSNumber {
                counters.writeOperations &+= writes.uint64Value
            }
        }
        return found ? counters : nil
    }
}
