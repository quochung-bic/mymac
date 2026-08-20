import Foundation

/// A throwaway directory tree used as a fake home for cleanup tests.
/// Nothing in these tests ever touches the real user's folders.
struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mymac-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let target = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func makeFile(_ relativePath: String, bytes: Int = 1024, modified: Date? = nil) throws -> URL {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: target)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
        }
        return target
    }

    @discardableResult
    func makeSymlink(_ relativePath: String, to destination: URL) throws -> URL {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination)
        return target
    }

    deinit {
        // Restore permissions first: a test may have made a directory read-only.
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            for case let relative as String in enumerator {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: url.appendingPathComponent(relative).path
                )
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
}
