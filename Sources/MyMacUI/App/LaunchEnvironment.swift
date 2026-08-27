import Foundation

/// Everything that depends only on how the process was launched.
///
/// This lives in `MyMacUI` rather than the app target because every view it
/// has to influence — `MainWindowView`, `UninstallerView`, `SettingsView` — is
/// internal to this module. Keeping it here also means the launch contract is
/// reachable from `swift test`, which is where its parsing is pinned.
public enum LaunchEnvironment {
    /// Written as `-MyMacUITesting YES`, a well-formed pair, rather than as a
    /// bare flag.
    ///
    /// The `NSUserDefaults` argument domain parses `-key value`, so a bare
    /// `-MyMacUITesting` swallows whatever token follows it. This app reads
    /// defaults heavily — `menuBarShowsCPU`, `menuBarShowsMemory` and
    /// `SettingsKey.relaxedUpdates` all come from there, the last one read
    /// directly by `MetricsStore.interval` — and a UI test wants to set those
    /// through the same domain to control what it is testing. A bare flag would
    /// silently eat the first one.
    static let testingArgument = "-MyMacUITesting"

    /// Which section the window should open on, as a `MainSection` raw value.
    static let sectionArgument = "-MyMacUITestSection"

    /// Read from the raw arguments rather than `UserDefaults`, so this answer
    /// does not depend on the argument domain having parsed cleanly.
    public static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains(testingArgument)
    }

    /// The section a UI test asked for, defaulting to the dashboard.
    ///
    /// Reusing `MainSection` rather than inventing a parallel enum means every
    /// section is addressable the day it is added, with no second list to keep
    /// in step.
    static var testSection: MainSection {
        section(in: ProcessInfo.processInfo.arguments)
    }

    /// Split out so the parsing can be tested without spawning a process.
    static func section(in arguments: [String]) -> MainSection {
        guard let index = arguments.firstIndex(of: sectionArgument),
              index + 1 < arguments.count,
              let section = MainSection(rawValue: arguments[index + 1])
        else { return .dashboard }
        return section
    }
}
