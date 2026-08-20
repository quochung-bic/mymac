import Foundation

public enum CleanupTier: String, Sendable, CaseIterable, Identifiable {
    case safe
    case review

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .safe: "Safe to Clean"
        case .review: "Review Before Cleaning"
        }
    }

    public var subtitle: String {
        switch self {
        case .safe: "Regenerated automatically by the apps that own them."
        case .review: "Real user data may be involved. Nothing is selected for you."
        }
    }
}

/// How an item leaves the disk.
public enum RemovalMode: String, Sendable {
    /// Deleted outright. Only used for content the owning app regenerates.
    case delete
    /// Moved to the Trash, so the user can put it back. Used for anything that
    /// could conceivably be wanted again.
    case trash

    public var verb: String {
        switch self {
        case .delete: "Deleted"
        case .trash: "Moved to Trash"
        }
    }
}

public struct CleanupItem: Sendable, Identifiable, Hashable {
    public let id: String
    public let url: URL
    public let name: String
    public let detail: String?
    public let size: Int64
    public let modified: Date?

    public init(url: URL, name: String, detail: String? = nil, size: Int64, modified: Date?) {
        self.id = url.path
        self.url = url
        self.name = name
        self.detail = detail
        self.size = size
        self.modified = modified
    }
}

/// Something the scanner could not do, surfaced to the user as context rather
/// than as an error dialog.
public struct CleanupIssue: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct CleanupGroup: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let explanation: String
    public let tier: CleanupTier
    public let removal: RemovalMode
    public let items: [CleanupItem]
    public let issues: [CleanupIssue]
    /// True when the group is empty only because macOS denied access.
    public let requiresFullDiskAccess: Bool
    /// Set for categories this app reports but will not delete. The group is
    /// shown, with the size and this explanation, and cannot be selected.
    public let advice: String?

    public var isAdvisory: Bool { advice != nil }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    public init(id: String, title: String, explanation: String, tier: CleanupTier,
                removal: RemovalMode, items: [CleanupItem], issues: [CleanupIssue],
                requiresFullDiskAccess: Bool, advice: String? = nil) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.tier = tier
        self.removal = removal
        self.items = items
        self.issues = issues
        self.requiresFullDiskAccess = requiresFullDiskAccess
        self.advice = advice
    }
}

public struct ScanProgress: Sendable {
    public let completedRules: Int
    public let totalRules: Int
    public let currentTitle: String
    public let bytesFound: Int64
    /// Files examined by the rule currently running. A deep scan can spend
    /// minutes inside one rule, and a progress bar that only moves between
    /// rules looks stuck.
    public let examinedFiles: Int

    public var fraction: Double {
        totalRules == 0 ? 0 : Double(completedRules) / Double(totalRules)
    }

    public init(completedRules: Int, totalRules: Int, currentTitle: String,
                bytesFound: Int64, examinedFiles: Int = 0) {
        self.completedRules = completedRules
        self.totalRules = totalRules
        self.currentTitle = currentTitle
        self.bytesFound = bytesFound
        self.examinedFiles = examinedFiles
    }
}

public struct CleanupOutcome: Sendable {
    public struct Failure: Sendable, Identifiable {
        public let id = UUID()
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public let removedCount: Int
    public let reclaimedBytes: Int64
    public let trashedCount: Int
    public let failures: [Failure]
    /// Items that were rejected by `PathSafety` at deletion time. Should always
    /// be empty; a non-zero value means the disk changed under us in a way that
    /// made a previously valid path unsafe.
    public let rejectedCount: Int

    public init(removedCount: Int, reclaimedBytes: Int64, trashedCount: Int,
                failures: [Failure], rejectedCount: Int) {
        self.removedCount = removedCount
        self.reclaimedBytes = reclaimedBytes
        self.trashedCount = trashedCount
        self.failures = failures
        self.rejectedCount = rejectedCount
    }
}
