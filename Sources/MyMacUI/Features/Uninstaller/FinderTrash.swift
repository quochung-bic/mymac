import Foundation

/// Trashes a path through Finder, which asks for an administrator password
/// itself when the item is owned by root. This app never holds that password
/// and never runs as root.
enum FinderTrash {
    struct Failure: LocalizedError {
        let code: Int
        let detail: String

        var errorDescription: String? {
            switch code {
            case -128: "The administrator password prompt was cancelled."
            case -1743: "Allow MyMac to control Finder in System Settings → Privacy & Security → Automation, then try again."
            default: detail
            }
        }
    }

    static func trash(_ path: String) throws {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Finder\" to delete POSIX file \"\(escaped)\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            throw Failure(code: error[NSAppleScript.errorNumber] as? Int ?? 0,
                          detail: error[NSAppleScript.errorMessage] as? String ?? "Finder could not remove it.")
        }
    }
}
