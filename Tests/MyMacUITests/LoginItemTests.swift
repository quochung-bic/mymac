import Foundation
import Testing
@testable import MyMacUI

/// Regression cover for P2-1 in the 2026-08-20 audit.
///
/// The toggle mirrored the click into bound state and corrected it inside the
/// failure handler. That re-entered `onChange`; its second pass called
/// `unregister()`, succeeded, and set the error back to `nil` — so the one
/// message the user needed never stayed on screen. The counters below are what
/// pins it: a refusal must produce exactly one call and no follow-up.
@MainActor
final class FakeLoginItemService: LoginItemService {
    enum Behaviour {
        case succeeds
        case refuses
        /// The realistic shape of the fault: macOS refuses to *add* the login
        /// item, but removing one that was never added succeeds. That is what
        /// made the old second pass so damaging — it did not just run, it ran
        /// successfully, and success is what cleared the message.
        case refusesToRegister
    }

    var behaviour: Behaviour
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private var enabled: Bool

    init(behaviour: Behaviour = .succeeds, enabled: Bool = false) {
        self.behaviour = behaviour
        self.enabled = enabled
    }

    var isEnabled: Bool { enabled }

    func register() throws {
        registerCalls += 1
        guard behaviour == .succeeds else {
            throw NSError(domain: "SMAppServiceErrorDomain", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        }
        enabled = true
    }

    func unregister() throws {
        unregisterCalls += 1
        guard behaviour == .refuses else {
            enabled = false
            return
        }
        guard behaviour == .succeeds else {
            throw NSError(domain: "SMAppServiceErrorDomain", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        }
        enabled = false
    }
}

@MainActor
@Suite("Login item")
struct LoginItemTests {
    @Test func turningItOnRegistersAndReportsNoError() {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        #expect(controller.isEnabled)
        #expect(controller.errorMessage == nil)
        #expect(service.registerCalls == 1)
        #expect(service.unregisterCalls == 0)
    }

    /// The fault itself.
    @Test func aRefusalLeavesTheMessageOnScreen() {
        let service = FakeLoginItemService(behaviour: .refuses)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        #expect(controller.errorMessage != nil, "the refusal must be explained, and stay explained")
        #expect(controller.isEnabled == false, "the switch goes back on its own")
    }

    /// The mechanism, stated directly: a failed attempt must not provoke a
    /// second call that succeeds and wipes the message.
    @Test func aRefusalDoesNotProvokeACompensatingSecondCall() {
        let service = FakeLoginItemService(behaviour: .refuses)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        #expect(service.registerCalls == 1)
        #expect(service.unregisterCalls == 0,
                "correcting the switch must not run the opposite operation")
    }

    /// The message has to say more than what SMAppService says, because what it
    /// says is "Operation not permitted" and that explains nothing.
    @Test func theMessageNamesTheLikelyCause() {
        let service = FakeLoginItemService(behaviour: .refuses)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)
        let message = controller.errorMessage ?? ""

        #expect(message.contains("Operation not permitted"), "the system's own words are kept")
        #expect(message.contains("Developer ID"), "and the actual cause is named")
        #expect(message.contains("ad-hoc"))
    }

    /// The realistic failure: adding is refused, removing would succeed. Under
    /// the old shape the compensating second pass therefore *succeeded*, and a
    /// success clears the error — so the explanation vanished before it could
    /// be read.
    @Test func aRefusalSurvivesEvenWhenTheOppositeOperationWouldSucceed() {
        let service = FakeLoginItemService(behaviour: .refusesToRegister)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        #expect(controller.errorMessage != nil,
                "nothing may run afterwards that could clear this message")
        #expect(controller.isEnabled == false)
        #expect(service.unregisterCalls == 0)
    }

    @Test func aSuccessfulChangeClearsAnEarlierMessage() throws {
        let service = FakeLoginItemService(behaviour: .refuses)
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        try #require(controller.errorMessage != nil)

        service.behaviour = .succeeds
        controller.setEnabled(true)

        #expect(controller.errorMessage == nil)
        #expect(controller.isEnabled)
    }

    /// The switch can be flipped in System Settings while the page is open.
    @Test func refreshReadsTheServiceRatherThanTrustingItsOwnState() {
        let service = FakeLoginItemService(enabled: false)
        let controller = LoginItemController(service: service)
        #expect(controller.isEnabled == false)

        try? service.register()
        controller.refresh()

        #expect(controller.isEnabled)
    }
}
