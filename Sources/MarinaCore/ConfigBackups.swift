import Foundation

/// Timestamped copies of `config.json`, taken just before Marina overwrites it.
///
/// The config file is the only record of what a project and its servers are:
/// there is no versioned history, and removing a server also deletes its logs.
/// So every write that genuinely changes the file leaves the previous generation
/// behind, and restoring one is a `cp` away — the store watches the file, so a
/// running app picks the restored config up live.
public enum ConfigBackups {
    /// Generations kept. Twenty covers a long session of edits without turning
    /// the directory into an archive of every config Marina has ever held.
    public static let generations = 20

    /// Backups live beside the config they belong to, so a config opened from a
    /// temporary path — a test, a second profile — keeps its history there and
    /// never writes into the real `~/.config/marina`.
    public static func directory(forConfigAt url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
    }

    /// Snapshots the file currently at `url` if `data` is about to change it.
    ///
    /// Called on the write path, so it never throws: a backup that cannot be
    /// written must not stop the user from saving their config.
    public static func snapshot(before data: Data, replacing url: URL) {
        guard let current = try? Data(contentsOf: url), current != data else { return }
        let directory = directory(forConfigAt: url)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: MarinaPaths.directoryPermissions]
        )
        guard let destination = availableURL(in: directory, for: Date()) else { return }
        guard (try? current.write(to: destination, options: .atomic)) != nil else { return }
        // A snapshot holds the same server environments as the config it copies.
        MarinaPaths.restrictFile(at: destination)
        prune(in: directory)
    }

    /// Every kept generation, newest first. The names sort chronologically, so
    /// the listing needs no stat call per file.
    public static func existing(in directory: URL = MarinaPaths.backupsDirectory) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return all
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - Naming

    private static let prefix = "config-"

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter
    }()

    /// Two saves inside the same millisecond are unlikely but not impossible, so
    /// the stamp carries a counter rather than overwriting the older snapshot.
    ///
    /// Names must grow strictly, because `existing()` orders by name and
    /// `prune()` frees the names it deletes: picking the lowest unused counter
    /// would hand the newest snapshot a name the sort reads as the oldest, and
    /// the next prune would delete it. So the counter continues from the highest
    /// one already on disk for this millisecond instead of filling the gaps.
    /// Both fields are fixed width, which keeps the plain string sort honest.
    private static func availableURL(in directory: URL, for date: Date) -> URL? {
        let base = prefix + stamp.string(from: date)
        let used = existing(in: directory).compactMap { url -> Int? in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(base + "-") else { return nil }
            return Int(name.dropFirst(base.count + 1))
        }
        let next = (used.max().map { $0 + 1 }) ?? 0
        guard next < 100 else { return nil }
        return directory
            .appendingPathComponent(String(format: "%@-%02d", base, next))
            .appendingPathExtension("json")
    }

    private static func prune(in directory: URL) {
        for url in existing(in: directory).dropFirst(generations) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
