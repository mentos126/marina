import Foundation

/// Every on-disk location Marina uses. Deliberately outside any app sandbox so
/// the config stays hand-editable and an agent can read it without the app running.
public enum MarinaPaths {
    public static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("marina", isDirectory: true)
    }

    public static var configFile: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    /// Shared secret for the local control API. See `ControlToken`.
    public static var tokenFile: URL {
        configDirectory.appendingPathComponent("token")
    }

    public static var logsDirectory: URL {
        configDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    public static func logFile(forServer id: String) -> URL {
        logsDirectory.appendingPathComponent("\(id).log")
    }

    /// The single rotated generation kept beside the live log file.
    public static func rotatedLogFile(forServer id: String) -> URL {
        logFile(forServer: id).deletingPathExtension().appendingPathExtension("1.log")
    }

    /// Server output can contain database URLs, tokens, and request payloads, so
    /// a removed server must not leave its log behind.
    public static func removeLogs(forServer id: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: logFile(forServer: id))
        try? fm.removeItem(at: rotatedLogFile(forServer: id))
    }

    /// Mode 0600/0700 throughout: the config holds every server environment and
    /// the logs hold their output, so neither is other-readable.
    public static let filePermissions = 0o600
    public static let directoryPermissions = 0o700

    public static func ensureDirectories() {
        let fm = FileManager.default
        for directory in [configDirectory, logsDirectory] {
            try? fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
            // Tighten a directory created by an older version under the umask.
            try? fm.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: directory.path)
        }
    }

    /// Applies `filePermissions` to a file Marina just wrote. Foundation writes
    /// under the process umask (0644 by default), which is too wide for these.
    public static func restrictFile(at url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: filePermissions],
            ofItemAtPath: url.path
        )
    }
}
