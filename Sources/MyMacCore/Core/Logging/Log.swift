import OSLog

/// Central OSLog subsystem. Diagnostics go here, never to the user interface.
public enum Log {
    public static let subsystem = "com.mymac.app"

    public static let metrics = Logger(subsystem: subsystem, category: "metrics")
    public static let cleaner = Logger(subsystem: subsystem, category: "cleaner")
    public static let scanner = Logger(subsystem: subsystem, category: "scanner")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
