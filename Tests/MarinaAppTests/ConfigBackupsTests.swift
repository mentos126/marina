import MarinaCore
import XCTest

/// The safety net behind one-click removal: what the config looked like before
/// the write that lost it.
final class ConfigBackupsTests: XCTestCase {
    private var root: URL!
    private var configURL: URL!
    private var backups: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("marina-backups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        configURL = root.appendingPathComponent("config.json")
        backups = ConfigBackups.directory(forConfigAt: configURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func write(_ projects: [Project]) throws {
        var config = MarinaConfig()
        config.projects = projects
        try ConfigStore.write(config, to: configURL)
    }

    private func project(_ id: String, servers: [ServerConfig] = []) -> Project {
        Project(id: id, name: id, root: "/tmp/\(id)", servers: servers)
    }

    private var kept: [URL] { ConfigBackups.existing(in: backups) }

    func testFirstWriteHasNothingToBackUp() throws {
        try write([project("prj_a")])

        XCTAssertTrue(kept.isEmpty)
    }

    func testRemovingEverySeverKeepsThePreviousGenerationOnDisk() throws {
        let server = ServerConfig(id: "srv_web", name: "web", command: "npm run dev", port: 3000)
        try write([project("prj_a", servers: [server])])

        try write([project("prj_a")])

        XCTAssertEqual(kept.count, 1)
        let restored = ConfigStore.read(from: try XCTUnwrap(kept.first))
        XCTAssertEqual(restored?.projects.first?.servers.map(\.name), ["web"])
    }

    func testBackupsAreNotOtherReadable() throws {
        try write([project("prj_a", servers: [
            ServerConfig(id: "srv_web", name: "web", command: "npm run dev", port: 3000),
        ])])
        try write([project("prj_a")])

        let attributes = try FileManager.default.attributesOfItem(atPath: try XCTUnwrap(kept.first).path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, MarinaPaths.filePermissions)
    }

    func testAnUnchangedWriteLeavesNoSnapshot() throws {
        try write([project("prj_a")])
        try write([project("prj_a")])
        try write([project("prj_a")])

        XCTAssertTrue(kept.isEmpty)
    }

    func testSavesInsideOneSecondDoNotOverwriteEachOther() throws {
        try write([project("prj_a")])
        try write([project("prj_b")])
        try write([project("prj_c")])

        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(Set(kept.map(\.lastPathComponent)).count, 2)
    }

    func testOnlyTheNewestGenerationsSurvive() throws {
        for index in 0...(ConfigBackups.generations + 5) {
            try write([project("prj_\(index)")])
        }

        XCTAssertEqual(kept.count, ConfigBackups.generations)
        // Newest first, and the newest holds the state just before the last write.
        let newest = ConfigStore.read(from: try XCTUnwrap(kept.first))
        XCTAssertEqual(newest?.projects.first?.id, "prj_\(ConfigBackups.generations + 4)")
    }

    func testBackupsStayBesideTheirOwnConfig() {
        XCTAssertEqual(backups.standardizedFileURL.path, root.appendingPathComponent("backups").path)
        XCTAssertNotEqual(backups.standardizedFileURL.path, MarinaPaths.backupsDirectory.path)
    }
}
