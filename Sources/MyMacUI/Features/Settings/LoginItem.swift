import Foundation
import MyMacCore
import Observation
import ServiceManagement

/// The part of `SMAppService` this app uses.
///
/// Abstracted for one reason: the failure path is the path every locally built
/// copy takes, because `SMAppService` refuses a bundle that is not signed with
/// a Developer ID and `Scripts/build-app.sh` signs ad-hoc. A refusal that
/// cannot be simulated is a refusal nobody ever tests, which is how the message
/// explaining it came to erase itself.
@MainActor
public protocol LoginItemService: Sendable {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

@MainActor
struct SystemLoginItemService: LoginItemService {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Drives "Open at login".
///
/// `isEnabled` is only ever written from the service's own status — never from
/// what the user just clicked. The previous version mirrored the click into
/// bound state and corrected it inside the failure handler, which re-entered
/// `onChange`; the second pass called `unregister()`, succeeded, and cleared
/// the very message that explained why the first pass had failed.
@MainActor
@Observable
public final class LoginItemController {
    public private(set) var isEnabled: Bool
    public private(set) var errorMessage: String?

    @ObservationIgnored private let service: any LoginItemService

    init(service: any LoginItemService) {
        self.service = service
        self.isEnabled = service.isEnabled
    }

    public convenience init() {
        self.init(service: SystemLoginItemService())
    }

    /// Granted and revoked outside the app too, from System Settings → General
    /// → Login Items, so the switch is re-read rather than trusted.
    public func refresh() {
        isEnabled = service.isEnabled
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.explain(error, enabling: enabled)
            Log.app.error("login item change failed: \(error.localizedDescription)")
        }
        // The service decides, not the click. If it refused, the switch goes
        // back on its own without anything else having to notice — and without
        // a second pass that could clear the message.
        isEnabled = service.isEnabled
    }

    /// `SMAppService` reports a bare "Operation not permitted" for the case
    /// people building this themselves will actually hit, and that alone tells
    /// nobody why. The likely cause is named instead.
    static func explain(_ error: Error, enabling: Bool) -> String {
        let detail = (error as NSError).localizedDescription
        guard enabling else {
            return "macOS refused to remove the login item: \(detail)"
        }
        return """
        macOS refused to add MyMac as a login item: \(detail) \
        The usual cause is the signature: macOS only accepts a login item from a bundle signed \
        with a Developer ID, and Scripts/build-app.sh signs ad-hoc. Re-sign with a Developer ID \
        identity, or add MyMac by hand in System Settings → General → Login Items.
        """
    }
}
