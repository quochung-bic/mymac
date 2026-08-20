import Darwin
import Foundation

/// The single gate every deletion must pass.
///
/// The rule set is an allowlist: a path is only removable when it lies strictly
/// inside a root that a cleanup rule declared, is not itself one of the
/// protected directories, and is not a symbolic link. Nothing here trusts a
/// path because of how it is spelled — "looks like a cache" is not a reason.
public enum PathSafety {
    public enum Violation: Error, Sendable, Equatable {
        case notAbsolute
        case traversal
        case outsideAllowedRoot
        case isProtectedDirectory
        case hasProtectedAncestor
        case isSymbolicLink
        case tooShallow
        case doesNotExist
        case unreadableParent

        public var reason: String {
            switch self {
            case .notAbsolute: "path is not absolute"
            case .traversal: "path contains a parent-directory reference"
            case .outsideAllowedRoot: "path is outside every allowed cleanup root"
            case .isProtectedDirectory: "path is a protected directory"
            case .hasProtectedAncestor: "path lives inside a protected directory"
            case .isSymbolicLink: "path is a symbolic link"
            case .tooShallow: "path is too close to the volume root"
            case .doesNotExist: "path no longer exists"
            case .unreadableParent: "parent directory could not be resolved"
            }
        }
    }

    /// Resolves a path through `realpath`, falling back to lexical
    /// standardisation when the path cannot be resolved.
    public static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The protected-path sets, resolved once so they can be reused across a
    /// whole cleanup run instead of being rebuilt for every item.
    public struct Context: Sendable {
        public let home: URL
        public let protectedPaths: Set<String>
        public let protectedAncestors: [String]

        public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
            let canonicalHome = URL(fileURLWithPath: PathSafety.canonicalPath(home.path))
            self.home = canonicalHome
            self.protectedPaths = Set(PathSafety.protectedDirectories(home: canonicalHome).map(PathSafety.canonicalPath))
            self.protectedAncestors = PathSafety.protectedAncestors(home: canonicalHome).map(PathSafety.canonicalPath)
        }
    }

    /// Directories that must never be removed, even when a rule root would
    /// otherwise permit it. Every cleanup rule's own root is included, so
    /// emptying `~/Library/Caches` can only ever remove its children — adding a
    /// new rule extends this set automatically.
    public static func protectedDirectories(home: URL) -> Set<String> {
        var paths: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
            "/etc", "/var", "/private", "/tmp", "/opt", "/Users", "/Volumes", "/cores",
        ]
        let homeRelative = [
            "", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
            "Public", "Applications", "Library", "Library/Caches", "Library/Logs",
            "Library/Preferences", "Library/Application Support", "Library/Containers",
            "Library/Group Containers", "Library/Keychains", "Library/Mobile Documents",
            "Library/Developer", "Library/Developer/Xcode", "Library/Developer/CoreSimulator",
            "Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives",
            "Library/Logs/DiagnosticReports", "Library/Application Support/MobileSync",
            "Library/Application Support/MobileSync/Backup", ".Trash", ".ssh", ".gnupg", ".config",
        ]
        for component in homeRelative {
            let url = component.isEmpty ? home : home.appendingPathComponent(component)
            paths.insert(url.standardizedFileURL.path)
        }
        for rule in CleanupCatalog.rules(home: home) {
            paths.insert(rule.root.standardizedFileURL.path)
        }
        return paths
    }

    /// Anything below these is off-limits regardless of rule configuration:
    /// keys, credentials and iCloud-synced documents.
    public static func protectedAncestors(home: URL) -> [String] {
        [
            home.appendingPathComponent("Library/Keychains").path,
            home.appendingPathComponent("Library/Mobile Documents").path,
            home.appendingPathComponent(".ssh").path,
            home.appendingPathComponent(".gnupg").path,
            "/System",
            "/Library/Keychains",
        ]
    }

    /// Minimum number of path components below the volume root. `/a/b` can
    /// never be a legitimate cleanup target.
    public static let minimumDepth = 3

    /// Validates `url` against `allowedRoots` and returns the canonical path to
    /// delete. Throws rather than returning an optional so the caller cannot
    /// accidentally ignore the result.
    public static func canonicalPathForRemoval(
        of url: URL,
        allowedRoots: [URL],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
        try canonicalPathForRemoval(of: url, allowedRoots: allowedRoots, context: Context(home: home))
    }

    public static func canonicalPathForRemoval(
        of url: URL,
        allowedRoots: [URL],
        context: Context
    ) throws -> String {
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/") else { throw Violation.notAbsolute }
        guard !standardized.pathComponents.contains("..") else { throw Violation.traversal }
        guard standardized.pathComponents.count - 1 >= minimumDepth else { throw Violation.tooShallow }

        // lstat, not stat: a symlink must be recognised as a symlink and
        // rejected, never silently followed to whatever it points at.
        var status = stat()
        guard lstat(standardized.path, &status) == 0 else { throw Violation.doesNotExist }
        guard (status.st_mode & S_IFMT) != S_IFLNK else { throw Violation.isSymbolicLink }

        // Resolve the *parent* through realpath. Resolving the item itself
        // would hide a symlinked component; resolving the parent exposes it.
        let parent = standardized.deletingLastPathComponent()
        guard let canonicalParent = realpath(parent.path, nil) else { throw Violation.unreadableParent }
        defer { free(canonicalParent) }
        let canonicalParentPath = String(cString: canonicalParent)
        let canonicalPath = (canonicalParentPath as NSString)
            .appendingPathComponent(standardized.lastPathComponent)

        guard !context.protectedPaths.contains(canonicalPath) else { throw Violation.isProtectedDirectory }

        for ancestor in context.protectedAncestors where isDescendant(canonicalPath, of: ancestor) {
            throw Violation.hasProtectedAncestor
        }

        let insideAllowedRoot = allowedRoots.contains { root in
            guard let canonicalRoot = realpath(root.standardizedFileURL.path, nil) else { return false }
            defer { free(canonicalRoot) }
            return isDescendant(canonicalPath, of: String(cString: canonicalRoot))
        }
        guard insideAllowedRoot else { throw Violation.outsideAllowedRoot }

        return canonicalPath
    }

    /// Strict containment: a path is never a descendant of itself, and the
    /// comparison is on whole path components so `/a/bc` is not inside `/a/b`.
    public static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        let normalizedAncestor = ancestor.hasSuffix("/") ? String(ancestor.dropLast()) : ancestor
        guard !normalizedAncestor.isEmpty else { return path != "/" && path.hasPrefix("/") }
        guard path.hasPrefix(normalizedAncestor + "/") else { return false }
        return path.count > normalizedAncestor.count + 1
    }
}
