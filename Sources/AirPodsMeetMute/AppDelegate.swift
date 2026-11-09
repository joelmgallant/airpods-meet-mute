import AppKit
import MeetMuteCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// From docs/spike-findings.md (HOLD_INPUT_DURING_CALLS = true: gesture is only delivered while we hold input).
    private let holdInputDuringCalls = true
    private let pollInterval: TimeInterval = 3

    private let controller = MuteController(browsers: Browser.allCases.map { ChromiumBridge(browser: $0) })
    private let listener = GestureListener()
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var listenerError: String?
    private var inputError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        listener.onMuteRequest = { [weak self] shouldMute in
            guard let self else { return false }
            let newState = self.controller.handleMuteRequest(shouldMute: shouldMute)
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
        if case .inCall(let mic) = status {
            listener.syncSystemMute(mic == .muted)
            inputError = holdInputDuringCalls ? listener.setHoldingInput(true) : nil
        } else {
            listener.setHoldingInput(false)
            inputError = nil
        }
        render()
    }

    private func render() {
        statusItem.button?.title = title(for: controller.status)
        let menu = NSMenu()
        menu.addItem(disabledItem(statusLine(for: controller.status)))
        for problem in [listenerError, inputError, controller.lastPressError].compactMap({ $0 }) {
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
        let hasProblem = listenerError != nil || inputError != nil || controller.lastPressError != nil
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
        } catch {
            listenerError = "Launch at Login failed: \(error.localizedDescription)"
        }
        render()
    }
}
