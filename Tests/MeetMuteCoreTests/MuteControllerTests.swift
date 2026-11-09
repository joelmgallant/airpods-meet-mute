import Testing
@testable import MeetMuteCore

/// Simulates a browser: `micMuted[tabIndex]` is the Meet mic state, absent = no mic button.
final class FakeBrowser: MeetBrowser {
    let browser: Browser
    var tabs: [MeetTab]
    var micMuted: [Int: Bool]
    var listingError: ScriptError?
    var mutationError: ScriptError?
    /// Per-tab failure for the `query` mode, keyed by tab index.
    var queryErrors: [Int: ScriptError] = [:]
    private(set) var executedModes: [String] = []
    private(set) var meetTabsCallCount = 0
    /// Raw script output returned instead of a state, per mode kind.
    var queryOutput: String?
    var mutationOutput: String?
    /// A non-ScriptError failure from the listing.
    var listingFailure: Error?

    init(_ browser: Browser, tabs: [MeetTab] = [], micMuted: [Int: Bool] = [:]) {
        self.browser = browser
        self.tabs = tabs
        self.micMuted = micMuted
    }

    func meetTabs() throws -> [MeetTab] {
        meetTabsCallCount += 1
        if let listingFailure { throw listingFailure }
        if let listingError { throw listingError }
        return tabs
    }

    func execute(javaScript: String, in tab: MeetTab) throws -> String {
        let mode = ["query", "mute", "unmute"].first { javaScript.hasSuffix("(\"\($0)\")") } ?? "?"
        executedModes.append(mode)
        if mode == "query", let queryError = queryErrors[tab.index] { throw queryError }
        if mode != "query", let mutationError { throw mutationError }
        if mode == "query", let queryOutput { return queryOutput }
        if mode != "query", let mutationOutput { return mutationOutput }
        guard let muted = micMuted[tab.index] else { return "no-button" }
        switch mode {
        case "mute": micMuted[tab.index] = true; return "muted"
        case "unmute": micMuted[tab.index] = false; return "unmuted"
        default: return muted ? "muted" : "unmuted"
        }
    }
}

struct SampleFailure: Error {}

func meetTab(_ browser: Browser, window: Int = 1, index: Int) -> MeetTab {
    MeetTab(browser: browser, window: window, index: index, url: "https://meet.google.com/abc-defg-hij")
}

@Test func refreshIsIdleWithoutMeetTabs() {
    let controller = MuteController(browsers: [FakeBrowser(.vivaldi), FakeBrowser(.chrome)])
    #expect(controller.refresh() == .idle)
}

@Test func refreshSkipsMeetTabsWithoutAMicButton() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 1), meetTab(.vivaldi, index: 2)], micMuted: [2: false])
    let controller = MuteController(browsers: [vivaldi])
    #expect(controller.refresh() == .inCall(.unmuted))
}

@Test func refreshPrefersTheEarlierBrowser() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 1)], micMuted: [1: true])
    let chrome = FakeBrowser(.chrome, tabs: [meetTab(.chrome, index: 1)], micMuted: [1: false])
    #expect(MuteController(browsers: [vivaldi, chrome]).refresh() == .inCall(.muted))
}

@Test func refreshReportsADescribedErrorWhenNoCallIsFound() {
    let vivaldi = FakeBrowser(.vivaldi)
    vivaldi.listingError = ScriptError(number: -1743, message: "Not authorized")
    let status = MuteController(browsers: [vivaldi, FakeBrowser(.chrome)]).refresh()
    guard case .error(let message) = status else {
        Issue.record("expected .error, got \(status)")
        return
    }
    #expect(message.contains("Automation"))
}

@Test func refreshIgnoresOneBrowsersErrorWhenAnotherHasTheCall() {
    let vivaldi = FakeBrowser(.vivaldi)
    vivaldi.listingError = ScriptError(number: -1743, message: "Not authorized")
    let chrome = FakeBrowser(.chrome, tabs: [meetTab(.chrome, index: 1)], micMuted: [1: false])
    #expect(MuteController(browsers: [vivaldi, chrome]).refresh() == .inCall(.unmuted))
}

@Test func muteRequestMutesTheCallTab() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 3)], micMuted: [3: false])
    let controller = MuteController(browsers: [vivaldi])
    #expect(controller.handleMuteRequest(shouldMute: true) == .muted)
    #expect(vivaldi.micMuted[3] == true)
    #expect(vivaldi.executedModes.last == "mute")
    #expect(controller.status == .inCall(.muted))
    #expect(controller.lastPressError == nil)
}

@Test func unmuteRequestUnmutesTheCallTab() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 1)], micMuted: [1: true])
    let controller = MuteController(browsers: [vivaldi])
    #expect(controller.handleMuteRequest(shouldMute: false) == .unmuted)
    #expect(vivaldi.micMuted[1] == false)
}

@Test func muteRequestIsNotHandledWithoutAMeetTab() {
    let vivaldi = FakeBrowser(.vivaldi)
    let controller = MuteController(browsers: [vivaldi])
    #expect(controller.handleMuteRequest(shouldMute: true) == nil)
    #expect(controller.lastPressError == nil)
    #expect(controller.status == .idle)
}

@Test func muteRequestFlagsALayoutChangeWhenAMeetTabHasNoMicButton() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 1)])
    let controller = MuteController(browsers: [vivaldi])
    #expect(controller.handleMuteRequest(shouldMute: true) == nil)
    #expect(controller.lastPressError == layoutChangedMessage)
}

@Test func muteRequestSurfacesScriptErrors() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 1)], micMuted: [1: false])
    vivaldi.mutationError = ScriptError(number: 12, message: "Executing JavaScript through AppleScript is turned off.")
    let controller = MuteController(browsers: [vivaldi])
    #expect(controller.handleMuteRequest(shouldMute: true) == nil)
    #expect(controller.lastPressError?.contains("Allow JavaScript from Apple Events") == true)
}

@Test func aSuccessfulPressClearsThePreviousPressError() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 1)], micMuted: [1: false])
    vivaldi.mutationError = ScriptError(number: -2700, message: "boom")
    let controller = MuteController(browsers: [vivaldi])
    _ = controller.handleMuteRequest(shouldMute: true)
    vivaldi.mutationError = nil
    #expect(controller.handleMuteRequest(shouldMute: true) == .muted)
    #expect(controller.lastPressError == nil)
}

@Test func refreshContinuesPastATabThatFailsToAnswer() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 1), meetTab(.vivaldi, index: 2)], micMuted: [2: true])
    vivaldi.queryErrors[1] = ScriptError(number: -2700, message: "boom")
    #expect(MuteController(browsers: [vivaldi]).refresh() == .inCall(.muted))
}

@Test func refreshReportsATabErrorWhenNoCallIsFound() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 1)])
    vivaldi.queryErrors[1] = ScriptError(number: -2700, message: "boom")
    let status = MuteController(browsers: [vivaldi]).refresh()
    guard case .error(let message) = status else {
        Issue.record("expected .error, got \(status)")
        return
    }
    #expect(message.contains("boom"))
}

@Test func aStalePressErrorClearsOnceNoMeetTabRemains() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 1)])
    let controller = MuteController(browsers: [vivaldi])
    #expect(controller.handleMuteRequest(shouldMute: true) == nil)
    #expect(controller.lastPressError == layoutChangedMessage)
    vivaldi.tabs = []
    controller.refresh()
    #expect(controller.lastPressError == nil)
}

@Test func aPressErrorPersistsWhileTheCallIsLive() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 1)], micMuted: [1: false])
    vivaldi.mutationError = ScriptError(number: -2700, message: "boom")
    let controller = MuteController(browsers: [vivaldi])
    #expect(controller.handleMuteRequest(shouldMute: true) == nil)
    #expect(controller.lastPressError != nil)
    controller.refresh()
    #expect(controller.lastPressError != nil)
}

@Test func aPressErrorPersistsWhenAListingFails() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 1)], micMuted: [1: false])
    vivaldi.mutationError = ScriptError(number: -2700, message: "boom")
    let controller = MuteController(browsers: [vivaldi])
    #expect(controller.handleMuteRequest(shouldMute: true) == nil)
    vivaldi.listingError = ScriptError(number: -1743, message: "Not authorized")
    controller.refresh()
    #expect(controller.lastPressError != nil)
}

@Test func refreshReportsUnexpectedScriptOutputWhenNoCallIsFound() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 1)], micMuted: [1: false])
    vivaldi.queryOutput = "garbled"
    let status = MuteController(browsers: [vivaldi]).refresh()
    guard case .error(let message) = status else {
        Issue.record("expected .error, got \(status)")
        return
    }
    #expect(message.contains("garbled"))
}

@Test func muteRequestSurfacesUnexpectedScriptOutput() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 1)], micMuted: [1: false])
    let controller = MuteController(browsers: [vivaldi])
    controller.refresh()
    vivaldi.mutationOutput = "garbled"
    #expect(controller.handleMuteRequest(shouldMute: true) == nil)
    #expect(controller.lastPressError?.contains("garbled") == true)
}

@Test func aNonScriptErrorIsPrefixedWithTheBrowserName() {
    let vivaldi = FakeBrowser(.vivaldi)
    vivaldi.listingFailure = SampleFailure()
    let status = MuteController(browsers: [vivaldi]).refresh()
    guard case .error(let message) = status else {
        Issue.record("expected .error, got \(status)")
        return
    }
    #expect(message.hasPrefix("Vivaldi:"))
}

@Test func aPressUsesTheCachedCallTabWithoutListingAgain() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 3)], micMuted: [3: false])
    let controller = MuteController(browsers: [vivaldi])
    #expect(controller.refresh() == .inCall(.unmuted))
    let listingsBeforePress = vivaldi.meetTabsCallCount
    #expect(controller.handleMuteRequest(shouldMute: true) == .muted)
    #expect(vivaldi.meetTabsCallCount == listingsBeforePress)
    #expect(vivaldi.micMuted[3] == true)
}

@Test func aPressFallsBackToRefreshWhenTheCachedTabHasNoMicButton() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 3)], micMuted: [3: false])
    let controller = MuteController(browsers: [vivaldi])
    #expect(controller.refresh() == .inCall(.unmuted))
    vivaldi.micMuted[3] = nil
    vivaldi.tabs = [meetTab(.vivaldi, index: 5)]
    vivaldi.micMuted[5] = false
    let listingsBeforePress = vivaldi.meetTabsCallCount
    #expect(controller.handleMuteRequest(shouldMute: true) == .muted)
    #expect(vivaldi.meetTabsCallCount == listingsBeforePress + 1)
    #expect(vivaldi.micMuted[5] == true)
    #expect(controller.lastPressError == nil)
}

@Test func aPressFallsBackToRefreshWhenTheCachedTabThrowsAndReportsIfItStillFails() {
    let vivaldi = FakeBrowser(.vivaldi, tabs: [meetTab(.vivaldi, index: 3)], micMuted: [3: false])
    let controller = MuteController(browsers: [vivaldi])
    #expect(controller.refresh() == .inCall(.unmuted))
    vivaldi.mutationError = ScriptError(number: -2700, message: "boom")
    let listingsBeforePress = vivaldi.meetTabsCallCount
    #expect(controller.handleMuteRequest(shouldMute: true) == nil)
    #expect(vivaldi.meetTabsCallCount == listingsBeforePress + 1)
    #expect(controller.lastPressError?.contains("boom") == true)
}
