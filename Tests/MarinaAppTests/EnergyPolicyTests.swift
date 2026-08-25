@testable import MarinaApp
import XCTest

final class EnergyPolicyTests: XCTestCase {
    private func conditions(
        dashboard: Bool = false,
        window: Bool = false,
        servers: Bool = false,
        controlAPI: Bool = false,
        memoryLimits: Bool = false,
        asleep: Bool = false,
        lowPower: Bool = false
    ) -> EnergyConditions {
        EnergyConditions(
            dashboardSelected: dashboard,
            windowVisible: window,
            hasRunningServers: servers,
            controlAPIActive: controlAPI,
            enforcesMemoryLimits: memoryLimits,
            asleep: asleep,
            lowPower: lowPower
        )
    }

    func testIdleAppDoesNotSample() {
        XCTAssertNil(EnergyPolicy.cadence(for: conditions()))
    }

    func testSleepSuspendsSamplingEvenWithServersAndDashboard() {
        XCTAssertNil(EnergyPolicy.cadence(for: conditions(
            dashboard: true, window: true, servers: true, asleep: true
        )))
    }

    func testVisibleDashboardKeepsFullFidelity() {
        let cadence = EnergyPolicy.cadence(for: conditions(dashboard: true, window: true, servers: true))
        XCTAssertEqual(cadence?.interval, EnergyPolicy.observedInterval)
        XCTAssertEqual(cadence?.includesExternalProcesses, true)
        XCTAssertEqual(cadence?.allowsExternalDetails, true)
    }

    func testDashboardBehindAHiddenWindowIsNotObserved() {
        let cadence = EnergyPolicy.cadence(for: conditions(dashboard: true, window: false, servers: true))
        XCTAssertEqual(cadence?.interval, EnergyPolicy.unobservedInterval)
        XCTAssertEqual(cadence?.includesExternalProcesses, false)
    }

    func testVisibleWindowWithoutDashboardSkipsTheLsofEnrichment() {
        let cadence = EnergyPolicy.cadence(for: conditions(window: true, servers: true))
        XCTAssertEqual(cadence?.interval, EnergyPolicy.windowInterval)
        XCTAssertEqual(cadence?.allowsExternalDetails, false)
    }

    func testRunningServersKeepTheMemoryGuardFedWhileUnobserved() {
        let cadence = EnergyPolicy.cadence(for: conditions(servers: true))
        XCTAssertEqual(cadence?.interval, EnergyPolicy.unobservedInterval)
    }

    func testControlAPIActivityKeepsTheSamplerWarmWithNoWindow() {
        let cadence = EnergyPolicy.cadence(for: conditions(servers: true, controlAPI: true))
        XCTAssertEqual(cadence?.interval, EnergyPolicy.windowInterval)
    }

    func testAnArmedMemoryLimitKeepsTheGuardResponsiveWithNothingOnScreen() {
        let cadence = EnergyPolicy.cadence(for: conditions(servers: true, memoryLimits: true))
        XCTAssertEqual(cadence?.interval, EnergyPolicy.guardedInterval)
        // Three consecutive over-limit samples still trigger inside a quarter
        // minute, and the enrichment nobody reads stays off.
        XCTAssertLessThan((cadence?.interval ?? 0) * 3, 20)
        XCTAssertEqual(cadence?.allowsExternalDetails, false)
    }

    func testAnArmedMemoryLimitDoesNotSampleWithNoServerRunning() {
        XCTAssertNil(EnergyPolicy.cadence(for: conditions(memoryLimits: true)))
    }

    func testEveryCadenceCarriesTolerance() {
        let all = [
            conditions(dashboard: true, window: true, servers: true),
            conditions(window: true, servers: true),
            conditions(servers: true),
            conditions(servers: true, memoryLimits: true),
        ].compactMap(EnergyPolicy.cadence(for:))

        XCTAssertEqual(all.count, 4)
        for cadence in all {
            XCTAssertGreaterThan(cadence.tolerance, 0)
            XCTAssertLessThanOrEqual(cadence.tolerance, cadence.interval)
        }
    }

    func testLowPowerModeHalvesTheRateAndDropsEnrichment() {
        let normal = EnergyPolicy.cadence(for: conditions(dashboard: true, window: true, servers: true))
        let saving = EnergyPolicy.cadence(for: conditions(
            dashboard: true, window: true, servers: true, lowPower: true
        ))

        XCTAssertEqual(saving?.interval, (normal?.interval ?? 0) * 2)
        XCTAssertEqual(saving?.allowsExternalDetails, false)
        XCTAssertEqual(saving?.includesExternalProcesses, true)
    }

    func testLowPowerModeNeverRevivesASuspendedSampler() {
        XCTAssertNil(EnergyPolicy.cadence(for: conditions(lowPower: true)))
    }
}
