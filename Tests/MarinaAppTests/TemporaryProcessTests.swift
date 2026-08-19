@testable import MarinaApp
import MarinaCore
import XCTest

@MainActor
final class TemporaryProcessTests: XCTestCase {
    func testServerConfigDecodesOlderPayloadWithoutActions() throws {
        let payload = Data(#"{"name":"web","command":"pnpm dev"}"#.utf8)

        let server = try MarinaAPI.decoder().decode(ServerConfig.self, from: payload)

        XCTAssertTrue(server.actions.isEmpty)
    }

    func testServerActionsRoundTripThroughConfig() throws {
        let server = ServerConfig(
            name: "web",
            command: "pnpm dev",
            actions: [ServerAction(name: "clear-cache", command: "trash .next/cache")]
        )

        let data = try MarinaAPI.encoder().encode(server)
        let decoded = try MarinaAPI.decoder().decode(ServerConfig.self, from: data)

        XCTAssertEqual(decoded.actions, server.actions)
    }

    func testMarinaStatusDecodesOlderPayloadWithoutTemporaryServers() throws {
        let payload = Data(#"{"version":"0.1.10","apiPort":7737,"projects":[]}"#.utf8)

        let status = try MarinaAPI.decoder().decode(MarinaStatus.self, from: payload)

        XCTAssertTrue(status.temporaryServers.isEmpty)
    }

    func testManagedRuleUpgradeReplacesOldBlockAndPreservesSurroundings() {
        let old = """
        Before
        <!-- marina:managed-rule:start -->
        old rule
        <!-- marina:managed-rule:end -->
        After
        """

        let updated = AgentSetup.installManagedRule(in: old)

        XCTAssertTrue(updated.contains("Before"))
        XCTAssertTrue(updated.contains("After"))
        XCTAssertTrue(updated.contains("marina temp '<command>'"))
        XCTAssertTrue(updated.contains("marina wait \"$job_id\""))
        XCTAssertTrue(updated.contains("exits with code `124`"))
        XCTAssertFalse(updated.contains("old rule"))
        XCTAssertEqual(updated.components(separatedBy: "marina:managed-rule:start").count - 1, 1)
    }

    func testManagedRuleUpgradeDropsTheBlockFromTheOldProductName() {
        let old = """
        Before
        <!-- portly:managed-rule:start -->
        - Always use Portly (`portly ...`) to start local development servers.
        <!-- portly:managed-rule:end -->
        After
        """

        let updated = AgentSetup.installManagedRule(in: old)

        XCTAssertTrue(updated.contains("Before"))
        XCTAssertTrue(updated.contains("After"))
        XCTAssertFalse(updated.lowercased().contains("portly"))
        XCTAssertEqual(updated.components(separatedBy: "marina:managed-rule:start").count - 1, 1)
    }

    func testManagedRuleInstallsCleanlyOverAFileHoldingOnlyTheOldBlock() {
        let old = """
        <!-- portly:managed-rule:start -->
        - Always use Portly (`portly ...`).
        <!-- portly:managed-rule:end -->
        """

        let updated = AgentSetup.installManagedRule(in: old)

        XCTAssertTrue(updated.hasPrefix("<!-- marina:managed-rule:start -->"))
        XCTAssertFalse(updated.lowercased().contains("portly"))
    }

    func testTemporaryTimeoutParsesFriendlyDurations() {
        XCTAssertEqual(TemporaryTimeout.parse("45"), 45)
        XCTAssertEqual(TemporaryTimeout.parse("30s"), 30)
        XCTAssertEqual(TemporaryTimeout.parse("1.5m"), 90)
        XCTAssertEqual(TemporaryTimeout.parse("2h"), 7_200)
        XCTAssertNil(TemporaryTimeout.parse("0"))
        XCTAssertNil(TemporaryTimeout.parse("forever"))
        XCTAssertNil(TemporaryTimeout.parse("8d"))
    }

    func testTemporaryJobMapsTerminalStateToShellExitCode() {
        let base = TemporaryJobStatus(
            id: "tmp_test",
            name: "build",
            command: "npm run build",
            directory: "/tmp",
            state: .succeeded,
            pid: nil,
            startedAt: Date(),
            finishedAt: Date(),
            timeoutSeconds: 60,
            deadline: Date(),
            exitCode: 0,
            error: nil
        )

        XCTAssertEqual(base.processExitCode, 0)
        var failed = base
        failed.state = .failed
        failed.exitCode = 7
        XCTAssertEqual(failed.processExitCode, 7)
        var timedOut = base
        timedOut.state = .timedOut
        timedOut.exitCode = nil
        XCTAssertEqual(timedOut.processExitCode, 124)
    }

    func testRawWaitStatusIsNormalizedBeforeExposingExitCode() {
        XCTAssertEqual(ServerRuntime.normalizedProcessExitCode(0), 0)
        XCTAssertEqual(ServerRuntime.normalizedProcessExitCode(7 << 8), 7)
        XCTAssertEqual(ServerRuntime.normalizedProcessExitCode(15), 143)
        XCTAssertNil(ServerRuntime.normalizedProcessExitCode(nil))
    }
}
