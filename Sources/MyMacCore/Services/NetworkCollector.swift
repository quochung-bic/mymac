import CoreWLAN
import Darwin
import Foundation
import Network
import SystemConfiguration

/// Interface byte counters from the routing socket, plus the current primary
/// interface from `NWPathMonitor`.
///
/// `NET_RT_IFLIST2` is used rather than `getifaddrs` because it carries
/// `if_data64` — 64-bit counters that do not wrap every few seconds on a fast
/// link. `NWPathMonitor` is event-driven, so knowing which interface is primary
/// costs nothing between changes.
@MetricsActor
public final class NetworkCollector {
    private struct Counters {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var packetsIn: UInt64 = 0
        var packetsOut: UInt64 = 0
        var errorsIn: UInt64 = 0
        var errorsOut: UInt64 = 0
        var drops: UInt64 = 0
        var linkSpeed: UInt64 = 0
        var mtu: UInt32 = 0
    }

    private var previous: [String: Counters] = [:]
    private var previousTimestamp: ContinuousClock.Instant?
    private var sessionReceived: UInt64 = 0
    private var sessionSent: UInt64 = 0
    private var primaryInterface: String?
    /// Addresses cost a `getifaddrs` walk — an order of magnitude more than the
    /// rest of the sample put together — and they change only when the network
    /// does. Cached, and refreshed when the interface changes or every so often.
    private var cachedAddresses: [String] = []
    private var addressInterface: String?
    private var samplesSinceAddressRefresh = 0
    private static let addressRefreshInterval = 15

    /// Router and resolvers come from the system configuration database. They
    /// change only when the network does, so they ride the same slow cadence.
    private var cachedRouter: String?
    private var cachedDNS: [String] = []
    /// CoreWLAN is by far the most expensive thing in a network sample — it
    /// costs four times the rest put together and keeps a chattering XPC
    /// connection to `airportd` alive. So the radio is read only when something
    /// on screen shows it, and then no more than every few seconds.
    private var cachedWiFi: WiFiSignal?
    /// Starts at the threshold so the first request reads the radio.
    private var samplesSinceRadioRefresh = NetworkCollector.radioRefreshInterval
    private nonisolated static let radioRefreshInterval = 5

    private var isExpensive = false
    private var isConstrained = false
    private var usesVPN = false
    private var interfaceKind = "Unknown"
    private var isConnected = false

    private let clock = ContinuousClock()
    /// Created fresh on every start, and released on stop.
    ///
    /// `NWPathMonitor` is single-use: once cancelled it never delivers another
    /// update, so reusing one instance across a stop/start cycle would leave
    /// the primary interface, the connectivity flag and every figure derived
    /// from them frozen for the rest of the process's life.
    private var monitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.mymac.network-path", qos: .utility)

    /// Constructible from anywhere; every method that touches state is isolated.
    public nonisolated init() {}

    public func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { path in
            // Extract plain values on the monitor queue; only `Sendable`
            // primitives cross back onto the metrics actor.
            let satisfied = path.status == .satisfied
            let interface = path.availableInterfaces.first
            let name = interface?.name
            let kind = Self.describe(interface?.type)
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            // A tunnel interface carrying the path means a VPN is in the way,
            // which explains a lot of otherwise puzzling latency.
            let tunnelled = path.availableInterfaces.contains {
                $0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") || $0.name.hasPrefix("ppp")
            }
            Task { @MetricsActor [weak self] in
                self?.apply(interface: name, kind: kind, connected: satisfied,
                            expensive: expensive, constrained: constrained, tunnelled: tunnelled)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    public func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// Whether a live path monitor is attached. Internal so a test can assert
    /// the invariant directly: the cached path values survive a stop, so a
    /// black-box check cannot tell a live monitor from a dead one holding a
    /// stale answer — which is precisely how this fault stayed hidden.
    var isMonitoring: Bool { monitor != nil }

    private func apply(interface: String?, kind: String, connected: Bool,
                       expensive: Bool, constrained: Bool, tunnelled: Bool) {
        primaryInterface = interface
        interfaceKind = kind
        isConnected = connected
        isExpensive = expensive
        isConstrained = constrained
        usesVPN = tunnelled
    }

    /// - Parameter includeRadio: whether anything on screen is showing Wi-Fi
    ///   signal detail. When false the radio is not touched at all.
    public func sample(includeRadio: Bool = false) -> NetworkStats {
        // Re-arm rather than assume. A `stop()` belonging to a sampling loop
        // that has already been cancelled can land after the next loop's
        // `start()`, and the path monitor would then be dead for good. Starting
        // it here makes that self-correcting: at worst one sample carries stale
        // path information instead of every sample from then on.
        start()
        let counters = Self.readInterfaceCounters()
        let now = clock.now
        var download = 0.0
        var upload = 0.0
        var packetsIn = 0.0
        var packetsOut = 0.0
        var active: [NetworkInterfaceStats] = []

        if let previousTimestamp {
            let duration = now - previousTimestamp
            let elapsed = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            if elapsed > 0.05 {
                var deltaReceived: UInt64 = 0
                var deltaSent: UInt64 = 0
                var deltaPacketsIn: UInt64 = 0
                var deltaPacketsOut: UInt64 = 0
                for (name, current) in counters where Self.isWorthListing(name) {
                    guard let old = previous[name] else { continue }
                    // A counter that went backwards means the interface was
                    // torn down and recreated; treat it as no traffic rather
                    // than emit a spike.
                    let received = current.received >= old.received ? current.received - old.received : 0
                    let sent = current.sent >= old.sent ? current.sent - old.sent : 0

                    if Self.countsTowardTotal(name) {
                        deltaReceived &+= received
                        deltaSent &+= sent
                        if current.packetsIn >= old.packetsIn { deltaPacketsIn &+= current.packetsIn - old.packetsIn }
                        if current.packetsOut >= old.packetsOut { deltaPacketsOut &+= current.packetsOut - old.packetsOut }
                    }

                    let interfaceDownload = Double(received) / elapsed
                    let interfaceUpload = Double(sent) / elapsed
                    if interfaceDownload > 0 || interfaceUpload > 0 || name == primaryInterface {
                        active.append(NetworkInterfaceStats(id: name,
                                                            download: interfaceDownload,
                                                            upload: interfaceUpload,
                                                            isPrimary: name == primaryInterface))
                    }
                }
                download = Double(deltaReceived) / elapsed
                upload = Double(deltaSent) / elapsed
                packetsIn = Double(deltaPacketsIn) / elapsed
                packetsOut = Double(deltaPacketsOut) / elapsed
                sessionReceived &+= deltaReceived
                sessionSent &+= deltaSent
            }
        }

        previous = counters
        previousTimestamp = now

        let primary = primaryInterface.flatMap { counters[$0] }
        return NetworkStats(
            interfaceName: primaryInterface,
            interfaceKind: interfaceKind,
            downloadThroughput: download,
            uploadThroughput: upload,
            totalReceived: sessionReceived,
            totalSent: sessionSent,
            isConnected: isConnected,
            addresses: refreshedAddresses(),
            packetsInRate: packetsIn,
            packetsOutRate: packetsOut,
            errorsIn: primary?.errorsIn ?? 0,
            errorsOut: primary?.errorsOut ?? 0,
            drops: primary?.drops ?? 0,
            linkSpeed: primary?.linkSpeed ?? 0,
            mtu: primary?.mtu ?? 0,
            interfaces: active.sorted { $0.download + $0.upload > $1.download + $1.upload },
            router: cachedRouter,
            dnsServers: cachedDNS,
            wifi: refreshedWiFi(includeRadio: includeRadio),
            usesVPN: usesVPN,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            lifetimeReceived: primary?.received ?? 0,
            lifetimeSent: primary?.sent ?? 0
        )
    }

    /// Interfaces the per-interface breakdown shows.
    ///
    /// Loopback traffic is not network traffic, and `awdl`/`llw` are Apple's
    /// peer-to-peer radios whose chatter would show as constant background use.
    /// Everything else is listed, tunnels included — seeing that a VPN is
    /// carrying the traffic is exactly what that list is for.
    nonisolated static func isWorthListing(_ name: String) -> Bool {
        !name.hasPrefix("lo") && !name.hasPrefix("awdl") && !name.hasPrefix("llw")
    }

    /// Interfaces layered on top of another one, which must not be added to the
    /// aggregate.
    ///
    /// A packet crossing a VPN is counted twice by the kernel: once on the
    /// `utun` device and again on the `en` device that actually carried it.
    /// Summing both reports roughly double the traffic that moved. The same
    /// holds for a bridge, an Internet Sharing `ap` interface, and the `gif`
    /// and `stf` tunnels. The physical interface underneath still accounts for
    /// every byte, so nothing is lost by leaving these out of the total.
    private nonisolated static let derivedInterfacePrefixes = [
        "utun", "ipsec", "ppp", "bridge", "gif", "stf", "vmenet", "ap",
    ]

    /// Internal rather than private so the double-counting rule can be tested
    /// against interface names without a live machine that happens to have a
    /// VPN up.
    nonisolated static func countsTowardTotal(_ name: String) -> Bool {
        isWorthListing(name) && !derivedInterfacePrefixes.contains { name.hasPrefix($0) }
    }

    private nonisolated static func describe(_ type: NWInterface.InterfaceType?) -> String {
        switch type {
        case .wifi: "Wi-Fi"
        case .wiredEthernet: "Ethernet"
        case .cellular: "Cellular"
        case .loopback: "Loopback"
        case .other: "Other"
        default: "Unknown"
        }
    }

    private func refreshedAddresses() -> [String] {
        samplesSinceAddressRefresh += 1
        let interfaceChanged = addressInterface != primaryInterface
        guard interfaceChanged || samplesSinceAddressRefresh >= Self.addressRefreshInterval else {
            return cachedAddresses
        }
        samplesSinceAddressRefresh = 0
        addressInterface = primaryInterface
        cachedAddresses = primaryInterface.map { Self.addresses(of: $0) } ?? []
        (cachedRouter, cachedDNS) = Self.routerAndResolvers()
        return cachedAddresses
    }

    private func refreshedWiFi(includeRadio: Bool) -> WiFiSignal? {
        guard includeRadio else { return cachedWiFi }
        // Saturating: the counter only ever needs to reach the threshold, and
        // an unbounded increment would overflow on a long-running sampler.
        samplesSinceRadioRefresh = min(samplesSinceRadioRefresh + 1, Self.radioRefreshInterval)
        guard samplesSinceRadioRefresh >= Self.radioRefreshInterval else { return cachedWiFi }
        samplesSinceRadioRefresh = 0
        cachedWiFi = Self.wifiSignal()
        return cachedWiFi
    }

    /// The router and resolvers macOS is actually using, from the dynamic store.
    /// Reading them here beats parsing the routing table or `/etc/resolv.conf`,
    /// which is a symlink that does not reflect per-service configuration.
    private nonisolated static func routerAndResolvers() -> (String?, [String]) {
        guard let store = SCDynamicStoreCreate(nil, "com.mymac.network" as CFString, nil, nil) else {
            return (nil, [])
        }
        let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
        return (ipv4?["Router"] as? String, dns?["ServerAddresses"] as? [String] ?? [])
    }

    /// Radio conditions, when the primary link is Wi-Fi. Every value here is
    /// readable without any permission; the SSID is not, and is left out.
    private nonisolated static func wifiSignal() -> WiFiSignal? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return nil }
        let rssi = interface.rssiValue()
        // Zero means the radio is associated with nothing worth reporting.
        guard rssi != 0 else { return nil }

        let channel = interface.wlanChannel()
        let band: String
        switch channel?.channelBand {
        case .band2GHz: band = "2.4 GHz"
        case .band5GHz: band = "5 GHz"
        case .band6GHz: band = "6 GHz"
        default: band = "—"
        }
        let width: Int
        switch channel?.channelWidth {
        case .width20MHz: width = 20
        case .width40MHz: width = 40
        case .width80MHz: width = 80
        case .width160MHz: width = 160
        default: width = 0
        }

        return WiFiSignal(networkName: interface.ssid(),
                          rssi: rssi,
                          noise: interface.noiseMeasurement(),
                          transmitRate: interface.transmitRate(),
                          channel: channel?.channelNumber ?? 0,
                          band: band,
                          channelWidth: width)
    }

    /// IPv4 and IPv6 addresses of one interface. Link-local IPv6 is omitted:
    /// it is always present and never what the user is looking for.
    private nonisolated static func addresses(of interface: String) -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == interface,
                  let address = current.pointee.ifa_addr else { continue }
            let family = address.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let scope = text.firstIndex(of: "%") { text = String(text[..<scope]) }
            guard !text.hasPrefix("fe80"), !text.hasPrefix("::1") else { continue }
            result.append(text)
        }
        return result
    }

    private nonisolated static func readInterfaceCounters() -> [String: Counters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: Counters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                defer { offset += messageLength }

                guard header.ifm_type == RTM_IFINFO2,
                      messageLength >= MemoryLayout<if_msghdr2>.size else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)

                var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
                guard if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil else { continue }
                let bytes = nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let name = String(decoding: bytes, as: UTF8.self)
                guard !name.isEmpty else { continue }

                var counters = result[name] ?? Counters()
                let data = message.ifm_data
                counters.received &+= data.ifi_ibytes
                counters.sent &+= data.ifi_obytes
                counters.packetsIn &+= data.ifi_ipackets
                counters.packetsOut &+= data.ifi_opackets
                counters.errorsIn &+= data.ifi_ierrors
                counters.errorsOut &+= data.ifi_oerrors
                counters.drops &+= data.ifi_iqdrops
                counters.linkSpeed = data.ifi_baudrate
                counters.mtu = data.ifi_mtu
                result[name] = counters
            }
        }
        return result
    }
}
