import CoreTransferable
import Foundation
import MarinaCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag payload

extension UTType {
    /// Declared in the app bundle so a sidebar drag carries a Marina row and not
    /// loose text: every other app refuses it, and the sidebar refuses theirs.
    static let marinaSidebarRow = UTType(exportedAs: "dev.marina.app.sidebar-row")
}

/// One payload for both row kinds. A single `Transferable` type keeps every row
/// to one `dropDestination`, so a header that accepts projects *and* servers
/// does not have to stack two drop handlers and hope they agree.
struct SidebarDrag: Codable, Transferable, Equatable {
    enum Kind: String, Codable {
        case project
        case server
    }

    let kind: Kind
    let id: String

    static func project(_ id: String) -> SidebarDrag { SidebarDrag(kind: .project, id: id) }
    static func server(_ id: String) -> SidebarDrag { SidebarDrag(kind: .server, id: id) }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .marinaSidebarRow)
    }
}

// MARK: - Reordering

/// The list surgery behind sidebar drag and drop. Pure on purpose: index maths
/// this fiddly is worth unit-testing instead of eyeballing in a running window.
enum SidebarReorder {
    /// Where a server currently sits.
    struct ServerLocation: Equatable {
        let projectID: String
        let index: Int
    }

    static func locate(server id: String, in projects: [Project]) -> ServerLocation? {
        for project in projects {
            if let index = project.servers.firstIndex(where: { $0.id == id }) {
                return ServerLocation(projectID: project.id, index: index)
            }
        }
        return nil
    }

    /// Drops `id` on the row currently occupied by `targetID` and takes its slot.
    ///
    /// Inserting at the target's *original* index is what makes the gesture
    /// direction-aware: dragged downwards the row lands under the target,
    /// upwards it lands above it. That is also what keeps the last slot
    /// reachable without a separate drop zone at the end of the list.
    static func moveProject(in projects: [Project], id: String, onto targetID: String) -> [Project] {
        guard id != targetID,
              let from = projects.firstIndex(where: { $0.id == id }),
              let to = projects.firstIndex(where: { $0.id == targetID })
        else { return projects }

        var result = projects
        let moved = result.remove(at: from)
        result.insert(moved, at: to)
        return result
    }

    /// Same gesture one level down. Within a project it is direction-aware like
    /// projects are; arriving from another project the server lands above the
    /// row it was dropped on, because a cross-project drag has no direction to
    /// read.
    static func moveServer(in projects: [Project], id: String, ontoServer targetID: String) -> [Project] {
        guard id != targetID,
              let source = locate(server: id, in: projects),
              let target = locate(server: targetID, in: projects)
        else { return projects }

        var result = projects
        guard let moved = removeServer(id, from: &result),
              let destination = result.firstIndex(where: { $0.id == target.projectID })
        else { return projects }

        let insertion: Int
        if source.projectID == target.projectID {
            insertion = target.index
        } else if let index = result[destination].servers.firstIndex(where: { $0.id == targetID }) {
            insertion = index
        } else {
            return projects
        }

        result[destination].servers.insert(moved, at: insertion)
        return result
    }

    /// Dropping a server on a project header puts it first in that project: the
    /// header sits above every row, so "above the first one" is what the gesture
    /// looks like. It is also the only way to adopt a server into an empty
    /// project.
    static func moveServer(in projects: [Project], id: String, toTopOf projectID: String) -> [Project] {
        guard let source = locate(server: id, in: projects),
              projects.contains(where: { $0.id == projectID }),
              !(source.projectID == projectID && source.index == 0)
        else { return projects }

        var result = projects
        guard let moved = removeServer(id, from: &result),
              let destination = result.firstIndex(where: { $0.id == projectID })
        else { return projects }

        result[destination].servers.insert(moved, at: 0)
        return result
    }

    private static func removeServer(_ id: String, from projects: inout [Project]) -> ServerConfig? {
        for index in projects.indices {
            if let serverIndex = projects[index].servers.firstIndex(where: { $0.id == id }) {
                return projects[index].servers.remove(at: serverIndex)
            }
        }
        return nil
    }
}

// MARK: - Folding stopped servers

/// Which projects have their stopped servers folded away.
///
/// This lives in `UserDefaults`, not in `config.json`: it is a window
/// preference, and the CLI and the control API have no business reading — or
/// rewriting — it. Stored as newline-separated project IDs so `@AppStorage`
/// can hold it directly.
enum SidebarFold {
    static let storageKey = "sidebarFoldedStoppedProjects"

    static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    static func encode(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: "\n")
    }

    static func isFolded(_ projectID: String, in raw: String) -> Bool {
        decode(raw).contains(projectID)
    }

    /// Toggles one project and drops IDs that no longer exist, so removing a
    /// project cannot leave its fold state behind forever.
    static func toggling(_ projectID: String, in raw: String, existing projectIDs: [String]) -> String {
        var ids = decode(raw).intersection(Set(projectIDs))
        if ids.contains(projectID) {
            ids.remove(projectID)
        } else {
            ids.insert(projectID)
        }
        return encode(ids)
    }

    /// How many rows a fold would hide. `.failed` is deliberately not counted:
    /// folding is for quiet servers, never for problems.
    static func foldableCount(_ servers: [ServerConfig], state: (String) -> ServerState?) -> Int {
        servers.filter { state($0.id) == .stopped }.count
    }

    /// Rows a project shows. A folded project keeps everything that is not
    /// plainly stopped, plus the selected row — the sidebar must never hide what
    /// the detail pane is showing.
    static func visibleServers(
        _ servers: [ServerConfig],
        folded: Bool,
        state: (String) -> ServerState?,
        selectedServerID: String?
    ) -> [ServerConfig] {
        guard folded else { return servers }
        return servers.filter { server in
            server.id == selectedServerID || state(server.id) != .stopped
        }
    }
}
