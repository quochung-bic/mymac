import Foundation

/// PEP 668: a Python whose standard library holds an `EXTERNALLY-MANAGED` file
/// belongs to a distributor — Homebrew, on most Macs — and its pip refuses to
/// change it, uninstalling included.
enum PythonEnvironment {
    /// Whether the interpreter behind `pip` is externally managed, read from
    /// disk rather than by running pip: the script's shebang names the
    /// interpreter, and the marker sits in that interpreter's `lib/pythonX.Y`.
    ///
    /// Both the interpreter as named and as resolved are checked. Homebrew's
    /// shebang names `Cellar/python@3.14/<version>/bin/python3.14`, a link into
    /// `Frameworks/Python.framework/Versions/3.14`, and only the latter holds
    /// the marker.
    ///
    /// Anything that cannot be followed — `#!/usr/bin/env python3`, a binary
    /// launcher — answers `false`, so the tool runs and answers for itself.
    static func isExternallyManaged(pip: URL) -> Bool {
        guard let interpreter = shebangInterpreter(of: pip) else { return false }
        let named = URL(fileURLWithPath: interpreter)
        let resolved = URL(fileURLWithPath: PathSafety.canonicalPath(interpreter))
        let name = named.lastPathComponent
        let version = name.hasPrefix("python") ? name.dropFirst("python".count) : ""

        return [named, resolved].contains { binary in
            let lib = binary.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lib")
            return markerExists(in: lib, version: version)
        }
    }

    /// `3.14` for a pip whose shebang names `python3.14`; `nil` when the
    /// interpreter's name does not say.
    static func version(ofPip pip: URL) -> String? {
        shebangInterpreter(of: pip).flatMap { dottedVersion(URL(fileURLWithPath: $0).lastPathComponent) }
    }

    /// The Python a package location belongs to, from the directory that
    /// names it: `lib/python3.13/site-packages`, or the `3.9` in
    /// `~/Library/Python/3.9/lib/python/site-packages`.
    static func version(ofSitePackagesAt location: URL) -> String? {
        location.pathComponents.reversed().lazy.compactMap(dottedVersion).first
    }

    /// `python3.14` or `3.14` → `3.14`; anything else → `nil`.
    private static func dottedVersion(_ component: String) -> String? {
        let digits = component.hasPrefix("python") ? component.dropFirst("python".count) : Substring(component)
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return String(digits)
    }

    private static func shebangInterpreter(of script: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: script) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512), head.starts(with: Array("#!".utf8))
        else { return nil }

        let line = String(decoding: head.dropFirst(2).prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
        guard let path = line.split(whereSeparator: \.isWhitespace).first.map(String.init),
              path.hasPrefix("/"),
              URL(fileURLWithPath: path).lastPathComponent != "env"
        else { return nil }
        return path
    }

    /// `python3.14` names its directory; a bare `python3` does not, so every
    /// `python3.*` beside it is checked instead.
    private static func markerExists(in lib: URL, version: Substring) -> Bool {
        let manager = FileManager.default
        let directories = version.contains(".")
            ? ["python\(version)"]
            : ((try? manager.contentsOfDirectory(atPath: lib.path)) ?? []).filter { $0.hasPrefix("python3.") }
        return directories.contains {
            manager.fileExists(atPath: lib.appendingPathComponent($0)
                .appendingPathComponent("EXTERNALLY-MANAGED").path)
        }
    }
}
