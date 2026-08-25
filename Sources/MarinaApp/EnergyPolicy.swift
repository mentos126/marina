import AppKit
import Foundation

/// What Marina knows about the machine and about its own visibility.
///
/// Sampling is only worth its energy when something consumes the result, so the
/// sampler asks these questions before deciding how hard to work.
struct EnergyConditions: Equatable {
    /// The Resources screen is the selected detail view.
    var dashboardSelected = false
    /// At least one Marina window is on screen and not fully covered.
    var windowVisible = false
    /// At least one supervised server is running.
    var hasRunningServers = false
    /// A CLI or agent polled the control API recently.
    var controlAPIActive = false
    /// A project with running servers enforces a footprint limit. Memory-limit
    /// restarts are the one thing that must keep working with nothing on screen.
    var enforcesMemoryLimits = false
    /// The displays or the machine are asleep.
    var asleep = false
    var lowPower = false

    /// The dashboard only consumes samples while its window is actually on screen.
    var dashboardVisible: Bool { dashboardSelected && windowVisible }
}

/// One decision of the metrics sampler: how often it runs, how much slack the
/// system may take when waking it, and how much of the sample it computes.
struct MetricsCadence: Equatable {
    let interval: TimeInterval
    /// Slack handed to `Timer.tolerance`. macOS coalesces tolerant timers with
    /// other pending wakeups instead of interrupting an idle core on a precise
    /// deadline, which is what Activity Monitor scores as energy impact.
    let tolerance: TimeInterval
    /// Build the "outside Marina" process list. This is pure parsing of the `ps`
    /// output Marina already has.
    let includesExternalProcesses: Bool
    /// Enrich external processes with working directory and listening ports.
    /// Two `lsof` invocations that walk every file descriptor on the machine —
    /// by far the most expensive part of a sample.
    let allowsExternalDetails: Bool
}

/// Chooses the sampling cadence from the current conditions.
///
/// Marina used to spawn `/bin/ps` across the whole process table every two
/// seconds for the lifetime of the app, plus two `lsof` calls every ten
/// seconds, whether or not a window was open and whether or not any server was
/// running. That is ~43k process spawns a day to feed a screen nobody is
/// looking at. The tiers below keep full fidelity for the dashboard and scale
/// the work down to what each other situation can actually observe.
enum EnergyPolicy {
    /// Live cadence while the Resources screen is on screen.
    static let observedInterval: TimeInterval = 2
    /// A window is open on another screen: metrics still appear in server rows.
    static let windowInterval: TimeInterval = 6
    /// Nothing is on screen and no memory limit is armed. Sampling continues
    /// only so the next reader does not start from nothing.
    static let unobservedInterval: TimeInterval = 15
    /// Nothing is on screen, but a project enforces a footprint limit. The guard
    /// restarts after three consecutive over-limit samples, so this stays tight
    /// enough to catch a runaway in seconds rather than in a minute.
    static let guardedInterval: TimeInterval = 5

    /// The cadence to run at, or `nil` when sampling should be suspended
    /// entirely because no consumer exists.
    static func cadence(for conditions: EnergyConditions) -> MetricsCadence? {
        // Nobody can read a sample taken behind a sleeping display, and the
        // memory-limit guard has nothing to protect while the machine is idle.
        if conditions.asleep { return nil }

        // No servers, no window, no CLI: every consumer of a sample is absent.
        if !conditions.hasRunningServers,
           !conditions.dashboardVisible,
           !conditions.windowVisible,
           !conditions.controlAPIActive {
            return nil
        }

        let base: MetricsCadence
        if conditions.dashboardVisible {
            base = MetricsCadence(
                interval: observedInterval,
                tolerance: observedInterval * 0.25,
                includesExternalProcesses: true,
                allowsExternalDetails: true
            )
        } else if conditions.windowVisible || conditions.controlAPIActive {
            base = MetricsCadence(
                interval: windowInterval,
                tolerance: windowInterval * 0.5,
                includesExternalProcesses: false,
                allowsExternalDetails: false
            )
        } else {
            let interval = conditions.enforcesMemoryLimits ? guardedInterval : unobservedInterval
            base = MetricsCadence(
                interval: interval,
                tolerance: interval * 0.5,
                includesExternalProcesses: false,
                allowsExternalDetails: false
            )
        }

        guard conditions.lowPower else { return base }
        // Low Power Mode is the user asking for less background work by name.
        return MetricsCadence(
            interval: base.interval * 2,
            tolerance: base.interval,
            includesExternalProcesses: base.includesExternalProcesses,
            allowsExternalDetails: false
        )
    }
}
