import AppKit
import MeetMuteCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let pollInterval: TimeInterval = 3
    /// A poll this soon after a handled press skips the system-mute sync: the press already
    /// made the system record the requested state, and a sync from a stale read could undo it.
    private let syncQuietPeriodAfterPress: TimeInterval = 1.5

    private let controller = MuteController(browsers: Browser.allCases.map { ChromiumBridge(browser: $0) })
    private let recorders: RecordingProcessSource = CoreAudioRecordingProcessSource()
    private let systemMute = SystemMicMuter(devices: CoreAudioInputDeviceProvider(), store: UserDefaultsMuteRecordStore())
    private let listener = GestureListener()
    private let terminationSignal = TerminationSignalHandler()
    private var routeTracker = RouteTracker()
    private let pressSound = PressFeedbackSound()
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?

    private var route: MuteRoute = .idle
    private var systemMuted: Bool?
    private var lastHandledPress: Date?

    private var listenerError: String?
    private var inputError: String?
    private var syncError: String?
    /// Read failure: cleared by the next successful read. Press failure: cleared by the next
    /// successful press or by leaving the system route.
    private var systemReadError: String?
    private var systemPressError: String?
    /// Failed unmute at launch/after a call/on quit. Kept until the user opens the menu (the
    /// notice is then rendered at least once), so a later poll cannot erase it unseen.
    private var restoreError: String?
    private var recorderError: String?
    private var loginItemError: String?
    private var soundError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminationSignal.install()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        restoreSystemMute(when: "after the last run")  // a crash or force-quit may have left the mic muted
        listener.onMuteRequest = { [weak self] shouldMute in
            guard let self else { return false }
            let handled = self.handlePress(shouldMute: shouldMute)
            self.render()
            return handled
        }
        do {
            try listener.start()
        } catch {
            listenerError = "Could not register for the AirPods mute gesture: \(error.localizedDescription)"
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreSystemMute(when: "on quit")
    }

    // MARK: Press

    /// Never calls setInputMuted (it re-enters this handler); returning true records the state.
    private func handlePress(shouldMute: Bool) -> Bool {
        let newState: MicState?
        switch route {
        case .meet:
            newState = controller.handleMuteRequest(shouldMute: shouldMute)
        case .system:
            do {
                let targets = try systemMute.targetDeviceUIDs(for: routeTracker.systemRecorders)
                if shouldMute { try systemMute.mute(deviceUIDs: targets) } else { try systemMute.unmute(deviceUIDs: targets) }
                systemPressError = nil
                systemMuted = shouldMute
                newState = shouldMute ? .muted : .unmuted
            } catch {
                systemPressError = "Could not \(shouldMute ? "mute" : "unmute") the system mic: \(error)"
                newState = nil
            }
        case .standAside, .idle:
            newState = nil
        }
        guard let newState else { return false }
        lastHandledPress = Date()
        soundError = pressSound.play(for: newState)
        return true
    }

    // MARK: Poll

    private func poll() {
        let meetStatus = controller.refresh()
        route = routeTracker.nextRoute(meetStatus: meetStatus, recorders: currentRecorders())
        if !route.isSystem {
            systemReadError = nil
            systemPressError = nil
            restoreSystemMute(when: "after the call")  // no-op unless we muted the device
        }
        switch route {
        case .meet:
            systemMuted = nil
            if case .inCall(let mic) = meetStatus, !inQuietPeriodAfterPress {
                syncError = listener.syncSystemMute(mic == .muted)
            }
        case .system:
            do {
                let muted = try systemMute.isMuted(deviceUIDs: systemMute.targetDeviceUIDs(for: routeTracker.systemRecorders))
                systemMuted = muted
                systemReadError = nil
                if !inQuietPeriodAfterPress { syncError = listener.syncSystemMute(muted) }
            } catch {
                systemMuted = nil
                systemReadError = "Could not read the system mic state: \(error)"
            }
        case .standAside, .idle:
            systemMuted = nil
            syncError = nil
        }
        if route.holdsMic {
            inputError = listener.setHoldingInput(true)
        } else {
            listener.setHoldingInput(false)
            inputError = nil
        }
        render()
    }

    private var inQuietPeriodAfterPress: Bool {
        guard let lastHandledPress else { return false }
        return Date().timeIntervalSince(lastHandledPress) < syncQuietPeriodAfterPress
    }

    private func currentRecorders() -> Result<[RecordingProcess], Error> {
        let result = Result { try recorders.recordingProcesses() }
        if case .failure(let error) = result {
            recorderError = "Could not list apps using the mic: \(error)"
        } else {
            recorderError = nil
        }
        return result
    }

    private func restoreSystemMute(when moment: String) {
        do {
            try systemMute.restoreIfWeMuted()
        } catch {
            // Keep the first failure (e.g. "after the last run") until seen; retries repeat it.
            restoreError = restoreError ?? "Could not unmute the system mic \(moment): \(error)"
        }
    }

    // MARK: Menu

    private func render() {
        let meetStatus = controller.status
        var problems = [listenerError, inputError, syncError, systemReadError, systemPressError,
                        restoreError, recorderError,
                        loginItemError, soundError, controller.lastPressError].compactMap { $0 }
        if case .error(let message) = meetStatus, route != .meet, route != .idle {
            problems.insert(message, at: 0)  // the status line is about another app; keep the Meet error visible
        }
        statusItem.button?.title = menuTitle(route: route, meetStatus: meetStatus, systemMuted: systemMuted,
                                             hasProblem: !problems.isEmpty)
        let menu = StatusMenu.build(
            statusLine: menuStatusLine(route: route, meetStatus: meetStatus, systemMuted: systemMuted),
            problems: problems,
            launchAtLoginEnabled: SMAppService.mainApp.status == .enabled,
            actionTarget: self,
            toggleLaunchAtLogin: #selector(toggleLaunchAtLogin)
        )
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        restoreError = nil  // this menu was built with it; the next render drops it
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Launch at Login failed: \(error.localizedDescription)"
        }
        render()
    }
}
