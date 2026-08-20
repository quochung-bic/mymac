import Foundation

/// A declarative description of one cleanup category.
///
/// Rules are data, not code paths: the scanner and the deletion engine both
/// read the same `root` and both re-validate against it, so a rule can never
/// widen the blast radius by accident.
public struct CleanupRule: Sendable, Identifiable {
    public enum Kind: Sendable {
        /// Every immediate child of `root` is one item (a per-app cache folder).
        case directoryChildren
        /// For each immediate child of `root`, the directory at
        /// `child/relativePath` is one item. Used for sandboxed apps, whose
        /// caches sit deep inside a container that must never itself be removed.
        case nestedDirectories(relativePath: String)
        /// Every file below `root`, recursively (crash reports).
        case filesRecursive
        /// Folders under `root` named after a bundle identifier with no
        /// matching application installed.
        case applicationLeftovers
        /// Large files below `root`, for the user to judge.
        case largeFiles
        /// Byte-identical copies below `root`.
        case duplicateFiles
        /// Directories with a given name found in project trees, e.g.
        /// `node_modules`. The scan never descends into a match.
        case projectArtifacts(named: String)
        /// Measures `root` and reports the size without offering to delete it.
        /// For storage this app must not touch — a virtual machine disk image,
        /// say — where the owning tool is the only safe way to reclaim space.
        case advisory(guidance: String)
    }

    public let id: String
    public let title: String
    public let explanation: String
    public let tier: CleanupTier
    public let removal: RemovalMode
    public let kind: Kind
    public let root: URL
    /// Items modified more recently than this are left alone — a log written a
    /// minute ago probably belongs to something still running.
    public let minimumAge: TimeInterval?
    public let minimumSize: Int64
    public let excludedNames: Set<String>
    /// Rules that read locations macOS keeps behind Full Disk Access.
    public let needsFullDiskAccess: Bool
    /// Scans that walk a deep tree and are therefore opt-in.
    public let isDeepScan: Bool

    public init(id: String, title: String, explanation: String, tier: CleanupTier,
                removal: RemovalMode, kind: Kind, root: URL, minimumAge: TimeInterval? = nil,
                minimumSize: Int64 = 0, excludedNames: Set<String> = [],
                needsFullDiskAccess: Bool = false, isDeepScan: Bool = false) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.tier = tier
        self.removal = removal
        self.kind = kind
        self.root = root
        self.minimumAge = minimumAge
        self.minimumSize = minimumSize
        self.excludedNames = excludedNames
        self.needsFullDiskAccess = needsFullDiskAccess
        self.isDeepScan = isDeepScan
    }
}
