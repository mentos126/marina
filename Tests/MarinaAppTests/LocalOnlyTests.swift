import XCTest

/// Marina is a local-only tool: it must not reach the network on its own behalf.
/// These tests read the shipped sources rather than a runtime flag, because the
/// guarantee we care about is "no such code exists", not "the code is disabled".
final class LocalOnlyTests: XCTestCase {
    private static let allowedHosts: Set<String> = ["localhost", "127.0.0.1", "[", "0.0.0.0", "::1"]

    func testNoSourceFileNamesARemoteHost() throws {
        var offenders: [String] = []

        for file in try Self.swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for host in Self.hosts(in: text) where !Self.allowedHosts.contains(host) {
                offenders.append("\(file.lastPathComponent): \(host)")
            }
        }

        XCTAssertEqual(
            offenders, [],
            "Marina must only ever address loopback. Remote hosts found: \(offenders.joined(separator: ", "))"
        )
    }

    func testNoUpdateFrameworkIsLinked() throws {
        for file in try Self.swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                text.contains("import Sparkle"),
                "\(file.lastPathComponent) imports Sparkle; the app must not check for updates."
            )
        }

        let manifest = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("Sparkle"), "Package.swift must not depend on an update framework.")
    }

    func testTheBundleDeclaresNoUpdateFeed() throws {
        let build = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("build.sh"), encoding: .utf8)
        for key in ["SUFeedURL", "SUPublicEDKey", "SUScheduledCheckInterval", "appcast"] {
            XCTAssertFalse(build.contains(key), "build.sh still writes \(key) into the app bundle.")
        }
    }

    func testAnalyticsAreGone() throws {
        for file in try Self.swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                text.contains("MarinaAnalytics"),
                "\(file.lastPathComponent) references analytics, which the app no longer has."
            )
        }
    }

    // MARK: - Helpers

    /// The repo root, walked up from this file rather than from the working
    /// directory, so the test passes wherever `swift test` is invoked from.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MarinaAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private static func swiftSources() throws -> [URL] {
        let sources = repositoryRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return []
        }
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "No sources were scanned; the walk is broken, not clean.")
        return files
    }

    /// Every host that follows an `http://` or `https://` in the text. A scheme
    /// with nothing after it (a `hasPrefix` check) yields an empty host and is
    /// not reported.
    private static func hosts(in text: String) -> [String] {
        var found: [String] = []
        for scheme in ["http://", "https://"] {
            var index = text.startIndex
            while let range = text.range(of: scheme, range: index..<text.endIndex) {
                index = range.upperBound
                let terminators: Set<Character> = ["/", "\"", "'", ":", " ", ")", "\\", "<", "\n"]
                var host = ""
                var cursor = range.upperBound
                while cursor < text.endIndex, !terminators.contains(text[cursor]) {
                    host.append(text[cursor])
                    cursor = text.index(after: cursor)
                }
                if !host.isEmpty { found.append(host) }
            }
        }
        return found
    }
}
