import Foundation

public enum MeetStatus: Equatable, Sendable {
    case idle
    case inCall(MicState)
    case error(String)
}

public let layoutChangedMessage =
    "Meet tab is open but no mic button was found — if you're in a call, Meet's layout changed and the selector in MeetToggleJS needs an update"

/// Finds the Meet call tab and sets its mic. Main-thread only (AppleScript).
public final class MuteController {
    private let browsers: [MeetBrowser]
    private var callTab: MeetTab?
    private var sawMeetTabWithoutButton = false

    public private(set) var status: MeetStatus = .idle
    /// The most recent press failure; cleared by the next successful press.
    public private(set) var lastPressError: String?

    public init(browsers: [MeetBrowser]) {
        self.browsers = browsers
    }

    /// Locates the first call tab (browser priority, then window/tab order) and reads its mic state.
    @discardableResult
    public func refresh() -> MeetStatus {
        var firstError: String?
        sawMeetTabWithoutButton = false
        for bridge in browsers {
            do {
                for tab in try bridge.meetTabs() {
                    let output = try bridge.execute(javaScript: MeetToggleJS.invocation(.query), in: tab)
                    switch MeetToggleJS.parse(output) {
                    case .state(let mic):
                        callTab = tab
                        status = .inCall(mic)
                        return status
                    case .noButton:
                        sawMeetTabWithoutButton = true
                    case .unexpected(let other):
                        firstError = firstError ?? "\(bridge.browser.displayName): unexpected Meet script output: \(other)"
                    }
                }
            } catch {
                firstError = firstError ?? message(for: error, browser: bridge.browser)
            }
        }
        callTab = nil
        status = firstError.map(MeetStatus.error) ?? .idle
        return status
    }

    /// Handles an AirPods mute gesture. Returns the new mic state, or nil when not handled.
    public func handleMuteRequest(shouldMute: Bool) -> MicState? {
        refresh()
        guard let tab = callTab,
              let bridge = browsers.first(where: { $0.browser == tab.browser }) else {
            if sawMeetTabWithoutButton { lastPressError = layoutChangedMessage }
            return nil
        }
        do {
            let output = try bridge.execute(javaScript: MeetToggleJS.invocation(shouldMute ? .mute : .unmute), in: tab)
            switch MeetToggleJS.parse(output) {
            case .state(let mic):
                status = .inCall(mic)
                lastPressError = nil
                return mic
            case .noButton:
                lastPressError = layoutChangedMessage
            case .unexpected(let other):
                lastPressError = "\(tab.browser.displayName): unexpected Meet script output: \(other)"
            }
        } catch {
            lastPressError = message(for: error, browser: tab.browser)
        }
        return nil
    }

    private func message(for error: Error, browser: Browser) -> String {
        if let scriptError = error as? ScriptError {
            return describe(scriptError, browser: browser)
        }
        return "\(browser.displayName): \(error)"
    }
}
