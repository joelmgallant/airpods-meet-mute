import AppKit
import MeetMuteCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let pollInterval: TimeInterval = 3
    /// A poll this soon after a handled press skips the system-mute sync: the press already
    /// made the system record the requested state, and a sync from a stale read could undo it.
    private let syncQuietPeriodAfterPress: TimeInterval = 1.5
    /// Consecutive AppleScript error polls a Meet call survives before it counts as ended.
    private let errorPollsBeforeLeavingMeet = 2

    private let controller = MuteController(browsers: Browser.allCases.map { ChromiumBridge(browser: $0) })
    private let recorders: RecordingProcessSource = CoreAudioRecordingProcessSource()
    private let systemMute = SystemMicMuter(devices: CoreAudioInputDeviceProvider(), store: UserDefaultsMuteRecordStore())
    private let listener = GestureListener()
    private let pressSound = PressFeedbackSound()
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?

    private var route: MuteRoute = .idle
    private var systemMuted: Bool?
    private var lastHandledPress: Date?
    private var wasInMeetCall = false
    private var consecutiveMeetErrorPolls = 0

    private var listenerError: String?
    private var inputError: String?
    private var syncError: String?
    private var systemError: String?
    private var recorderError: String?
    private var loginItemError: String?
    private var soundError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                if shouldMute { try systemMute.mute() } else { try systemMute.unmute() }
                systemError = nil
                systemMuted = shouldMute
                newState = shouldMute ? .muted : .unmuted
            } catch {
                systemError = "Could not \(shouldMute ? "mute" : "unmute") the system mic: \(error)"
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
        route = decideRoute(meetCallPresent: meetCallPresent(meetStatus), recording: currentRecorders())
        if !route.isSystem {
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
                let muted = try systemMute.isDefaultInputMuted()
                systemMuted = muted
                if !inQuietPeriodAfterPress { syncError = listener.syncSystemMute(muted) }
            } catch {
                systemMuted = nil
                systemError = "Could not read the system mic state: \(error)"
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

    /// A Meet call survives a couple of transient AppleScript errors, so one glitch neither
    /// drops the held mic nor reroutes presses to the system path mid-call.
    private func meetCallPresent(_ status: MeetStatus) -> Bool {
        switch status {
        case .inCall:
            consecutiveMeetErrorPolls = 0
            wasInMeetCall = true
            return true
        case .error where wasInMeetCall && consecutiveMeetErrorPolls < errorPollsBeforeLeavingMeet:
            consecutiveMeetErrorPolls += 1
            return true
        case .error, .idle:
            consecutiveMeetErrorPolls = 0
            wasInMeetCall = false
            return false
        }
    }

    private func currentRecorders() -> [RecordingProcess] {
        do {
            let found = try recorders.recordingProcesses()
            recorderError = nil
            return found
        } catch {
            recorderError = "Could not list apps using the mic: \(error)"
            return []
        }
    }

    private func restoreSystemMute(when moment: String) {
        do {
            try systemMute.restoreIfWeMuted()
            if !route.isSystem { systemError = nil }
        } catch {
            systemError = "Could not unmute the system mic \(moment): \(error)"
        }
    }

    // MARK: Menu

    private func render() {
        let meetStatus = controller.status
        var problems = [listenerError, inputError, syncError, systemError, recorderError,
                        loginItemError, soundError, controller.lastPressError].compactMap { $0 }
        if case .error(let message) = meetStatus, route != .meet, route != .idle {
            problems.insert(message, at: 0)  // the status line is about another app; keep the Meet error visible
        }
        statusItem.button?.title = menuTitle(route: route, meetStatus: meetStatus, systemMuted: systemMuted,
                                             hasProblem: !problems.isEmpty)
        statusItem.menu = StatusMenu.build(
            statusLine: menuStatusLine(route: route, meetStatus: meetStatus, systemMuted: systemMuted),
            problems: problems,
            launchAtLoginEnabled: SMAppService.mainApp.status == .enabled,
            actionTarget: self,
            toggleLaunchAtLogin: #selector(toggleLaunchAtLogin)
        )
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
