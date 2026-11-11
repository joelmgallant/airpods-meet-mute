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
    private lazy var restore = SystemMuteRestore(muter: systemMute, pressSound: pressSound)
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
    private var recorderError: String?
    private var loginItemError: String?
    private var soundError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminationSignal.install()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A crash or force-quit may have left the mic muted; a call may still be running.
        restore.restore(when: "after the last run", recorderNames: callRecorderNames(currentRecorders()))
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
        restore.restore(when: "on quit")
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
        let listing = currentRecorders()
        route = routeTracker.nextRoute(meetStatus: meetStatus, recorders: listing)
        if !route.isSystem {
            systemReadError = nil
            systemPressError = nil
            // No-op unless we muted a device; audible if an app may still be on a call.
            soundError = restore.restore(when: "after the call", route: route, recorderNames: callRecorderNames(listing)) ?? soundError
        }
        switch route {
        case .meet:
            systemMuted = nil
            if case .inCall(let mic) = meetStatus, !inQuietPeriodAfterPress {
                syncError = listener.syncSystemMute(mic == .muted)
            }
        case .system:
            do {
                switch try systemMute.muteState(deviceUIDs: systemMute.targetDeviceUIDs(for: routeTracker.systemRecorders)) {
                case .mixed:  // never mirror a guess into AVAudioApplication
                    systemMuted = nil
                    systemReadError = "Some call mics are muted and some are live — press to unmute all"
                case let state:
                    systemMuted = state == .muted
                    systemReadError = nil
                    if !inQuietPeriodAfterPress { syncError = listener.syncSystemMute(state == .muted) }
                }
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

    /// Names of the call apps recording; nil when the listing failed (unknown).
    private func callRecorderNames(_ listing: Result<[RecordingProcess], Error>) -> [String]? {
        (try? listing.get()).map { processes in callRecorders(processes).map(\.displayName) }
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

    // MARK: Menu

    private func render() {
        let meetStatus = controller.status
        var problems = restore.problems + [listenerError, inputError, syncError, systemReadError, systemPressError,
                                           recorderError, loginItemError, soundError, controller.lastPressError].compactMap { $0 }
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
        restore.markSeen()  // this menu was built with its notices; the next render drops them
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
