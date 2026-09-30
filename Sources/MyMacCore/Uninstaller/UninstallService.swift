import Foundation

/// Removes an installed application or package.
///
/// Applications and their support files go to the Trash, never straight out —
/// an uninstall is exactly the kind of decision people reverse. Packages are
/// handed to their own manager, because deleting a package's files by hand
/// leaves that manager's bookkeeping inconsistent.
public actor UninstallService {
    public struct Outcome: Sendable {
        public let trashedCount: Int
        public let reclaimedBytes: Int64
        public let toolOutput: String?
        public let failures: [CleanupOutcome.Failure]
        /// Whether the thing the user pointed at is gone, regardless of what
        /// happened to its support files.
        public let removedTheItemItself: Bool

        public var succeeded: Bool { failures.isEmpty }
    }

    /// One item to remove, with the allowlist it has to clear. A bundle and a
    /// leftover are validated against different roots and different depth
    /// floors, so the loop carries both rather than assuming one policy.
    private struct Target {
        let url: URL
        let size: Int64
        let roots: [URL]
        let minimumDepth: Int
    }

    private let home: URL
    private let fileManager: FileManager

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                fileManager: FileManager = .default) {
        self.home = home
        self.fileManager = fileManager
    }

    public func uninstall(_ item: InstalledItem, leftovers: [CleanupItem]) async -> Outcome {
        switch item.source {
        case .application:
            return await removeApplication(item, leftovers: leftovers)
        case .package(let ecosystem):
            return await removePackage(item, ecosystem: ecosystem)
        }
    }

    // MARK: - Applications

    private func removeApplication(_ item: InstalledItem, leftovers: [CleanupItem]) async -> Outcome {
        let context = PathSafety.Context(home: home)

        // A cask's bundle goes back through Homebrew: trashing it by hand
        // leaves brew sure it is still installed, and its next upgrade acts on
        // something that is gone.
        let bundle: Outcome
        if let cask = item.cask {
            bundle = await runManager(.homebrewCask, package: cask.token,
                                      at: item.location, near: cask.record, size: item.size)
        } else {
            bundle = trash(Target(url: item.location, size: item.size ?? 0,
                                  roots: ApplicationCatalog.searchLocations(home: home),
                                  minimumDepth: PathSafety.minimumApplicationDepth),
                           context: context)
        }

        // Support files only once the application itself is gone. Trashing the
        // settings of an app that is still installed leaves it on defaults.
        guard bundle.removedTheItemItself else {
            guard !leftovers.isEmpty else { return bundle }
            let note = CleanupOutcome.Failure(
                path: item.name,
                reason: "\(leftovers.count) support file\(leftovers.count == 1 ? " was" : "s were") left in place, because \(item.name) is still installed."
            )
            return Outcome(trashedCount: bundle.trashedCount, reclaimedBytes: bundle.reclaimedBytes,
                           toolOutput: bundle.toolOutput, failures: bundle.failures + [note],
                           removedTheItemItself: false)
        }

        let leftoverRoots = LeftoverScanner.searchRoots(home: home)
        let rest = leftovers.map {
            trash(Target(url: $0.url, size: $0.size, roots: leftoverRoots,
                         minimumDepth: PathSafety.minimumDepth),
                  context: context)
        }
        return Outcome(trashedCount: bundle.trashedCount + rest.reduce(0) { $0 + $1.trashedCount },
                       reclaimedBytes: bundle.reclaimedBytes + rest.reduce(0) { $0 + $1.reclaimedBytes },
                       toolOutput: bundle.toolOutput,
                       failures: bundle.failures + rest.flatMap(\.failures),
                       removedTheItemItself: true)
    }

    /// Validates one path immediately before touching it, then moves it to the
    /// Trash. A path that has already gone counts as removed, not as a failure.
    private func trash(_ target: Target, context: PathSafety.Context) -> Outcome {
        do {
            let path = try PathSafety.canonicalPathForRemoval(
                of: target.url, allowedRoots: target.roots,
                minimumDepth: target.minimumDepth, context: context
            )
            try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return Outcome(trashedCount: 1, reclaimedBytes: target.size, toolOutput: nil,
                           failures: [], removedTheItemItself: true)
        } catch let violation as PathSafety.Violation {
            guard violation != .doesNotExist else {
                return Outcome(trashedCount: 0, reclaimedBytes: 0, toolOutput: nil,
                               failures: [], removedTheItemItself: true)
            }
            Log.cleaner.error("refused \(target.url.path, privacy: .private): \(violation.reason)")
            return Outcome(trashedCount: 0, reclaimedBytes: 0, toolOutput: nil,
                           failures: [.init(path: target.url.path, reason: violation.reason)],
                           removedTheItemItself: false)
        } catch {
            return Outcome(trashedCount: 0, reclaimedBytes: 0, toolOutput: nil,
                           failures: [.init(path: target.url.path, reason: Self.describe(error))],
                           removedTheItemItself: false)
        }
    }

    /// Cocoa's error codes, in words a person can act on.
    private nonisolated static func describe(_ error: Error) -> String {
        guard let cocoa = error as? CocoaError else { return error.localizedDescription }
        switch cocoa.code {
        case .fileWriteNoPermission, .fileReadNoPermission:
            return "Permission denied. Applications installed for all users may need an administrator."
        case .fileNoSuchFile:
            return "The item no longer exists."
        default:
            return cocoa.localizedDescription
        }
    }

    // MARK: - Packages

    private func removePackage(_ item: InstalledItem, ecosystem: PackageEcosystem) async -> Outcome {
        if let refusal = ecosystem.refusal(home: home, near: item.location) {
            return Outcome(trashedCount: 0, reclaimedBytes: 0, toolOutput: nil,
                           failures: [.init(path: item.name, reason: refusal)],
                           removedTheItemItself: false)
        }
        return await runManager(ecosystem, package: item.name, at: item.location,
                                near: item.location, size: item.size)
    }

    /// Asks a package manager to remove `package`, then checks that `location`
    /// is really gone.
    ///
    /// - Parameter near: where the tool should come from. Running an arm64
    ///   brew against an x86_64 formula fails in a way that reads like the
    ///   package is broken rather than mismatched.
    private func runManager(_ ecosystem: PackageEcosystem, package: String, at location: URL,
                            near: URL, size: Int64?) async -> Outcome {
        do {
            try CommandRunner.validate(package)
            guard let executable = CommandRunner.firstExecutable(
                among: ecosystem.executables(home: home, near: near)
            ) else {
                throw CommandRunner.Failure.executableNotFound
            }
            // Checked before the tool runs: a location that was never there
            // cannot be used to judge what the tool did afterwards.
            let existedBefore = fileManager.fileExists(atPath: location.path)
            let output = try await CommandRunner.run(
                executable: executable,
                arguments: ecosystem.uninstallArguments(for: package)
            )
            // Every manager here has a path that exits 0 having done nothing:
            // `npm uninstall --global` says "up to date", `pip uninstall` says
            // "Skipping … as it is not installed". That happens whenever the
            // tool resolved is not the one owning the prefix this row came
            // from — a second Homebrew, another interpreter's pip. Reporting
            // that as a removal drops the row and leaves the package installed.
            if existedBefore, fileManager.fileExists(atPath: location.path) {
                return Outcome(
                    trashedCount: 0, reclaimedBytes: 0, toolOutput: output,
                    failures: [.init(path: location.path,
                                     reason: "\(ecosystem.title) reported success but the package is still installed. It was probably installed by a different copy of the tool.")],
                    removedTheItemItself: false
                )
            }
            return Outcome(trashedCount: 1, reclaimedBytes: size ?? 0,
                           toolOutput: output, failures: [], removedTheItemItself: true)
        } catch let failure as CommandRunner.Failure {
            Log.cleaner.error("uninstall failed for \(package, privacy: .public): \(failure.message)")
            return Outcome(trashedCount: 0, reclaimedBytes: 0, toolOutput: nil,
                           failures: [.init(path: package, reason: failure.message)],
                           removedTheItemItself: false)
        } catch {
            return Outcome(trashedCount: 0, reclaimedBytes: 0, toolOutput: nil,
                           failures: [.init(path: package, reason: error.localizedDescription)],
                           removedTheItemItself: false)
        }
    }

    /// Measures an item on demand, so a list of forty applications does not have
    /// to walk forty bundles before it can be shown.
    ///
    /// `nil` when there is nothing at the location to measure. The size column
    /// shows "…" for that and a flatly wrong "0 B" for a zero — and the two are
    /// not the same thing: a Python distribution's name need not match any
    /// directory, so `pillow`'s row points at a path that was never there.
    public nonisolated static func measure(_ item: InstalledItem) -> Int64? {
        guard FileManager.default.fileExists(atPath: item.location.path) else { return nil }
        return (try? DirectorySizer.measure(item.location))?.bytes
    }
}
