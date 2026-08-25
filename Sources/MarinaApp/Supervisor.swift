import AppKit
import Foundation
import MarinaCore

struct ResourceHistoryPoint: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let footprintBytes: UInt64
    let residentBytes: UInt64
    let cpuPercent: Double
    let processCount: Int
}

struct ProjectResourceHistoryPoint: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let projectID: String
    let projectName: String
    let colorHex: String
    let footprintBytes: UInt64
    let residentBytes: UInt64
}

/// Owns the config and one `ServerRuntime` per configured server. Single source
/// of truth for the UI, the control API and the config file.
final class Supervisor: ObservableObject {
    static let shared = Supervisor()

    @Published private(set) var projects: [Project] = []
    @Published private(set) var resourceHistory: [ResourceHistoryPoint] = []
    @Published private(set) var projectResourceHistory: [ProjectResourceHistoryPoint] = []
    @Published private(set) var externalProcesses: [ExternalProcessSnapshot] = []
    @Published private(set) var temporaryRuntimeIDs: [String] = []
    @Published private(set) var memoryLimitRestarts: [String: MemoryLimitRestartEvent] = [:]
    /// Bumped on any runtime state change so SwiftUI redraws the lists.
    @Published private(set) var revision: Int = 0
    /// A Marina window is on screen and not fully covered. Screens that poll on
    /// their own — Ports runs `lsof` — watch this to stand down when hidden.
    @Published private(set) var uiIsVisible: Bool = false

    private let store: ConfigStore
    private(set) var runtimes: [String: ServerRuntime] = [:]
    private let metricsQueue = DispatchQueue(label: "dev.marina.app.process-metrics", qos: .utility)
    private var metricsTimer: Timer?
    private var metricsSampleInFlight = false
    private var metricsSampleSequence = 0
    private var memoryLimitGuard = MemoryLimitGuard()
    private let activity = AppActivityMonitor()
    private var currentCadence: MetricsCadence?
    private var dashboardObservers = 0
    private var lastControlAPIActivity: Date?
    private var lastMetricsSampleAt: Date?
    /// How long a control API call keeps the sampler warm, so an agent polling
    /// `marina status` in a loop reads fresh numbers without waking `ps` on the
    /// request path every time.
    private static let controlAPIInterestWindow: TimeInterval = 60

    var settings: MarinaConfig { store.config }

    private init() {
        store = ConfigStore()
        projects = store.config.projects
        syncRuntimes()
        store.onExternalChange = { [weak self] config in
            guard let self else { return }
            self.projects = config.projects
            self.syncRuntimes()
            self.bump()
        }
        store.startWatching()
        activity.onChange = { [weak self] in
            guard let self else { return }
            if self.uiIsVisible != self.activity.windowVisible {
                self.uiIsVisible = self.activity.windowVisible
            }
            self.updateMetricsSchedule()
        }
        uiIsVisible = activity.windowVisible
        updateMetricsSchedule()
    }

    // MARK: - Runtime bookkeeping

    private func syncRuntimes() {
        var seen = Set<String>()
        for project in store.config.projects {
            for server in project.servers {
                seen.insert(server.id)
                if let existing = runtimes[server.id] {
                    existing.apply(config: server, project: project, settings: store.config)
                } else {
                    let runtime = ServerRuntime(config: server, project: project, settings: store.config)
                    wire(runtime)
                    runtimes[server.id] = runtime
                }
            }
        }
        // A server removed from the config must not keep running.
        let temporaryIDs = Set(temporaryRuntimeIDs)
        for (id, runtime) in runtimes where !seen.contains(id) && !temporaryIDs.contains(id) {
            runtime.stop()
            runtimes.removeValue(forKey: id)
        }
    }

    private func wire(_ runtime: ServerRuntime, temporary: Bool = false) {
        runtime.onStateChange = { [weak self, weak runtime] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.bump()
                if temporary, runtime?.isRunning == false {
                    self.scheduleTemporaryCleanup(runtimeID: runtime?.id)
                }
            }
        }
        runtime.onFailed = { runtime in
            Notifications.serverFailed(name: runtime.config.name, project: runtime.projectName, reason: runtime.lastError)
        }
    }

    private func bump() {
        revision &+= 1
        // A server starting or stopping changes what the sampler has to feed.
        updateMetricsSchedule()
    }

    private func scheduleTemporaryCleanup(runtimeID: String?) {
        guard let runtimeID, let completedAt = runtimes[runtimeID]?.temporaryFinishedAt else { return }
        // Keep completed jobs long enough for a detached agent to call
        // `marina wait <id>` and inspect logs/result after a fast command exits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3_600) { [weak self] in
            guard let self,
                  self.temporaryRuntimeIDs.contains(runtimeID),
                  let runtime = self.runtimes[runtimeID],
                  runtime.isRunning == false,
                  runtime.temporaryFinishedAt == completedAt else { return }
            self.runtimes.removeValue(forKey: runtimeID)
            self.temporaryRuntimeIDs.removeAll { $0 == runtimeID }
            self.bump()
        }
    }

    // MARK: - Metrics scheduling

    /// The Resources screen registers while it is selected, so the sampler knows
    /// it has a live reader and can pay for the full sample.
    func beginDashboardObservation() {
        dashboardObservers += 1
        updateMetricsSchedule()
    }

    func endDashboardObservation() {
        dashboardObservers = max(0, dashboardObservers - 1)
        updateMetricsSchedule()
    }

    /// The control API is a reader too: `marina status --details` prints these
    /// numbers. A call keeps the sampler warm and tops up a stale sample.
    func noteControlAPIActivity() {
        lastControlAPIActivity = Date()
        updateMetricsSchedule()
        refreshProcessMetricsIfStale(maxAge: EnergyPolicy.observedInterval)
    }

    private var energyConditions: EnergyConditions {
        let controlAPIActive = lastControlAPIActivity.map {
            Date().timeIntervalSince($0) < Self.controlAPIInterestWindow
        } ?? false
        let enforcesMemoryLimits = projects.contains { project in
            project.effectiveMemoryLimit(global: store.config.globalMemoryLimitBytes) != nil
                && runtimes(inProject: project.id).contains { $0.isRunning }
        }
        return EnergyConditions(
            dashboardSelected: dashboardObservers > 0,
            windowVisible: uiIsVisible,
            hasRunningServers: runtimes.values.contains { $0.isRunning },
            controlAPIActive: controlAPIActive,
            enforcesMemoryLimits: enforcesMemoryLimits,
            asleep: activity.asleep,
            lowPower: activity.lowPower
        )
    }

    /// Rebuilds the sampling timer whenever the conditions call for a different
    /// cadence. Sampling stops outright when nothing can read the result.
    private func updateMetricsSchedule() {
        let cadence = EnergyPolicy.cadence(for: energyConditions)
        guard cadence != currentCadence else { return }
        let previous = currentCadence
        currentCadence = cadence

        metricsTimer?.invalidate()
        metricsTimer = nil

        guard let cadence else { return }

        let timer = Timer(timeInterval: cadence.interval, repeats: true) { [weak self] _ in
            self?.refreshProcessMetrics()
        }
        // Tolerance lets macOS fire this alongside wakeups it already has to
        // make, instead of interrupting an idle core on an exact deadline.
        timer.tolerance = cadence.tolerance
        metricsTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        // Moving up a tier — a window opened, the dashboard appeared — has to
        // show fresh numbers now, not after one full interval.
        let widened = previous.map {
            cadence.interval < $0.interval
                || (cadence.includesExternalProcesses && !$0.includesExternalProcesses)
        } ?? true
        if widened { refreshProcessMetrics() }
    }

    private func refreshProcessMetrics() {
        guard !metricsSampleInFlight, let cadence = currentCadence else { return }

        let targets = runningTargets()
        // Nothing running and no external list to build: `ps` would be spawned
        // to produce an empty sample.
        guard !targets.isEmpty || cadence.includesExternalProcesses else { return }

        metricsSampleInFlight = true
        metricsSampleSequence &+= 1
        // The cwd/listener enrichment is two `lsof` calls over every file
        // descriptor on the machine, so it stays on the dashboard's cadence and
        // its results are retained between samples.
        let includeExternalProcesses = cadence.includesExternalProcesses
        let includeExternalDetails = cadence.allowsExternalDetails
            && (externalProcesses.isEmpty || metricsSampleSequence.isMultiple(of: 5))
        let rootProcessIDs = Set(targets.values)
        metricsQueue.async { [weak self] in
            let sample = ProcessMetricsSampler.sample(
                rootProcessIDs: rootProcessIDs,
                includeExternalProcesses: includeExternalProcesses,
                includeExternalDetails: includeExternalDetails
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.metricsSampleInFlight = false
                self.apply(
                    sample: sample,
                    targets: targets,
                    includeExternalProcesses: includeExternalProcesses,
                    includeExternalDetails: includeExternalDetails
                )
            }
        }
    }

    /// Tops the sample up in place when a reader needs numbers the idle cadence
    /// has not refreshed. This runs `ps` on the calling thread and skips the
    /// `lsof` enrichment; it is only reached while no window is drawing.
    private func refreshProcessMetricsIfStale(maxAge: TimeInterval) {
        guard !metricsSampleInFlight else { return }
        if let lastMetricsSampleAt, Date().timeIntervalSince(lastMetricsSampleAt) < maxAge { return }

        let targets = runningTargets()
        guard !targets.isEmpty else { return }
        let sample = ProcessMetricsSampler.sample(
            rootProcessIDs: Set(targets.values),
            includeExternalProcesses: false,
            includeExternalDetails: false
        )
        apply(sample: sample, targets: targets, includeExternalProcesses: false, includeExternalDetails: false)
    }

    /// The PIDs this sample is attributed to. Anything no longer running loses
    /// its metrics here rather than keeping the last value on screen.
    private func runningTargets() -> [String: Int32] {
        for runtime in runtimes.values where !runtime.isRunning {
            runtime.updateProcessMetrics(nil)
        }
        return runtimes.compactMapValues { $0.isRunning ? $0.pid : nil }
    }

    private func apply(
        sample: ProcessMetricsSample,
        targets: [String: Int32],
        includeExternalProcesses: Bool,
        includeExternalDetails: Bool
    ) {
        lastMetricsSampleAt = Date()
        for (serverID, sampledPID) in targets {
            guard let runtime = runtimes[serverID], runtime.pid == sampledPID else { continue }
            runtime.updateProcessMetrics(sample.managedByRoot[sampledPID])
        }
        // An unobserved sample carries no external list. The previous one is
        // kept so opening the dashboard has something to draw while the full
        // sample that opening triggers completes.
        if includeExternalProcesses {
            if includeExternalDetails {
                externalProcesses = sample.externalProcesses
            } else {
                let previousByPID = Dictionary(uniqueKeysWithValues: externalProcesses.map { ($0.pid, $0) })
                externalProcesses = sample.externalProcesses.map {
                    $0.preservingDetails(from: previousByPID[$0.pid])
                }
            }
        }
        recordResourceHistory(samples: sample.managedByRoot, targets: targets)
        evaluateMemoryLimits(samples: sample.managedByRoot, targets: targets)
        bump()
    }

    private func recordResourceHistory(
        samples: [Int32: ProcessMetrics],
        targets: [String: Int32]
    ) {
        let now = Date()
        let point = ResourceHistoryPoint(
            timestamp: now,
            footprintBytes: samples.values.reduce(0) { $0 + $1.memoryBytes },
            residentBytes: samples.values.reduce(0) { $0 + $1.residentMemoryBytes },
            cpuPercent: samples.values.reduce(0) { $0 + $1.cpuPercent },
            processCount: samples.values.reduce(0) { $0 + $1.processCount }
        )
        resourceHistory.append(point)
        // Five minutes at the two-second sampling interval is enough to reveal
        // runaway growth without turning the monitor into another memory sink.
        if resourceHistory.count > 150 {
            resourceHistory.removeFirst(resourceHistory.count - 150)
        }

        struct ProjectTotals {
            let name: String
            let colorHex: String
            var footprintBytes: UInt64 = 0
            var residentBytes: UInt64 = 0
        }

        var projectTotals: [String: ProjectTotals] = [:]
        for (serverID, rootPID) in targets {
            guard let runtime = runtimes[serverID], let metrics = samples[rootPID] else { continue }
            let colorHex = projects.first(where: { $0.id == runtime.projectID })?.color
                ?? runtime.projectColorHex
            var total = projectTotals[runtime.projectID]
                ?? ProjectTotals(name: runtime.projectName, colorHex: colorHex)
            total.footprintBytes += metrics.memoryBytes
            total.residentBytes += metrics.residentMemoryBytes
            projectTotals[runtime.projectID] = total
        }

        projectResourceHistory.append(contentsOf: projectTotals.map { projectID, total in
            ProjectResourceHistoryPoint(
                timestamp: now,
                projectID: projectID,
                projectName: total.name,
                colorHex: total.colorHex,
                footprintBytes: total.footprintBytes,
                residentBytes: total.residentBytes
            )
        })
        let cutoff = now.addingTimeInterval(-300)
        projectResourceHistory.removeAll { $0.timestamp < cutoff }
    }

    private func evaluateMemoryLimits(
        samples: [Int32: ProcessMetrics],
        targets: [String: Int32],
        now: Date = Date()
    ) {
        let projectIDs = Set(projects.map(\.id))
        memoryLimitGuard.removeProjects(except: projectIDs)
        memoryLimitRestarts = memoryLimitRestarts.filter { projectIDs.contains($0.key) }

        for project in projects {
            let running = runtimes(inProject: project.id).filter(\.isRunning)
            let footprint = running.reduce(UInt64(0)) { total, runtime in
                guard let rootPID = targets[runtime.id], let metrics = samples[rootPID] else { return total }
                return total + metrics.memoryBytes
            }
            let limit = project.effectiveMemoryLimit(global: store.config.globalMemoryLimitBytes)
            guard memoryLimitGuard.shouldRestart(
                projectID: project.id,
                footprintBytes: footprint,
                limitBytes: limit,
                hasRunningServers: !running.isEmpty
            ), let limit else { continue }

            let serverIDs = running.map(\.id)
            memoryLimitRestarts[project.id] = MemoryLimitRestartEvent(
                projectID: project.id,
                timestamp: now,
                footprintBytes: footprint,
                limitBytes: limit,
                restartedServerIDs: serverIDs
            )
            for runtime in running {
                runtime.restartForMemoryLimit(projectFootprintBytes: footprint, limitBytes: limit)
            }
        }
    }

    func runtime(for id: String) -> ServerRuntime? { runtimes[id] }

    var temporaryRuntimes: [ServerRuntime] {
        temporaryRuntimeIDs.compactMap { runtimes[$0] }
    }

    var visibleTemporaryRuntimes: [ServerRuntime] {
        temporaryRuntimes.filter(\.isRunning)
    }

    func runtimes(inProject id: String) -> [ServerRuntime] {
        guard let project = store.config.project(id: id) else { return [] }
        return project.servers.compactMap { runtimes[$0.id] }
    }

    // MARK: - Status

    var status: MarinaStatus {
        MarinaStatus(
            version: marinaVersion,
            apiPort: store.config.apiPort,
            globalMemoryLimitBytes: store.config.globalMemoryLimitBytes,
            projects: store.config.projects.map { project in
                let memoryRestart = memoryLimitRestarts[project.id]
                return ProjectStatus(
                    id: project.id,
                    name: project.name,
                    icon: project.icon,
                    color: project.color,
                    root: project.root,
                    servers: project.servers.compactMap { runtimes[$0.id]?.status },
                    memoryLimitMode: project.memoryLimitMode,
                    memoryLimitBytes: project.memoryLimitBytes,
                    effectiveMemoryLimitBytes: project.effectiveMemoryLimit(global: store.config.globalMemoryLimitBytes),
                    lastMemoryRestartAt: memoryRestart?.timestamp,
                    lastMemoryRestartBytes: memoryRestart?.footprintBytes
                )
            },
            temporaryServers: temporaryRuntimes.map(\.status)
        )
    }

    var runningCount: Int {
        runtimes.values.filter { $0.isRunning }.count
    }

    var hasProblem: Bool {
        runtimes.values.contains { $0.state == .failed || $0.state == .unhealthy }
    }

    // MARK: - Actions

    func start(serverID: String) { runtime(for: serverID)?.start() }
    func stop(serverID: String) { runtime(for: serverID)?.stop() }
    func restart(serverID: String) { runtime(for: serverID)?.restart() }

    func startProject(_ id: String) {
        runtimes(inProject: id).forEach { $0.start() }
    }

    func stopProject(_ id: String) {
        runtimes(inProject: id).forEach { $0.stop() }
    }

    func stopAll() {
        runtimes.values.forEach { $0.stop() }
    }

    /// Blocks briefly on quit so children get a chance to die with us.
    func terminateEverythingSynchronously() {
        let running = runtimes.values.filter { $0.isRunning }
        guard !running.isEmpty else { return }
        running.forEach { $0.stop() }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, runtimes.values.contains(where: { $0.isRunning }) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        // Anything still alive gets a hard kill so no port stays held.
        for runtime in runtimes.values {
            if let pid = runtime.status.pid, pid > 0 {
                kill(-pid, SIGKILL)
            }
        }
    }

    // MARK: - Config mutations

    func addProject(
        name: String,
        root: String,
        icon: String?,
        color: String?,
        memoryLimitMode: MemoryLimitMode = .inherit,
        memoryLimitBytes: UInt64? = nil
    ) -> Project {
        let project = Project(
            name: name,
            icon: icon ?? Project.defaultIcon,
            color: color ?? Supervisor.nextColor(excluding: store.config.projects.map(\.color)),
            root: NSString(string: root).expandingTildeInPath,
            memoryLimitMode: memoryLimitMode,
            memoryLimitBytes: memoryLimitBytes
        )
        store.mutate { $0.projects.append(project) }
        refresh()
        return project
    }

    func updateProject(_ project: Project) {
        if let previous = store.config.project(id: project.id),
           previous.memoryLimitMode != project.memoryLimitMode
            || previous.memoryLimitBytes != project.memoryLimitBytes {
            memoryLimitGuard.reset(projectID: project.id)
        }
        store.mutate { config in
            guard let idx = config.projects.firstIndex(where: { $0.id == project.id }) else { return }
            config.projects[idx] = project
        }
        refresh()
    }

    func updateGlobalMemoryLimit(_ bytes: UInt64?) {
        memoryLimitGuard.resetAll()
        store.mutate { $0.globalMemoryLimitBytes = bytes }
        refresh()
    }

    func updateProjectMemoryLimit(projectID: String, mode: MemoryLimitMode, bytes: UInt64?) {
        memoryLimitGuard.reset(projectID: projectID)
        store.mutate { config in
            guard let index = config.projects.firstIndex(where: { $0.id == projectID }) else { return }
            config.projects[index].memoryLimitMode = mode
            config.projects[index].memoryLimitBytes = mode == .custom ? bytes : nil
        }
        refresh()
    }

    func removeProject(id: String) {
        runtimes(inProject: id).forEach { $0.stop() }
        let removedServerIDs = store.config.project(id: id)?.servers.map(\.id) ?? []
        store.mutate { config in
            config.projects.removeAll { $0.id == id }
        }
        refresh()
        // refresh() released the runtimes, so no LogStore is writing these anymore.
        removedServerIDs.forEach(MarinaPaths.removeLogs(forServer:))
    }

    @discardableResult
    func addServer(projectID: String, server: ServerConfig) -> ServerConfig? {
        var added: ServerConfig?
        store.mutate { config in
            guard let idx = config.projects.firstIndex(where: { $0.id == projectID }) else { return }
            config.projects[idx].servers.append(server)
            added = server
        }
        refresh()
        return added
    }

    @discardableResult
    func runTemporary(
        name: String,
        command: String,
        directory: String,
        port: Int?,
        env: [String: String] = [:],
        healthURL: String? = nil,
        healthStatus: Int? = nil,
        timeoutSeconds: Int = TemporaryTimeout.defaultSeconds
    ) -> ServerRuntime {
        let resolvedDirectory = NSString(string: directory).expandingTildeInPath
        let resolvedName = uniqueTemporaryName(name)
        let server = ServerConfig(
            id: "tmp_" + String(UUID().uuidString.prefix(8)).lowercased(),
            name: resolvedName,
            command: command,
            port: port,
            env: env,
            healthURL: healthURL,
            healthStatus: healthStatus,
            autoRestart: false
        )
        let temporaryProject = Project(
            id: Supervisor.temporaryProjectID,
            name: "Temporary",
            icon: "clock.badge",
            color: Supervisor.temporaryProjectColor,
            root: resolvedDirectory,
            servers: [server]
        )
        let runtime = ServerRuntime(config: server, project: temporaryProject, settings: store.config)
        runtime.configureTemporaryJob(timeoutSeconds: timeoutSeconds)
        wire(runtime, temporary: true)
        runtimes[server.id] = runtime
        temporaryRuntimeIDs.append(server.id)
        bump()
        runtime.start()
        return runtime
    }

    @discardableResult
    func runAction(
        _ action: ServerAction,
        for runtime: ServerRuntime,
        timeoutSeconds: Int = TemporaryTimeout.defaultSeconds
    ) -> ServerRuntime {
        var env = runtime.config.env
        env["MARINA_SERVER"] = runtime.config.name
        if let port = runtime.config.port {
            env["PORT"] = String(port)
        }
        return runTemporary(
            name: "\(runtime.config.name): \(action.name)",
            command: action.command,
            directory: runtime.workingDirectory,
            port: nil,
            env: env,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func uniqueTemporaryName(_ requestedName: String) -> String {
        let base = requestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Temporary process"
            : requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = Set(temporaryRuntimes.map { $0.config.name.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    func updateServer(_ server: ServerConfig) {
        store.mutate { config in
            for (pIdx, project) in config.projects.enumerated() {
                if let sIdx = project.servers.firstIndex(where: { $0.id == server.id }) {
                    config.projects[pIdx].servers[sIdx] = server
                    return
                }
            }
        }
        refresh()
    }

    func removeServer(id: String) {
        if temporaryRuntimeIDs.contains(id) {
            guard let runtime = runtime(for: id) else { return }
            if runtime.isRunning {
                runtime.stop { [weak self] in
                    self?.removeTemporaryRuntime(id: id)
                }
            } else {
                removeTemporaryRuntime(id: id)
            }
            return
        }
        runtime(for: id)?.stop()
        store.mutate { config in
            for (pIdx, project) in config.projects.enumerated() {
                if project.servers.contains(where: { $0.id == id }) {
                    config.projects[pIdx].servers.removeAll { $0.id == id }
                    return
                }
            }
        }
        refresh()
        // A removed server keeps no log behind: it can hold secrets and payloads.
        MarinaPaths.removeLogs(forServer: id)
    }

    private func removeTemporaryRuntime(id: String) {
        runtimes.removeValue(forKey: id)
        temporaryRuntimeIDs.removeAll { $0 == id }
        MarinaPaths.removeLogs(forServer: id)
        bump()
    }

    func refresh() {
        projects = store.config.projects
        syncRuntimes()
        bump()
    }

    func updateRuntimeSettings(
        healthIntervalSeconds: Int,
        maxRestartAttempts: Int,
        logBufferLines: Int,
        logFileMaxMB: Int
    ) {
        store.mutate { config in
            config.healthIntervalSeconds = healthIntervalSeconds
            config.maxRestartAttempts = maxRestartAttempts
            config.logBufferLines = logBufferLines
            config.logFileMaxMB = logFileMaxMB
        }
        refresh()
    }

    // MARK: - Resolution helpers (shared by the API and the UI)

    func resolveServer(_ query: String) -> ServerRuntime? {
        if let hit = store.config.resolveServer(query) { return runtimes[hit.server.id] }
        if let runtime = temporaryRuntimes.first(where: { $0.id == query }) { return runtime }
        let normalized = query.split(separator: "/", maxSplits: 1).last.map(String.init) ?? query
        return temporaryRuntimes.first {
            $0.config.name.caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    func resolveProject(_ query: String) -> Project? {
        store.config.resolveProject(query)
    }

    func project(containing serverID: String) -> Project? {
        store.config.projects.first { $0.servers.contains { $0.id == serverID } }
    }

    func server(configuredOn port: Int, excluding serverID: String? = nil) -> (project: Project, server: ServerConfig)? {
        for project in store.config.projects {
            if let server = project.servers.first(where: { $0.port == port && $0.id != serverID }) {
                return (project, server)
            }
        }
        if let runtime = temporaryRuntimes.first(where: {
            $0.id != serverID && $0.config.port == port
        }) {
            return (
                Project(
                    id: Supervisor.temporaryProjectID,
                    name: "Temporary",
                    icon: "clock.badge",
                    color: Supervisor.temporaryProjectColor,
                    root: runtime.workingDirectory,
                    servers: [runtime.config]
                ),
                runtime.config
            )
        }
        return nil
    }

    func nextAvailablePort(startingAt start: Int = 3000, excluding serverID: String? = nil) -> Int {
        for port in max(1, start)...65_535 {
            if server(configuredOn: port, excluding: serverID) == nil, PortInspector.occupant(of: port) == nil {
                return port
            }
        }
        return start
    }

    // MARK: - Ports

    func occupant(of port: Int) -> PortOccupant? {
        guard let found = PortInspector.occupant(of: port) else { return nil }
        let owned = runtimes.values.first { $0.status.pid == found.pid || ($0.config.port == port && $0.isRunning) }
        let container = DockerPortInspector.container(publishing: port)
        return PortOccupant(
            port: port,
            pid: found.pid,
            command: found.command,
            user: found.user,
            ownedByMarina: owned != nil,
            serverID: owned?.id,
            dockerContainerID: container?.id,
            dockerContainerName: container?.name,
            dockerComposeProject: container?.composeProject,
            dockerComposeService: container?.composeService
        )
    }

    /// The palette is intentionally the macOS system colors, so projects read as
    /// native rather than branded. The order matters: colors are handed out in this
    /// sequence, and every adjacent pair sits at least 86 degrees apart in OKLCH hue,
    /// so the first projects you create never look alike in the charts.
    static let palette = [
        "#0A84FF", // Blue
        "#FF9F0A", // Orange
        "#BF5AF2", // Purple
        "#30D158", // Green
        "#FF375F", // Pink
        "#64D2FF", // Cyan
        "#FFD60A", // Yellow
        "#5E5CE6", // Indigo
        "#66D4CF", // Mint
        "#8E8E93", // Gray
    ]
    static let paletteNames = [
        "Blue", "Orange", "Purple", "Green", "Pink", "Cyan", "Yellow", "Indigo", "Mint", "Gray",
    ]
    static let temporaryProjectID = "marina-temporary"
    static let temporaryProjectColor = "#8E8E93"

    /// Hands out the first palette color no project uses yet, so two projects never
    /// end up with the same line in the resource charts. Once every color is taken,
    /// the least used one wins.
    static func nextColor(excluding used: [String]) -> String {
        var counts: [String: Int] = [:]
        for hex in used {
            counts[hex.uppercased(), default: 0] += 1
        }
        var best = palette[0]
        var bestCount = Int.max
        for hex in palette {
            let count = counts[hex.uppercased()] ?? 0
            guard count < bestCount else { continue }
            best = hex
            bestCount = count
            if count == 0 { break }
        }
        return best
    }
}
