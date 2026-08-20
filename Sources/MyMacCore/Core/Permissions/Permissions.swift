import Foundation

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case notDetermined

    public var label: String {
        switch self {
        case .granted: "Granted"
        case .denied: "Not granted"
        case .notDetermined: "Not asked"
        }
    }
}

/// Everything the app can ask macOS for, described in one place so the user can
/// see the whole list before granting anything — rather than meeting a system
/// prompt part-way through a task.
public struct Permission: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        case fullDiskAccess
        case location
    }

    public let id: Kind
    public let title: String
    public let symbol: String
    /// What granting it makes possible.
    public let unlocks: String
    /// What still works without it. Every permission here is optional.
    public let withoutIt: String
    /// Whether the app can raise a system prompt, or whether the user has to
    /// grant it in System Settings.
    public let isRequestable: Bool

    public static let all: [Permission] = [
        Permission(
            id: .fullDiskAccess,
            title: "Full Disk Access",
            symbol: "externaldrive.badge.person.crop",
            unlocks: "Cleaning caches belonging to Safari and Mail, and finding local iPhone and iPad backups.",
            withoutIt: "Everything else works. Most sandboxed app caches are readable already; only the few macOS protects are skipped, and they are shown as skipped rather than reported as empty.",
            isRequestable: false
        ),
        Permission(
            id: .location,
            title: "Location",
            symbol: "location",
            unlocks: "Showing the name of the Wi-Fi network you are joined to.",
            withoutIt: "Signal strength, noise, channel and link rate are all still shown — macOS only gates the network name itself.",
            isRequestable: true
        ),
    ]

    /// Things this app deliberately never asks for. Worth stating: the absence
    /// of a prompt is easy to miss, and a list of what is *not* used says more
    /// about an app than the list of what is.
    public static let neverRequested = [
        "Accessibility", "Screen Recording", "Camera and Microphone",
        "Contacts, Calendars and Reminders", "Photos", "An administrator helper",
    ]
}

public enum FullDiskAccess {
    /// macOS offers no API to query this, so it is probed: the TCC database is
    /// readable only by applications that have been granted Full Disk Access.
    /// Reading a few bytes is enough, and nothing is kept.
    public static func status(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PermissionStatus {
        let probe = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard FileManager.default.fileExists(atPath: probe.path) else {
            // No database to probe — assume the best rather than accuse macOS.
            return .granted
        }
        guard let handle = try? FileHandle(forReadingFrom: probe) else { return .denied }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1)) != nil ? .granted : .denied
    }

    /// The Privacy pane, scrolled to the Full Disk Access list.
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
}
