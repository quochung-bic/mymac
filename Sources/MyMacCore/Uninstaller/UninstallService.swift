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

        public var succeeded: Bool { failures.isEmpty }
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
            return removeApplication(item, leftovers: leftovers)
        case .package(let ecosystem):
            return await removePackage(item, ecosystem: ecosystem)
        }
    }

    // MARK: - Applications

    private func removeApplication(_ item: InstalledItem, leftovers: [CleanupItem]) -> Outcome {
        var trashed = 0
        var reclaimed: Int64 = 0
        var failures: [CleanupOutcome.Failure] = []

        // The bundle itself is validated against the folders applications are
        // installed in, and each leftover against the folders it was found in.
        let applicationRoots = ApplicationCatalog.searchLocations(home: home)
        let context = PathSafety.Context(home: home)

        let leftoverRoots = LeftoverScanner.searchRoots(home: home)
        let targets = [(item.location, item.size ?? 0, applicationRoots)]
            + leftovers.map { ($0.url, $0.size, leftoverRoots) }

        for (url, size, roots) in targets {
            do {
                let path = try PathSafety.canonicalPathForRemoval(of: url, allowedRoots: roots, context: context)
                try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                trashed += 1
                reclaimed += size
            } catch let violation as PathSafety.Violation {
                guard violation != .doesNotExist else { continue }
                Log.cleaner.error("refused \(url.path, privacy: .private): \(violation.reason)")
                failures.append(.init(path: url.path, reason: violation.reason))
            } catch {
                failures.append(.init(path: url.path, reason: Self.describe(error)))
            }
        }

        return Outcome(trashedCount: trashed, reclaimedBytes: reclaimed,
                       toolOutput: nil, failures: failures)
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
        do {
            try CommandRunner.validate(item.name)
            guard let executable = CommandRunner.firstExecutable(among: ecosystem.executables(home: home)) else {
                throw CommandRunner.Failure.executableNotFound
            }
            let output = try await CommandRunner.run(
                executable: executable,
                arguments: ecosystem.uninstallArguments(for: item.name)
            )
            return Outcome(trashedCount: 1, reclaimedBytes: item.size ?? 0,
                           toolOutput: output, failures: [])
        } catch let failure as CommandRunner.Failure {
            Log.cleaner.error("uninstall failed for \(item.name, privacy: .public): \(failure.message)")
            return Outcome(trashedCount: 0, reclaimedBytes: 0, toolOutput: nil,
                           failures: [.init(path: item.name, reason: failure.message)])
        } catch {
            return Outcome(trashedCount: 0, reclaimedBytes: 0, toolOutput: nil,
                           failures: [.init(path: item.name, reason: error.localizedDescription)])
        }
    }

    /// Measures an item on demand, so a list of forty applications does not have
    /// to walk forty bundles before it can be shown.
    public nonisolated static func measure(_ item: InstalledItem) -> Int64 {
        ((try? DirectorySizer.measure(item.location))?.bytes) ?? 0
    }
}
