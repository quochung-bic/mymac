import Foundation
import IOKit
import IOKit.ps

/// Battery state from the IOPowerSources API, enriched with the SMC's own
/// health counters from the `AppleSmartBattery` IORegistry node.
///
/// Desktop Macs simply have no power source of type battery, so `sample()`
/// returns `nil` and every battery UI is hidden rather than faked.
@MetricsActor
public final class BatteryCollector {
    /// Constructible from anywhere; every method that touches state is isolated.
    public nonisolated init() {}

    public func sample() -> BatteryStats? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let powerSource: PowerSource
        switch providing {
        case kIOPSBatteryPowerValue: powerSource = .battery
        case kIOPSACPowerValue: powerSource = .acPower
        default: powerSource = .unknown
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }

            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let isCharged = description[kIOPSIsChargedKey] as? Bool ?? false

            // macOS reports -1 while it is still calibrating its estimate.
            // Showing "calculating" is more honest than showing a wrong number.
            let rawMinutes = isCharging
                ? description[kIOPSTimeToFullChargeKey] as? Int
                : description[kIOPSTimeToEmptyKey] as? Int
            let minutes = (rawMinutes ?? -1) > 0 ? rawMinutes : nil

            let smart = Self.smartBatteryProperties()
            let adapter = Self.powerAdapter()
            return BatteryStats(
                charge: min(1, Double(current) / Double(maximum)),
                isCharging: isCharging,
                isCharged: isCharged,
                powerSource: powerSource,
                cycleCount: smart.cycleCount,
                healthFraction: smart.health,
                conditionLabel: description[kIOPSBatteryHealthKey] as? String,
                timeRemainingMinutes: minutes,
                voltage: smart.voltage,
                amperage: smart.amperage,
                powerDraw: smart.power,
                currentCapacity: smart.currentCapacity,
                designCapacity: smart.designCapacity,
                adapterName: adapter?.name,
                adapterWatts: adapter?.watts,
                isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }
        return nil
    }

    /// Internal so the zero-versus-missing distinction can be tested without
    /// a machine in a particular power state.
    struct SmartBattery {
        var cycleCount: Int?
        var health: Double?
        var voltage: Double?
        var amperage: Double?
        var currentCapacity: Int?
        var designCapacity: Int?

        /// Watts, from the SMC's own volts and amps. Sign is dropped: the
        /// interesting quantity is magnitude, and the direction is already
        /// conveyed by the charging state.
        ///
        /// Zero is an answer, not a missing one. On mains power without
        /// charging nothing flows in or out of the battery, and that is what
        /// both the interface and the README say the figure will read. Filtering
        /// small values to `nil` made it show "—" instead, which claims the
        /// reading is unavailable.
        var power: Double? {
            guard let voltage, let amperage else { return nil }
            return abs(voltage * amperage)
        }
    }

    /// `AppleSmartBattery` exposes the raw SMC counters. Key names have drifted
    /// across hardware generations, so every read is optional and the whole
    /// block degrades to `nil` on unsupported machines.
    private static func smartBatteryProperties() -> SmartBattery {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return SmartBattery() }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return SmartBattery() }

        var result = SmartBattery()
        result.cycleCount = properties["CycleCount"] as? Int

        // Millivolts and milliamps in the registry; volts and amps here.
        if let millivolts = properties["Voltage"] as? Int, millivolts > 0 {
            result.voltage = Double(millivolts) / 1000
        }
        // "InstantAmperage" tracks the present draw; "Amperage" is averaged and
        // sits at zero on a charged machine on mains power.
        let milliamps = (properties["InstantAmperage"] as? Int).flatMap { $0 != 0 ? $0 : nil }
            ?? (properties["Amperage"] as? Int)
        if let milliamps { result.amperage = Double(milliamps) / 1000 }

        result.currentCapacity = properties["AppleRawCurrentCapacity"] as? Int
        result.designCapacity = properties["DesignCapacity"] as? Int

        let design = properties["DesignCapacity"] as? Int
        // Apple Silicon reports "NominalChargeCapacity"; Intel used "AppleRawMaxCapacity".
        let nominal = (properties["NominalChargeCapacity"] as? Int)
            ?? (properties["AppleRawMaxCapacity"] as? Int)
        if let design, let nominal, design > 0 {
            result.health = min(1, Double(nominal) / Double(design))
        }

        // Battery temperature is deliberately not surfaced: the unit of the
        // SMC "Temperature" key differs between Intel and Apple Silicon, and a
        // wrong reading is worse than no reading.
        return result
    }

    private struct Adapter {
        var name: String?
        var watts: Int?
    }

    /// What is plugged in. Knowing the adapter is rated 67 W explains a slow
    /// charge far better than any progress bar can.
    private static func powerAdapter() -> Adapter? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        let name = details["Name"] as? String ?? details["Description"] as? String
        let watts = details["Watts"] as? Int
        guard name != nil || watts != nil else { return nil }
        return Adapter(name: name, watts: watts)
    }
}
