import Foundation

// MARK: - CPU

public struct LoadAverage: Sendable, Equatable {
    public let oneMinute: Double
    public let fiveMinutes: Double
    public let fifteenMinutes: Double

    public init(oneMinute: Double, fiveMinutes: Double, fifteenMinutes: Double) {
        self.oneMinute = oneMinute
        self.fiveMinutes = fiveMinutes
        self.fifteenMinutes = fifteenMinutes
    }
}

/// Fractions in 0...1, measured over the interval between two samples.
public struct CPUStats: Sendable, Equatable {
    public let user: Double
    public let system: Double
    public let idle: Double
    public let niceTime: Double
    public let perCore: [Double]
    public let loadAverage: LoadAverage
    public let coreCount: Int
    /// Live task and thread totals, the same figures Activity Monitor shows.
    public let taskCount: Int?
    public let threadCount: Int?

    public var usage: Double { min(1, max(0, user + system + niceTime)) }

    public init(user: Double, system: Double, idle: Double, niceTime: Double,
                perCore: [Double], loadAverage: LoadAverage, coreCount: Int,
                taskCount: Int? = nil, threadCount: Int? = nil) {
        self.user = user
        self.system = system
        self.idle = idle
        self.niceTime = niceTime
        self.perCore = perCore
        self.loadAverage = loadAverage
        self.coreCount = coreCount
        self.taskCount = taskCount
        self.threadCount = threadCount
    }
}

// MARK: - Memory

public enum MemoryPressure: Int, Sendable, Comparable, CaseIterable {
    case low = 1
    case moderate = 2
    case high = 4

    public static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .low: "Low"
        case .moderate: "Moderate"
        case .high: "High"
        }
    }
}

/// macOS memory semantics, not "total minus free".
///
/// `used` mirrors Activity Monitor's *Memory Used*: application memory plus
/// wired plus compressed. File-backed pages that the kernel can evict without
/// cost are reported separately as `cached` and are deliberately not counted as
/// used — that is what makes a healthy Mac look "full" in naive monitors.
public struct MemoryStats: Sendable, Equatable {
    public let total: UInt64
    public let app: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let cached: UInt64
    public let free: UInt64
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    public let pressure: MemoryPressure
    /// Bytes per second moving between RAM and the swap file. Sustained
    /// non-zero values are what actually makes a machine feel slow — far more
    /// so than a high "used" figure.
    public let swapInRate: Double
    public let swapOutRate: Double
    /// Pages per second faulted in from, or written out to, disk.
    public let pageInRate: Double
    public let pageOutRate: Double
    /// How much the compressor is saving, e.g. 5.2 means the compressed pages
    /// would occupy 5.2x as much RAM uncompressed.
    public let compressionRatio: Double

    public var used: UInt64 { app &+ wired &+ compressed }
    public var available: UInt64 { total > used ? total - used : 0 }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

    public init(total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64,
                cached: UInt64, free: UInt64, swapUsed: UInt64, swapTotal: UInt64,
                pressure: MemoryPressure, swapInRate: Double = 0, swapOutRate: Double = 0,
                pageInRate: Double = 0, pageOutRate: Double = 0, compressionRatio: Double = 0) {
        self.total = total
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.free = free
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
        self.swapInRate = swapInRate
        self.swapOutRate = swapOutRate
        self.pageInRate = pageInRate
        self.pageOutRate = pageOutRate
        self.compressionRatio = compressionRatio
    }
}

// MARK: - Disk

public struct VolumeStats: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let url: URL
    public let total: Int64
    /// `volumeAvailableCapacityForImportantUsage`: what the user can actually
    /// reclaim, i.e. free space plus purgeable space.
    public let available: Int64
    public let isInternal: Bool
    public let isRemovable: Bool
    public let fileSystem: String?
    /// Space macOS can reclaim on demand — the gap between plain free space and
    /// what it reports as available. Worth showing, because it explains why
    /// Finder and `df` disagree.
    public let purgeable: Int64

    public var used: Int64 { max(0, total - available) }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

    public init(id: String, name: String, url: URL, total: Int64, available: Int64,
                isInternal: Bool, isRemovable: Bool, fileSystem: String?, purgeable: Int64 = 0) {
        self.id = id
        self.name = name
        self.url = url
        self.total = total
        self.available = available
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.fileSystem = fileSystem
        self.purgeable = purgeable
    }
}

public struct DiskStats: Sendable, Equatable {
    public let volumes: [VolumeStats]
    public let readThroughput: Double
    public let writeThroughput: Double
    /// I/O operations per second, across every block device.
    public let readOperations: Double
    public let writeOperations: Double
    /// Totals since monitoring started, not since boot.
    public let sessionRead: UInt64
    public let sessionWritten: UInt64

    public var primary: VolumeStats? { volumes.first(where: \.isInternal) ?? volumes.first }

    public init(volumes: [VolumeStats], readThroughput: Double, writeThroughput: Double,
                readOperations: Double = 0, writeOperations: Double = 0,
                sessionRead: UInt64 = 0, sessionWritten: UInt64 = 0) {
        self.volumes = volumes
        self.readThroughput = readThroughput
        self.writeThroughput = writeThroughput
        self.readOperations = readOperations
        self.writeOperations = writeOperations
        self.sessionRead = sessionRead
        self.sessionWritten = sessionWritten
    }
}

// MARK: - Battery

public enum PowerSource: String, Sendable {
    case battery = "Battery"
    case acPower = "Power Adapter"
    case unknown = "Unknown"
}

/// What the battery is actually doing.
///
/// "Time remaining" only means something while discharging. On mains power there
/// is nothing to count down to, and a Mac held at 80 % by optimised charging is
/// neither charging nor draining — showing "Calculating…" there suggests the app
/// is working on an answer that will never arrive.
public enum BatteryActivity: Sendable, Equatable {
    case charging(minutesToFull: Int?)
    case discharging(minutesRemaining: Int?)
    case pluggedInNotCharging
}

public struct BatteryStats: Sendable, Equatable {
    public let charge: Double
    public let isCharging: Bool
    public let isCharged: Bool
    public let powerSource: PowerSource
    public let cycleCount: Int?
    /// Nominal capacity relative to design capacity, when the SMC reports both.
    public let healthFraction: Double?
    public let conditionLabel: String?
    /// Only populated when macOS considers its own estimate settled.
    public let timeRemainingMinutes: Int?
    public let voltage: Double?
    /// Signed: negative while discharging, positive while charging.
    public let amperage: Double?
    /// Instantaneous power in watts, the number that answers "what is this
    /// costing me right now".
    public let powerDraw: Double?
    public let currentCapacity: Int?
    public let designCapacity: Int?
    public let adapterName: String?
    public let adapterWatts: Int?
    public let isLowPowerMode: Bool

    public var activity: BatteryActivity {
        if isCharging { return .charging(minutesToFull: timeRemainingMinutes) }
        if powerSource == .acPower || isCharged { return .pluggedInNotCharging }
        return .discharging(minutesRemaining: timeRemainingMinutes)
    }

    /// One line describing the state, used everywhere the battery appears so
    /// the menu bar, the dashboard and the detail page cannot disagree.
    public var statusDescription: String {
        switch activity {
        case .charging(let minutes):
            minutes.map { "Full in \(Format.duration($0))" } ?? "Charging"
        case .discharging(let minutes):
            minutes.map { "\(Format.duration($0)) left" } ?? "Estimating…"
        case .pluggedInNotCharging:
            isCharged ? "Fully charged" : "Not charging"
        }
    }

    public init(charge: Double, isCharging: Bool, isCharged: Bool, powerSource: PowerSource,
                cycleCount: Int?, healthFraction: Double?, conditionLabel: String?,
                timeRemainingMinutes: Int?, voltage: Double? = nil, amperage: Double? = nil,
                powerDraw: Double? = nil, currentCapacity: Int? = nil, designCapacity: Int? = nil,
                adapterName: String? = nil, adapterWatts: Int? = nil, isLowPowerMode: Bool = false) {
        self.charge = charge
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.powerSource = powerSource
        self.cycleCount = cycleCount
        self.healthFraction = healthFraction
        self.conditionLabel = conditionLabel
        self.timeRemainingMinutes = timeRemainingMinutes
        self.voltage = voltage
        self.amperage = amperage
        self.powerDraw = powerDraw
        self.currentCapacity = currentCapacity
        self.designCapacity = designCapacity
        self.adapterName = adapterName
        self.adapterWatts = adapterWatts
        self.isLowPowerMode = isLowPowerMode
    }
}

// MARK: - Network

public struct NetworkInterfaceStats: Sendable, Equatable, Identifiable {
    public let id: String
    public let download: Double
    public let upload: Double
    public let isPrimary: Bool

    public var name: String { id }

    public init(id: String, download: Double, upload: Double, isPrimary: Bool) {
        self.id = id
        self.download = download
        self.upload = upload
        self.isPrimary = isPrimary
    }
}

/// Radio conditions for a Wi-Fi link.
///
/// The network name is deliberately absent: macOS now gates the SSID behind
/// Location Services, and asking for a location permission to display one label
/// is not a trade this app makes. Everything here needs no permission at all.
public struct WiFiSignal: Sendable, Equatable {
    /// The joined network's name, which macOS releases only once Location has
    /// been granted. `nil` otherwise, and the interface says why.
    public let networkName: String?
    /// Received signal strength in dBm; roughly −30 (excellent) to −90 (unusable).
    public let rssi: Int
    /// Noise floor in dBm.
    public let noise: Int
    /// Negotiated transmit rate in Mbps.
    public let transmitRate: Double
    public let channel: Int
    public let band: String
    public let channelWidth: Int

    /// Signal-to-noise ratio in dB — a better predictor of a usable link than
    /// signal strength alone, because a strong signal in a noisy room is not
    /// a good link.
    public var signalToNoise: Int { rssi - noise }

    /// Quality expressed the way a person would judge it.
    public var quality: String {
        switch rssi {
        case (-60)...: "Excellent"
        case (-70)..<(-60): "Good"
        case (-80)..<(-70): "Fair"
        default: "Weak"
        }
    }

    /// 0...1, for a meter. Maps the useful part of the dBm range.
    public var strengthFraction: Double {
        min(1, max(0, Double(rssi + 90) / 55))
    }

    public init(networkName: String? = nil, rssi: Int, noise: Int, transmitRate: Double,
                channel: Int, band: String, channelWidth: Int) {
        self.networkName = networkName
        self.rssi = rssi
        self.noise = noise
        self.transmitRate = transmitRate
        self.channel = channel
        self.band = band
        self.channelWidth = channelWidth
    }
}

public struct NetworkStats: Sendable, Equatable {
    public let interfaceName: String?
    public let interfaceKind: String
    public let downloadThroughput: Double
    public let uploadThroughput: Double
    public let totalReceived: UInt64
    public let totalSent: UInt64
    public let isConnected: Bool
    /// Addresses of the primary interface, link-local IPv6 omitted.
    public let addresses: [String]
    public let packetsInRate: Double
    public let packetsOutRate: Double
    public let errorsIn: UInt64
    public let errorsOut: UInt64
    public let drops: UInt64
    /// Negotiated link rate in bits per second; 0 when the driver does not
    /// report one.
    public let linkSpeed: UInt64
    public let mtu: UInt32
    public let interfaces: [NetworkInterfaceStats]
    /// Default gateway for the primary service.
    public let router: String?
    public let dnsServers: [String]
    public let wifi: WiFiSignal?
    /// A tunnel interface is carrying the traffic.
    public let usesVPN: Bool
    /// macOS considers the link metered, or is asking apps to go easy on it.
    public let isExpensive: Bool
    public let isConstrained: Bool
    /// Interface counters are cumulative since the interface came up, which in
    /// practice means since boot — unlike `totalReceived`, which counts only
    /// what this app has watched.
    public let lifetimeReceived: UInt64
    public let lifetimeSent: UInt64

    public init(interfaceName: String?, interfaceKind: String, downloadThroughput: Double,
                uploadThroughput: Double, totalReceived: UInt64, totalSent: UInt64,
                isConnected: Bool, addresses: [String] = [], packetsInRate: Double = 0,
                packetsOutRate: Double = 0, errorsIn: UInt64 = 0, errorsOut: UInt64 = 0,
                drops: UInt64 = 0, linkSpeed: UInt64 = 0, mtu: UInt32 = 0,
                interfaces: [NetworkInterfaceStats] = [], router: String? = nil,
                dnsServers: [String] = [], wifi: WiFiSignal? = nil, usesVPN: Bool = false,
                isExpensive: Bool = false, isConstrained: Bool = false,
                lifetimeReceived: UInt64 = 0, lifetimeSent: UInt64 = 0) {
        self.interfaceName = interfaceName
        self.interfaceKind = interfaceKind
        self.downloadThroughput = downloadThroughput
        self.uploadThroughput = uploadThroughput
        self.totalReceived = totalReceived
        self.totalSent = totalSent
        self.isConnected = isConnected
        self.addresses = addresses
        self.packetsInRate = packetsInRate
        self.packetsOutRate = packetsOutRate
        self.errorsIn = errorsIn
        self.errorsOut = errorsOut
        self.drops = drops
        self.linkSpeed = linkSpeed
        self.mtu = mtu
        self.interfaces = interfaces
        self.router = router
        self.dnsServers = dnsServers
        self.wifi = wifi
        self.usesVPN = usesVPN
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.lifetimeReceived = lifetimeReceived
        self.lifetimeSent = lifetimeSent
    }
}

// MARK: - Processes

public struct ProcessSample: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case application = "App"
        case background = "Background"
        case system = "System"
    }

    public let id: pid_t
    public let name: String
    public let kind: Kind
    /// Fraction of one core; 1.6 means 160% in Activity Monitor terms.
    /// `nil` when the kernel denied access (typically another user's process).
    public let cpuUsage: Double?
    public let memoryFootprint: UInt64?
    public let isResponding: Bool

    public var pid: pid_t { id }

    /// Sort keys for a table's column headers.
    ///
    /// `Table` needs one `Comparable` value per sortable column, and `Optional`
    /// is not `Comparable`. These exist only to make the headers clickable: the
    /// ordering itself still goes through `ProcessSorter`, which is what keeps
    /// processes the kernel refused to describe at the bottom whichever way the
    /// column points.
    public var cpuSortValue: Double { cpuUsage ?? -1 }
    public var memorySortValue: UInt64 { memoryFootprint ?? 0 }

    public init(id: pid_t, name: String, kind: Kind, cpuUsage: Double?,
                memoryFootprint: UInt64?, isResponding: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.cpuUsage = cpuUsage
        self.memoryFootprint = memoryFootprint
        self.isResponding = isResponding
    }
}

public enum ProcessSortKey: String, Sendable, CaseIterable, Identifiable {
    case cpu, memory, name, pid
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .name: "Name"
        case .pid: "PID"
        }
    }
}

public enum ProcessSorter {
    /// Natural order is the one a user expects when picking a column: CPU and
    /// memory descending (biggest offender first), name and PID ascending.
    /// `reversed` flips it. Processes whose stats the kernel refused to share
    /// always sort last, so an unreadable root daemon never squats at the top.
    public static func sort(_ processes: [ProcessSample], by key: ProcessSortKey,
                            reversed: Bool = false) -> [ProcessSample] {
        processes.sorted { lhs, rhs in
            switch key {
            case .cpu:
                return unreadableLast(lhs, rhs, \.cpuUsage, reversed: reversed)
            case .memory:
                return unreadableLast(lhs, rhs, \.memoryFootprint, reversed: reversed)
            case .name:
                return reversed ? nameOrder(rhs, lhs) : nameOrder(lhs, rhs)
            case .pid:
                return reversed ? lhs.id > rhs.id : lhs.id < rhs.id
            }
        }
    }

    /// Orders on an optional figure, keeping the rows that have none at the
    /// bottom **whichever way the readable ones are pointing**.
    ///
    /// This used to be done by sorting once and reversing the whole array,
    /// which also flipped the unreadable rows to the top — so asking for
    /// "quietest first" opened with a screenful of dashes. The doc above says
    /// they always sort last; now they do.
    private static func unreadableLast<Value: Comparable>(
        _ lhs: ProcessSample, _ rhs: ProcessSample,
        _ figure: KeyPath<ProcessSample, Value?>, reversed: Bool
    ) -> Bool {
        let a = lhs[keyPath: figure], b = rhs[keyPath: figure]
        if a == nil && b == nil { return nameOrder(lhs, rhs) }
        guard let a else { return false }
        guard let b else { return true }
        if a == b { return nameOrder(lhs, rhs) }
        return reversed ? a < b : a > b
    }

    private static func nameOrder(_ lhs: ProcessSample, _ rhs: ProcessSample) -> Bool {
        let result = lhs.name.localizedStandardCompare(rhs.name)
        return result == .orderedSame ? lhs.id < rhs.id : result == .orderedAscending
    }
}
