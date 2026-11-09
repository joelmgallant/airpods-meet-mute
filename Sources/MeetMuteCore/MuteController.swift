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
    /// The call tab found by the last refresh, with the bridge that owns it.
    private var callTarget: (tab: MeetTab, bridge: MeetBrowser)?
    private var sawMeetTabWithoutButton = false

    public private(set) var status: MeetStatus = .idle
    /// The most recent press failure; cleared by the next successful press, or once a poll finds no Meet tab at all.
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
            let tabs: [MeetTab]
            do {
                tabs = try bridge.meetTabs()
            } catch {
                firstError = firstError ?? message(for: error, browser: bridge.browser)
                continue
            }
            for tab in tabs {
                let output: String
                do {
                    output = try bridge.execute(javaScript: MeetToggleJS.invocation(.query), in: tab)
                } catch {
                    firstError = firstError ?? message(for: error, browser: bridge.browser)
                    continue
                }
                switch MeetToggleJS.parse(output) {
                case .state(let mic):
                    callTarget = (tab, bridge)
                    status = .inCall(mic)
                    return status
                case .noButton:
                    sawMeetTabWithoutButton = true
                case .unexpected(let other):
                    firstError = firstError ?? "\(bridge.browser.displayName): unexpected Meet script output: \(other)"
                }
            }
        }
        if firstError == nil && !sawMeetTabWithoutButton { lastPressError = nil }
        callTarget = nil
        status = firstError.map(MeetStatus.error) ?? .idle
        return status
    }

    /// Handles an AirPods mute gesture. Returns the new mic state, or nil when not handled.
    /// Tries the cached call tab first (one Apple Event); only when that fails does it pay for
    /// a full refresh, and then retries once.
    public func handleMuteRequest(shouldMute: Bool) -> MicState? {
        if let target = callTarget, case .state(let mic) = pressOutcome(on: target, shouldMute: shouldMute) {
            recordPress(mic)
            return mic
        }
        refresh()
        guard let target = callTarget else {
            if sawMeetTabWithoutButton { lastPressError = layoutChangedMessage }
            return nil
        }
        switch pressOutcome(on: target, shouldMute: shouldMute) {
        case .state(let mic):
            recordPress(mic)
            return mic
        case .noButton:
            lastPressError = layoutChangedMessage
        case .unexpected(let other):
            lastPressError = "\(target.tab.browser.displayName): unexpected Meet script output: \(other)"
        case .failed(let error):
            lastPressError = message(for: error, browser: target.tab.browser)
        }
        return nil
    }

    private enum PressOutcome {
        case state(MicState)
        case noButton
        case unexpected(String)
        case failed(Error)
    }

    private func pressOutcome(on target: (tab: MeetTab, bridge: MeetBrowser), shouldMute: Bool) -> PressOutcome {
        do {
            let output = try target.bridge.execute(javaScript: MeetToggleJS.invocation(shouldMute ? .mute : .unmute), in: target.tab)
            switch MeetToggleJS.parse(output) {
            case .state(let mic): return .state(mic)
            case .noButton: return .noButton
            case .unexpected(let other): return .unexpected(other)
            }
        } catch {
            return .failed(error)
        }
    }

    private func recordPress(_ mic: MicState) {
        status = .inCall(mic)
        lastPressError = nil
    }

    private func message(for error: Error, browser: Browser) -> String {
        if let scriptError = error as? ScriptError {
            return describe(scriptError, browser: browser)
        }
        return "\(browser.displayName): \(error)"
    }
}
