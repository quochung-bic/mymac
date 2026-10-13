import Foundation
import MyMacCore
import Testing
@testable import MyMacUI

/// An ad-hoc signature changes on every build, so a reinstall silently drops
/// Full Disk Access. The page that explains it is the last place anyone looks,
/// so the app has to notice the drop itself — and only for someone who had the
/// permission, not for someone who never granted it.
@MainActor
@Suite("Full Disk Access lapse")
struct FullDiskAccessLapseTests {
    private final class Probe: @unchecked Sendable {
        var status: PermissionStatus
        init(_ status: PermissionStatus) { self.status = status }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeModel(_ probe: Probe, defaults: UserDefaults? = nil) -> PermissionsModel {
        PermissionsModel(defaults: defaults ?? makeDefaults(), fullDiskAccessProbe: { probe.status })
    }

    @Test func staysQuietForSomeoneWhoNeverGrantedIt() {
        let model = makeModel(Probe(.denied))
        #expect(!model.fullDiskAccessLapsed)
    }

    @Test func staysQuietWhileItIsGranted() {
        let model = makeModel(Probe(.granted))
        #expect(!model.fullDiskAccessLapsed)
    }

    @Test func noticesAGrantThatDisappeared() {
        let probe = Probe(.granted)
        let model = makeModel(probe)

        probe.status = .denied
        model.refresh()

        #expect(model.fullDiskAccessLapsed)
    }

    @Test func remembersTheGrantAcrossLaunches() {
        let defaults = makeDefaults()
        _ = makeModel(Probe(.granted), defaults: defaults)

        let relaunched = makeModel(Probe(.denied), defaults: defaults)

        #expect(relaunched.fullDiskAccessLapsed)
    }

    @Test func clearsItselfOnceTheGrantIsBack() {
        let probe = Probe(.granted)
        let model = makeModel(probe)
        probe.status = .denied
        model.refresh()

        probe.status = .granted
        model.refresh()

        #expect(!model.fullDiskAccessLapsed)
    }

    @Test func dismissingItStaysDismissedUntilTheGrantIsGivenAgain() {
        let probe = Probe(.granted)
        let model = makeModel(probe)
        probe.status = .denied
        model.refresh()

        model.dismissFullDiskAccessLapse()
        model.refresh()

        #expect(!model.fullDiskAccessLapsed)
    }
}
