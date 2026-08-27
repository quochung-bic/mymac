import Testing

@testable import MyMacUI

@Suite("Launch environment")
struct LaunchEnvironmentTests {
    @Test func noSectionArgumentOpensTheDashboard() {
        #expect(LaunchEnvironment.section(in: []) == .dashboard)
        #expect(LaunchEnvironment.section(in: ["-MyMacUITesting", "YES"]) == .dashboard)
    }

    @Test func aSectionIsReadFromTheTokenAfterTheFlag() {
        let arguments = ["-MyMacUITesting", "YES", "-MyMacUITestSection", "uninstaller"]
        #expect(LaunchEnvironment.section(in: arguments) == .uninstaller)
    }

    /// Every section is addressable by its raw value the day it is added,
    /// because the parser reuses `MainSection` rather than a parallel list.
    @Test func everySectionIsReachableByRawValue() {
        for section in MainSection.allCases {
            let arguments = ["-MyMacUITestSection", section.rawValue]
            #expect(LaunchEnvironment.section(in: arguments) == section)
        }
    }

    @Test func anUnknownSectionFallsBackRatherThanCrashing() {
        #expect(LaunchEnvironment.section(in: ["-MyMacUITestSection", "nonsense"]) == .dashboard)
    }

    /// The flag at the very end has no value after it. Reading past the array
    /// would trap, so the bounds check is the point of this test.
    @Test func aTrailingSectionFlagWithNoValueIsIgnored() {
        #expect(LaunchEnvironment.section(in: ["-MyMacUITestSection"]) == .dashboard)
    }

    /// The reason `-MyMacUITesting` carries `YES` instead of standing alone:
    /// with a bare flag the NSUserDefaults argument domain treats the next
    /// token as its value, so a section flag placed after it would be eaten.
    /// Written as pairs, the section is still found wherever it sits.
    @Test func theSectionSurvivesFollowingTheTestingFlag() {
        let arguments = [
            "-MyMacUITesting", "YES",
            "-MyMacUITestSection", "processes",
            "-menuBarShowsCPU", "NO",
        ]
        #expect(LaunchEnvironment.section(in: arguments) == .processes)
    }
}
