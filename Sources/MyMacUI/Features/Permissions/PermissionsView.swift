import AppKit
import CoreLocation
import MyMacCore
import Observation
import SwiftUI

/// Tracks and requests the permissions the app can use.
///
/// Nothing here is asked for on its own. The point of the page is that a user
/// can see the whole list, decide once, and never meet a system prompt in the
/// middle of doing something else.
@MainActor
@Observable
final class PermissionsModel: NSObject, CLLocationManagerDelegate {
    private(set) var statuses: [Permission.Kind: PermissionStatus] = [:]
    /// Full Disk Access was granted once and is gone now. The build signs
    /// ad-hoc, so every reinstall drops it without a word.
    private(set) var fullDiskAccessLapsed = false

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fullDiskAccessProbe: () -> PermissionStatus
    private static let everGrantedKey = "fullDiskAccessEverGranted"

    init(defaults: UserDefaults = .standard,
         fullDiskAccessProbe: @escaping () -> PermissionStatus = { FullDiskAccess.status() }) {
        self.defaults = defaults
        self.fullDiskAccessProbe = fullDiskAccessProbe
        super.init()
        locationManager.delegate = self
        refresh()
    }

    func refresh() {
        let fullDiskAccess = fullDiskAccessProbe()
        if fullDiskAccess == .granted { defaults.set(true, forKey: Self.everGrantedKey) }
        fullDiskAccessLapsed = fullDiskAccess == .denied && defaults.bool(forKey: Self.everGrantedKey)
        statuses[.fullDiskAccess] = fullDiskAccess
        statuses[.location] = Self.locationStatus(locationManager.authorizationStatus)
    }

    func status(of kind: Permission.Kind) -> PermissionStatus {
        statuses[kind] ?? .notDetermined
    }

    func dismissFullDiskAccessLapse() {
        defaults.set(false, forKey: Self.everGrantedKey)
        fullDiskAccessLapsed = false
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }

    /// Either raises the system prompt, or opens the pane where the user has to
    /// grant it by hand — Full Disk Access has no programmatic request.
    func request(_ permission: Permission) {
        switch permission.id {
        case .location:
            if status(of: .location) == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
            }
        case .fullDiskAccess:
            openFullDiskAccessSettings()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh() }
    }

    private static func locationStatus(_ status: CLAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized, .authorizedAlways: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }
}

/// The permissions group inside Settings.
struct PermissionsPanel: View {
    @Environment(PermissionsModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Permission.all) { permission in
                PermissionRow(permission: permission, status: model.status(of: permission.id)) {
                    model.request(permission)
                }
                .frame(height: 142)
            }

            Card(title: "Never Requested", symbol: "checkmark.shield", fillsHeight: true) {
                Text("Every feature works without the two above. These are not asked for at all, and the app cannot use them:")
                    .font(.note)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 4) {
                    ForEach(Permission.neverRequested, id: \.self) { item in
                        Label(item, systemImage: "xmark")
                            .font(.note)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        // Full Disk Access is granted outside the app, so the status is
        // re-checked whenever the panel comes back into view.
        .onAppear { model.refresh() }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let status: PermissionStatus
    let request: () -> Void

    var body: some View {
        Card(title: permission.title, symbol: permission.symbol, fillsHeight: true) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(permission.unlocks)
                        .font(.callout)
                    Text(permission.withoutIt)
                        .font(.note)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 7) {
                    StatusPill(status: status)
                    if status != .granted {
                        Button(permission.isRequestable && status == .notDetermined
                               ? "Allow…" : "Open Settings…", action: request)
                    }
                    if !permission.isRequestable {
                        Text("Granted in System Settings")
                            .font(.note)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 168, alignment: .trailing)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StatusPill: View {
    let status: PermissionStatus

    var body: some View {
        Label(status.label, systemImage: symbol)
            .font(.badge)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var symbol: String {
        switch status {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle"
        case .notDetermined: "questionmark.circle"
        }
    }

    private var color: Color {
        switch status {
        case .granted: .green
        case .denied: .orange
        case .notDetermined: .secondary
        }
    }
}

/// Shown on the dashboard after a reinstall took Full Disk Access away. It
/// clears itself the moment the permission is back, so nobody has to dismiss
/// something that is already fixed.
struct FullDiskAccessLapseBanner: View {
    @Environment(PermissionsModel.self) private var model

    var body: some View {
        Group {
            if model.fullDiskAccessLapsed {
                HStack(spacing: 10) {
                    Image(systemName: "lock.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                    Text("Full Disk Access was reset, which happens after every reinstall. Grant it again to clean Safari and Mail caches.")
                        .font(.note)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Open Settings…") { model.openFullDiskAccessSettings() }
                    Button("Dismiss") { model.dismissFullDiskAccessLapse() }
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
        }
        // Granted in System Settings, so coming back to the app is the only
        // signal there is.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .onAppear { model.refresh() }
    }
}
