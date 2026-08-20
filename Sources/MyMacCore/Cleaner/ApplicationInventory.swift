import Foundation

/// Answers "is an app with this bundle identifier installed?".
///
/// Abstracted so the core has no AppKit dependency and so leftover detection
/// can be tested without touching Launch Services.
public protocol ApplicationInventory: Sendable {
    func isInstalled(bundleIdentifier: String) -> Bool
}

/// Used when no inventory is supplied: reports everything as installed, so the
/// leftovers rule finds nothing rather than guessing.
public struct ConservativeApplicationInventory: ApplicationInventory {
    public init() {}
    public func isInstalled(bundleIdentifier: String) -> Bool { true }
}

extension String {
    /// A reverse-DNS bundle identifier, e.g. `com.example.App`. Folders with
    /// human names ("Google", "Firefox") are never treated as leftovers,
    /// because there is no reliable way to map them back to an application.
    var looksLikeBundleIdentifier: Bool {
        let parts = split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, !contains(" "), !hasPrefix(".") else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }
}
