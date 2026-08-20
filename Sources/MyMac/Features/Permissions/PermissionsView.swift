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

    @ObservationIgnored private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        refresh()
    }

    func refresh() {
        statuses[.fullDiskAccess] = FullDiskAccess.status()
        statuses[.location] = Self.locationStatus(locationManager.authorizationStatus)
    }

    func status(of kind: Permission.Kind) -> PermissionStatus {
        statuses[kind] ?? .notDetermined
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
            NSWorkspace.shared.open(FullDiskAccess.settingsURL)
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
