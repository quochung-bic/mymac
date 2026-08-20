import Foundation

public struct PublicAddress: Sendable, Equatable {
    public let ip: String
    /// Two-letter country code the service saw the request come from.
    public let country: String?

    public init(ip: String, country: String?) {
        self.ip = ip
        self.country = country
    }
}

/// Looks up the address the internet sees.
///
/// This is the **only** outbound request the app makes, and it cannot be
/// answered locally: a machine behind NAT has no way to know its public address
/// without asking something outside. The endpoint is named in the interface so
/// the user knows who was asked, the session is ephemeral so nothing is
/// persisted, and the result is cached — the answer changes when the network
/// does, not once a second.
public actor PublicAddressService {
    public enum Failure: Error, Sendable {
        case unreachable
        case unreadable
    }

    /// Cloudflare's trace endpoint: plain `key=value` text, and it reports the
    /// country as well as the address.
    public static let endpoint = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!
    public static let endpointName = "cloudflare.com"

    private static let cacheLifetime: TimeInterval = 15 * 60

    private var cached: PublicAddress?
    private var fetchedAt: Date?
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func lookup(force: Bool = false) async throws -> PublicAddress {
        if !force, let cached, let fetchedAt,
           Date().timeIntervalSince(fetchedAt) < Self.cacheLifetime {
            return cached
        }

        let data: Data
        do {
            (data, _) = try await session.data(from: Self.endpoint)
        } catch {
            Log.metrics.error("public address lookup failed: \(error.localizedDescription)")
            throw Failure.unreachable
        }

        guard let address = Self.parse(String(decoding: data, as: UTF8.self)) else {
            throw Failure.unreadable
        }
        cached = address
        fetchedAt = Date()
        return address
    }

    static func parse(_ body: String) -> PublicAddress? {
        var fields: [String: String] = [:]
        for line in body.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1])
        }
        guard let ip = fields["ip"], !ip.isEmpty else { return nil }
        let country = fields["loc"].flatMap { $0.isEmpty || $0 == "XX" ? nil : $0 }
        return PublicAddress(ip: ip, country: country)
    }
}
