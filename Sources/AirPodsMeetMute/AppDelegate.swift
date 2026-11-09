import AppKit
import MeetMuteCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// From docs/spike-findings.md (HOLD_INPUT_DURING_CALLS = true: gesture is only delivered while we hold input).
    private let holdInputDuringCalls = true
    private let pollInterval: TimeInterval = 3
    /// A poll this soon after a handled press skips the system-mute sync: the press already
    /// made the system record the requested state, and a sync from a stale read could undo it.
    private let syncQuietPeriodAfterPress: TimeInterval = 1.5
    /// Consecutive error polls tolerated mid-call before the held mic input is released.
    private let errorPollsBeforeReleasingInput = 2

    private let controller = MuteController(browsers: Browser.allCases.map { ChromiumBridge(browser: $0) })
    private let listener = GestureListener()
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var listenerError: String?
    private var inputError: String?
    private var syncError: String?
    private var lastHandledPress: Date?
    private var wasInCall = false
    private var consecutiveErrorPolls = 0
    private var loginItemError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        listener.onMuteRequest = { [weak self] shouldMute in
            guard let self else { return false }
            // No syncSystemMute here: returning true makes the system record the requested
            // state, and calling setInputMuted from inside the handler re-enters the handler.
            let newState = self.controller.handleMuteRequest(shouldMute: shouldMute)
            if newState != nil { self.lastHandledPress = Date() }
            self.render()
            return newState != nil
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

    private func poll() {
        let status = controller.refresh()
        switch status {
        case .inCall(let mic):
            consecutiveErrorPolls = 0
            wasInCall = true
            if let lastHandledPress, Date().timeIntervalSince(lastHandledPress) < syncQuietPeriodAfterPress {
                // Leave syncError as it was: nothing was attempted.
            } else {
                syncError = listener.syncSystemMute(mic == .muted)
            }
            inputError = holdInputDuringCalls ? listener.setHoldingInput(true) : nil
        case .error where wasInCall && consecutiveErrorPolls < errorPollsBeforeReleasingInput:
            // One transient error mid-call must not drop the held mic (and the gesture with it).
            consecutiveErrorPolls += 1
        case .error, .idle:
            consecutiveErrorPolls = 0
            wasInCall = false
            syncError = nil
            listener.setHoldingInput(false)
            inputError = nil
        }
        render()
    }

    private func render() {
        statusItem.button?.title = title(for: controller.status)
        let menu = NSMenu()
        menu.addItem(disabledItem(statusLine(for: controller.status)))
        for problem in [listenerError, inputError, syncError, loginItemError, controller.lastPressError].compactMap({ $0 }) {
            menu.addItem(disabledItem("⚠️ " + problem))
        }
        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit AirPods Meet Mute", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func title(for status: MeetStatus) -> String {
        let hasProblem = listenerError != nil || inputError != nil || syncError != nil || loginItemError != nil || controller.lastPressError != nil
        switch status {
        case .error: return "🎧⚠️"
        case _ where hasProblem: return "🎧⚠️"
        case .idle: return "🎧"
        case .inCall(.muted): return "🎧🔇"
        case .inCall(.unmuted): return "🎧🎙️"
        }
    }

    private func statusLine(for status: MeetStatus) -> String {
        switch status {
        case .idle: "No Meet call"
        case .inCall(.muted): "In Meet call — muted"
        case .inCall(.unmuted): "In Meet call — unmuted"
        case .error(let message): message
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
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
