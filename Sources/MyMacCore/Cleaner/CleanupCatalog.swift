import Foundation

/// The complete set of locations this app is willing to touch.
///
/// Every entry names an exact directory. There is deliberately no pattern like
/// `~/Library/*` anywhere: adding a category means adding a rule here, in the
/// open, with an explanation the user can read in the interface.
public enum CleanupCatalog {
    /// Cache folders that are not really caches. `CloudKit` holds sync state
    /// whose loss forces an expensive re-download, and the two container
    /// daemons keep bookkeeping the system expects to survive.
    static let cacheExclusions: Set<String> = [
        "CloudKit",
        "com.apple.containermanagerd",
        "com.apple.rosetta.update",
        "com.apple.aned",
    ]


    /// Caches belonging to a language or package manager.
    ///
    /// Only locations *outside* `~/Library/Caches` need an entry of their own —
    /// anything inside it is already covered by the Application Caches rule,
    /// and listing it twice would count the same bytes twice.
    private static func developerCache(_ id: String, _ title: String, _ path: URL,
                                       _ explanation: String) -> CleanupRule {
        CleanupRule(
            id: "dev.\(id)",
            title: title,
            explanation: explanation,
            tier: .safe,
            removal: .delete,
            kind: .directoryChildren,
            root: path
        )
    }

    public static func rules(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CleanupRule] {
        let library = home.appendingPathComponent("Library")
        let developer = library.appendingPathComponent("Developer")

        return [
            CleanupRule(
                id: "user.caches",
                title: "Application Caches",
                explanation: "Per-app cache folders in ~/Library/Caches. Apps rebuild these on demand; the first launch afterwards may be slightly slower.",
                tier: .safe,
                removal: .delete,
                kind: .directoryChildren,
                root: library.appendingPathComponent("Caches"),
                excludedNames: cacheExclusions
            ),
            CleanupRule(
                id: "container.caches",
                title: "Sandboxed App Caches",
                explanation: "Cache folders inside the containers of sandboxed apps. Only the Caches folder of each container is listed; the container itself is never touched.",
                tier: .safe,
                removal: .delete,
                kind: .nestedDirectories(relativePath: "Data/Library/Caches"),
                root: library.appendingPathComponent("Containers"),
                needsFullDiskAccess: true
            ),
            CleanupRule(
                id: "user.logs",
                title: "Application Logs",
                explanation: "Log files written by apps into ~/Library/Logs, older than seven days.",
                tier: .safe,
                removal: .delete,
                kind: .directoryChildren,
                root: library.appendingPathComponent("Logs"),
                minimumAge: 7 * 86_400,
                excludedNames: ["DiagnosticReports"]
            ),
            CleanupRule(
                id: "user.crashreports",
                title: "Crash Reports",
                explanation: "Diagnostic reports macOS wrote after an app crashed. Only useful while you are actively investigating a crash.",
                tier: .safe,
                removal: .delete,
                kind: .filesRecursive,
                root: library.appendingPathComponent("Logs/DiagnosticReports"),
                minimumAge: 3 * 86_400
            ),
            CleanupRule(
                id: "user.trash",
                title: "Trash",
                explanation: "Items you already moved to the Trash. Emptying it is permanent.",
                tier: .safe,
                removal: .delete,
                kind: .directoryChildren,
                root: home.appendingPathComponent(".Trash")
            ),
            CleanupRule(
                id: "xcode.deriveddata",
                title: "Xcode Derived Data",
                explanation: "Build products and indexes Xcode regenerates. Removing them forces a full rebuild of the affected projects.",
                tier: .safe,
                removal: .delete,
                kind: .directoryChildren,
                root: developer.appendingPathComponent("Xcode/DerivedData")
            ),
            CleanupRule(
                id: "simulator.caches",
                title: "Simulator Caches",
                explanation: "Caches written by the iOS/watchOS simulator runtimes. Simulator devices and their contents are not touched.",
                tier: .safe,
                removal: .delete,
                kind: .directoryChildren,
                root: developer.appendingPathComponent("CoreSimulator/Caches")
            ),

            developerCache("npm", "npm Cache",
                            home.appendingPathComponent(".npm/_cacache"),
                            "Package tarballs and metadata npm keeps in ~/.npm. Re-downloaded on the next install that needs them."),
            developerCache("pnpm", "pnpm Store",
                            home.appendingPathComponent("Library/pnpm/store"),
                            "pnpm's content-addressable store. Removing it forces the next install to fetch packages again."),
            developerCache("bun", "Bun Cache",
                            home.appendingPathComponent(".bun/install/cache"),
                            "Packages Bun has downloaded."),
            developerCache("gradle", "Gradle Caches",
                            home.appendingPathComponent(".gradle/caches"),
                            "Dependencies and build state Gradle re-downloads and rebuilds on demand."),
            developerCache("maven", "Maven Repository",
                            home.appendingPathComponent(".m2/repository"),
                            "Java artefacts Maven re-downloads when a build needs them."),
            developerCache("cargo", "Cargo Registry",
                            home.appendingPathComponent(".cargo/registry"),
                            "Crate archives and unpacked sources Cargo fetches again as needed."),
            developerCache("cache.dir", "Shared Tool Cache",
                            home.appendingPathComponent(".cache"),
                            "The ~/.cache folder used by pip, Puppeteer and other cross-platform tools."),

            CleanupRule(
                id: "xcode.devicesupport",
                title: "Xcode Device Support",
                explanation: "Symbol files Xcode downloaded for each iOS version it has debugged. Re-downloaded automatically when you connect that device again.",
                tier: .review,
                removal: .trash,
                kind: .directoryChildren,
                root: developer.appendingPathComponent("Xcode/iOS DeviceSupport")
            ),
            CleanupRule(
                id: "xcode.archives",
                title: "Xcode Archives",
                explanation: "Archived builds, including the dSYMs needed to symbolicate crash reports from shipped versions.",
                tier: .review,
                removal: .trash,
                kind: .directoryChildren,
                root: developer.appendingPathComponent("Xcode/Archives")
            ),
            CleanupRule(
                id: "ios.backups",
                title: "iOS Device Backups",
                explanation: "Local backups of iPhones and iPads. These may be the only copy of a device's data.",
                tier: .review,
                removal: .trash,
                kind: .directoryChildren,
                root: library.appendingPathComponent("Application Support/MobileSync/Backup"),
                needsFullDiskAccess: true
            ),
            CleanupRule(
                id: "downloads.old",
                title: "Old Downloads",
                explanation: "Files in ~/Downloads untouched for more than 90 days.",
                tier: .review,
                removal: .trash,
                kind: .directoryChildren,
                root: home.appendingPathComponent("Downloads"),
                minimumAge: 90 * 86_400
            ),
            CleanupRule(
                id: "app.leftovers",
                title: "Leftovers From Removed Apps",
                explanation: "Support folders named after an application that is no longer installed. Deleting one discards that app's settings and data for good.",
                tier: .review,
                removal: .trash,
                kind: .applicationLeftovers,
                root: library.appendingPathComponent("Application Support"),
                minimumSize: 1_000_000
            ),
            CleanupRule(
                id: "project.node_modules",
                title: "node_modules Folders",
                explanation: "Installed dependencies in your projects, untouched for more than 30 days. Restored by running your package manager's install command again.",
                tier: .review,
                removal: .trash,
                kind: .projectArtifacts(named: "node_modules"),
                root: home,
                minimumAge: 30 * 86_400,
                minimumSize: 50_000_000,
                isDeepScan: true
            ),
            CleanupRule(
                id: "docker.data",
                title: "Docker Desktop Data",
                explanation: "Docker keeps its images, containers and volumes inside a single virtual disk image.",
                tier: .review,
                removal: .trash,
                kind: .advisory(guidance: "Deleting files inside the disk image would not shrink it, and deleting the image itself would destroy every container, image and volume you have. Reclaim this space with Docker's own tooling — `docker system prune` — or from Docker Desktop's Disk settings."),
                root: home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms")
            ),
            CleanupRule(
                id: "files.large",
                title: "Large Files",
                explanation: "Files over 1 GB in your home folder, outside ~/Library. Listed so you can judge them; nothing here is presumed disposable.",
                tier: .review,
                removal: .trash,
                kind: .largeFiles,
                root: home,
                minimumSize: 1_000_000_000,
                isDeepScan: true
            ),
            CleanupRule(
                id: "files.duplicates",
                title: "Duplicate Files",
                explanation: "Byte-identical copies of files over 10 MB in your documents, downloads and media folders. Compared by content, not by name.",
                tier: .review,
                removal: .trash,
                kind: .duplicateFiles,
                root: home,
                minimumSize: 10_000_000,
                isDeepScan: true
            ),
        ]
    }

    /// Go's module cache is deliberately absent: it makes its own directories
    /// read-only, so a plain delete fails part-way through and leaves a broken
    /// cache behind. `go clean -modcache` is the only correct way to clear it.
    ///
    /// Directories the large-file and duplicate scans never descend into:
    /// application internals, package contents, and anything already covered by
    /// a dedicated rule.
    public static func excludedScanDirectories(home: URL) -> Set<String> {
        [
            home.appendingPathComponent("Library").path,
            home.appendingPathComponent(".Trash").path,
            home.appendingPathComponent(".cache").path,
            home.appendingPathComponent("Applications").path,
        ]
    }

    /// Folders that the duplicate scan looks at. Restricted to places where a
    /// duplicate is genuinely redundant rather than part of a project's layout.
    public static func duplicateScanRoots(home: URL) -> [URL] {
        ["Documents", "Downloads", "Desktop", "Pictures", "Movies", "Music"]
            .map { home.appendingPathComponent($0) }
    }
}
