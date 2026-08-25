import AppKit
import Foundation

/// Tracks the machine and window state that decides how hard Marina samples.
///
/// Marina spends most of its life as a menu bar item with no window on screen.
/// Nothing in AppKit pushes that fact at the supervisor, so this listens for the
/// few notifications that change the answer and re-evaluates only then — there
/// is no polling here.
final class AppActivityMonitor {
    /// Called on the main thread whenever one of the tracked facts may have changed.
    var onChange: (() -> Void)?

    private(set) var windowVisible = false
    private(set) var asleep = false

    var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.asleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.asleep = false }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.asleep = false }

        for name: Notification.Name in [
            NSApplication.didChangeOcclusionStateNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
            .NSProcessInfoPowerStateDidChange,
        ] {
            observe(.default, name) { _ in }
        }

        refreshWindowVisibility()
    }

    deinit {
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { workspace.removeObserver(observer) }
        for observer in defaultObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ apply: @escaping (AppActivityMonitor) -> Void
    ) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            apply(self)
            self.settle()
        }
        if center === NSWorkspace.shared.notificationCenter {
            workspaceObservers.append(observer)
        } else {
            defaultObservers.append(observer)
        }
    }

    /// `willClose` fires while the window is still listed, so window state is
    /// re-read on the next turn of the run loop rather than inside the callback.
    private func settle() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshWindowVisibility()
            self.onChange?()
        }
    }

    private func refreshWindowVisibility() {
        // The menu bar extra's panel does not count: it is transient, and its
        // content is driven by server state changes rather than by samples.
        windowVisible = NSApp?.windows.contains { window in
            window.isVisible
                && !window.isMiniaturized
                && window.canBecomeMain
                && window.occlusionState.contains(.visible)
        } ?? false
    }
}
