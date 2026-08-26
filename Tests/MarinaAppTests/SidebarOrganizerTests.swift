@testable import MarinaApp
import MarinaCore
import UniformTypeIdentifiers
import XCTest

final class SidebarReorderTests: XCTestCase {
    private func project(_ id: String, servers: [String]) -> Project {
        Project(
            id: id,
            name: id,
            root: "/Users/me/Developer/\(id)",
            servers: servers.map { ServerConfig(id: $0, name: $0, command: "pnpm dev") }
        )
    }

    private var catalog: [Project] {
        [
            project("a", servers: ["a1", "a2", "a3"]),
            project("b", servers: ["b1"]),
            project("c", servers: []),
        ]
    }

    private func order(_ projects: [Project]) -> [String] { projects.map(\.id) }

    private func servers(_ projects: [Project], _ projectID: String) -> [String] {
        projects.first { $0.id == projectID }?.servers.map(\.id) ?? []
    }

    // MARK: - Projects

    func testDraggingAProjectDownLandsUnderTheRowItWasDroppedOn() {
        let result = SidebarReorder.moveProject(in: catalog, id: "a", onto: "b")

        XCTAssertEqual(order(result), ["b", "a", "c"])
    }

    func testDraggingAProjectUpLandsAboveTheRowItWasDroppedOn() {
        let result = SidebarReorder.moveProject(in: catalog, id: "c", onto: "a")

        XCTAssertEqual(order(result), ["c", "a", "b"])
    }

    func testDraggingAProjectOntoTheLastRowMakesItLast() {
        let result = SidebarReorder.moveProject(in: catalog, id: "a", onto: "c")

        XCTAssertEqual(order(result), ["b", "c", "a"])
    }

    func testUnknownOrSelfProjectDropChangesNothing() {
        XCTAssertEqual(order(SidebarReorder.moveProject(in: catalog, id: "a", onto: "a")), ["a", "b", "c"])
        XCTAssertEqual(order(SidebarReorder.moveProject(in: catalog, id: "zz", onto: "b")), ["a", "b", "c"])
        XCTAssertEqual(order(SidebarReorder.moveProject(in: catalog, id: "a", onto: "zz")), ["a", "b", "c"])
    }

    // MARK: - Servers

    func testDraggingAServerDownWithinItsProjectLandsUnderTheTarget() {
        let result = SidebarReorder.moveServer(in: catalog, id: "a1", ontoServer: "a3")

        XCTAssertEqual(servers(result, "a"), ["a2", "a3", "a1"])
    }

    func testDraggingAServerUpWithinItsProjectLandsAboveTheTarget() {
        let result = SidebarReorder.moveServer(in: catalog, id: "a3", ontoServer: "a1")

        XCTAssertEqual(servers(result, "a"), ["a3", "a1", "a2"])
    }

    func testDroppingAServerOnAnotherProjectsRowInsertsAboveThatRow() {
        let result = SidebarReorder.moveServer(in: catalog, id: "a2", ontoServer: "b1")

        XCTAssertEqual(servers(result, "a"), ["a1", "a3"])
        XCTAssertEqual(servers(result, "b"), ["a2", "b1"])
    }

    func testDroppingAServerOnAProjectHeaderPutsItFirstInThatProject() {
        let result = SidebarReorder.moveServer(in: catalog, id: "b1", toTopOf: "a")

        XCTAssertEqual(servers(result, "a"), ["b1", "a1", "a2", "a3"])
        XCTAssertEqual(servers(result, "b"), [])
    }

    func testAnEmptyProjectAdoptsAServerDroppedOnItsHeader() {
        let result = SidebarReorder.moveServer(in: catalog, id: "a1", toTopOf: "c")

        XCTAssertEqual(servers(result, "a"), ["a2", "a3"])
        XCTAssertEqual(servers(result, "c"), ["a1"])
    }

    func testHeaderDropOfAnAlreadyFirstServerChangesNothing() {
        let result = SidebarReorder.moveServer(in: catalog, id: "a1", toTopOf: "a")

        XCTAssertEqual(servers(result, "a"), ["a1", "a2", "a3"])
    }

    func testUnknownOrSelfServerDropChangesNothing() {
        XCTAssertEqual(servers(SidebarReorder.moveServer(in: catalog, id: "a1", ontoServer: "a1"), "a"), ["a1", "a2", "a3"])
        XCTAssertEqual(servers(SidebarReorder.moveServer(in: catalog, id: "zz", ontoServer: "a1"), "a"), ["a1", "a2", "a3"])
        XCTAssertEqual(servers(SidebarReorder.moveServer(in: catalog, id: "a1", ontoServer: "zz"), "a"), ["a1", "a2", "a3"])
        XCTAssertEqual(servers(SidebarReorder.moveServer(in: catalog, id: "a1", toTopOf: "zz"), "a"), ["a1", "a2", "a3"])
    }

    /// The drag payload declares its own type, which the app bundle exports.
    /// Instantiating it here proves an unbundled build cannot trip over it.
    func testDragPayloadCarriesMarinaOwnTypeAndRoundTrips() throws {
        XCTAssertEqual(UTType.marinaSidebarRow.identifier, "dev.marina.app.sidebar-row")

        let encoded = try JSONEncoder().encode(SidebarDrag.server("srv_web"))

        XCTAssertEqual(try JSONDecoder().decode(SidebarDrag.self, from: encoded), .server("srv_web"))
        XCTAssertNotEqual(SidebarDrag.server("prj_a"), .project("prj_a"))
    }

    func testLocateFindsTheProjectAndSlotOfAServer() {
        XCTAssertEqual(
            SidebarReorder.locate(server: "a2", in: catalog),
            SidebarReorder.ServerLocation(projectID: "a", index: 1)
        )
        XCTAssertNil(SidebarReorder.locate(server: "zz", in: catalog))
    }
}

final class SidebarFoldTests: XCTestCase {
    private let servers = [
        ServerConfig(id: "srv_web", name: "web", command: "next dev"),
        ServerConfig(id: "srv_redis", name: "redis", command: "redis-server"),
        ServerConfig(id: "srv_worker", name: "worker", command: "pnpm worker"),
        ServerConfig(id: "srv_broken", name: "broken", command: "pnpm broken"),
    ]

    private let states: [String: ServerState] = [
        "srv_web": .running,
        "srv_redis": .stopped,
        "srv_worker": .stopped,
        "srv_broken": .failed,
    ]

    private func state(_ id: String) -> ServerState? { states[id] }

    func testUnfoldedProjectShowsEveryServer() {
        let visible = SidebarFold.visibleServers(
            servers,
            folded: false,
            state: state,
            selectedServerID: nil
        )

        XCTAssertEqual(visible.map(\.id), ["srv_web", "srv_redis", "srv_worker", "srv_broken"])
    }

    func testFoldingHidesStoppedServersAndKeepsFailedOnesVisible() {
        let visible = SidebarFold.visibleServers(
            servers,
            folded: true,
            state: state,
            selectedServerID: nil
        )

        XCTAssertEqual(visible.map(\.id), ["srv_web", "srv_broken"])
    }

    func testFoldingNeverHidesTheSelectedServer() {
        let visible = SidebarFold.visibleServers(
            servers,
            folded: true,
            state: state,
            selectedServerID: "srv_worker"
        )

        XCTAssertEqual(visible.map(\.id), ["srv_web", "srv_worker", "srv_broken"])
    }

    func testFoldableCountCountsOnlyStoppedServers() {
        XCTAssertEqual(SidebarFold.foldableCount(servers, state: state), 2)
        XCTAssertEqual(SidebarFold.foldableCount([], state: state), 0)
    }

    func testTogglingFoldsAndUnfoldsOneProject() {
        let folded = SidebarFold.toggling("prj_a", in: "", existing: ["prj_a", "prj_b"])
        XCTAssertTrue(SidebarFold.isFolded("prj_a", in: folded))
        XCTAssertFalse(SidebarFold.isFolded("prj_b", in: folded))

        let unfolded = SidebarFold.toggling("prj_a", in: folded, existing: ["prj_a", "prj_b"])
        XCTAssertFalse(SidebarFold.isFolded("prj_a", in: unfolded))
    }

    func testTogglingDropsFoldStateOfProjectsThatNoLongerExist() {
        let stored = SidebarFold.encode(["prj_a", "prj_gone"])

        let result = SidebarFold.toggling("prj_b", in: stored, existing: ["prj_a", "prj_b"])

        XCTAssertEqual(SidebarFold.decode(result), ["prj_a", "prj_b"])
    }

    func testDecodeIgnoresBlankEntries() {
        XCTAssertEqual(SidebarFold.decode(""), [])
        XCTAssertEqual(SidebarFold.decode("\n\nprj_a\n"), ["prj_a"])
    }
}
