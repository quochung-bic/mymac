import XCTest

/// Shared launch helpers for the UI tests.
///
/// The constants below are duplicated from `LaunchEnvironment` in the app
/// target on purpose: a UI test bundle runs out of process and cannot import
/// the app, so there is no way to share them. Changing one means changing both.
enum UITest {
    static let testingArgument = "-MyMacUITesting"
    static let sectionArgument = "-MyMacUITestSection"
}
