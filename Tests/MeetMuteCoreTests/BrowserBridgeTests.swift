import Testing
@testable import MeetMuteCore

final class RecordingRunner: ScriptRunner {
    private(set) var scripts: [String] = []
    private var responses: [Result<String, ScriptError>]

    init(_ responses: [Result<String, ScriptError>]) {
        self.responses = responses
    }

    func run(_ source: String) throws -> String {
        scripts.append(source)
        return try responses.removeFirst().get()
    }
}

@Test func meetTabsSkipsABrowserThatIsNotRunning() throws {
    let runner = RecordingRunner([])
    let bridge = ChromiumBridge(browser: .vivaldi, runner: runner, isRunning: { false })
    #expect(try bridge.meetTabs() == [])
    #expect(runner.scripts.isEmpty)
}

@Test func meetTabsTargetsTheBrowserByBundleIDAndParsesTheListing() throws {
    let runner = RecordingRunner([.success("1\t3\thttps://meet.google.com/abc-defg-hij\n1\t4\thttps://example.com/\n")])
    let bridge = ChromiumBridge(browser: .vivaldi, runner: runner, isRunning: { true })
    #expect(try bridge.meetTabs() == [
        MeetTab(browser: .vivaldi, window: 1, index: 3, url: "https://meet.google.com/abc-defg-hij"),
    ])
    #expect(runner.scripts[0].contains(#"tell application id "com.vivaldi.Vivaldi""#))
}

@Test func meetTabsPropagatesScriptErrors() {
    let denial = ScriptError(number: -1743, message: "Not authorized to send Apple events to Vivaldi.")
    let bridge = ChromiumBridge(browser: .vivaldi, runner: RecordingRunner([.failure(denial)]), isRunning: { true })
    #expect(throws: denial) { try bridge.meetTabs() }
}

@Test func executeEmbedsEscapedJavaScriptForTheRightTab() throws {
    let runner = RecordingRunner([.success("muted")])
    let bridge = ChromiumBridge(browser: .chrome, runner: runner, isRunning: { true })
    let tab = MeetTab(browser: .chrome, window: 2, index: 5, url: "https://meet.google.com/abc-defg-hij")
    #expect(try bridge.execute(javaScript: #"f("a\b")"#, in: tab) == "muted")
    #expect(runner.scripts[0].contains(#"tell application id "com.google.Chrome""#))
    #expect(runner.scripts[0].contains("set targetTab to tab 5 of window 2"))
    #expect(runner.scripts[0].contains(#"execute targetTab javascript "f(\"a\\b\")""#))
}

@Test func executeRefusesToLaunchABrowserThatIsNotRunning() {
    let runner = RecordingRunner([])
    let bridge = ChromiumBridge(browser: .vivaldi, runner: runner, isRunning: { false })
    let tab = MeetTab(browser: .vivaldi, window: 1, index: 1, url: "https://meet.google.com/abc-defg-hij")
    #expect(throws: ScriptError.self) { try bridge.execute(javaScript: "f()", in: tab) }
    #expect(runner.scripts.isEmpty)
}

@Test func executeOnlyRunsInATabStillShowingTheExpectedURL() throws {
    let runner = RecordingRunner([.success("muted")])
    let bridge = ChromiumBridge(browser: .vivaldi, runner: runner, isRunning: { true })
    let tab = MeetTab(browser: .vivaldi, window: 1, index: 2, url: "https://meet.google.com/meet/qrs-tuvw-xyz")
    _ = try bridge.execute(javaScript: "f()", in: tab)
    let script = runner.scripts[0]
    #expect(script.contains(#"if (URL of targetTab) is not "https://meet.google.com/meet/qrs-tuvw-xyz" then error"#))
    let urlCheck = try #require(script.range(of: "if (URL of targetTab)"))
    let execution = try #require(script.range(of: "execute targetTab"))
    #expect(urlCheck.lowerBound < execution.lowerBound)
}

@Test func appleScriptLiteralEscapesBackslashesAndQuotes() {
    #expect(appleScriptLiteral(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
}

@Test func describeExplainsAutomationDenial() {
    let text = describe(ScriptError(number: -1743, message: "Not authorized to send Apple events to Vivaldi."), browser: .vivaldi)
    #expect(text.hasPrefix("Vivaldi:"))
    #expect(text.contains("Privacy & Security › Automation"))
}

@Test func describeExplainsDisabledJavaScriptFromAppleEvents() {
    let message = "Executing JavaScript through AppleScript is turned off. To turn it on, from the menu bar, go to View > Developer > Allow JavaScript from Apple Events."
    let text = describe(ScriptError(number: 12, message: message), browser: .chrome)
    #expect(text.hasPrefix("Chrome:"))
    #expect(text.contains("Allow JavaScript from Apple Events"))
    #expect(text.contains("each profile"))
}

@Test func describeFallsBackToTheRawError() {
    #expect(describe(ScriptError(number: -2700, message: "boom"), browser: .chrome) == "Chrome: AppleScript error -2700: boom")
}

@Test func bothGeneratedScriptsRunUnderAThreeSecondTimeout() throws {
    let runner = RecordingRunner([.success(""), .success("muted")])
    let bridge = ChromiumBridge(browser: .vivaldi, runner: runner, isRunning: { true })
    _ = try bridge.meetTabs()
    _ = try bridge.execute(javaScript: "f()", in: MeetTab(browser: .vivaldi, window: 1, index: 1, url: "https://meet.google.com/abc-defg-hij"))
    #expect(runner.scripts[0].contains("with timeout of 3 seconds"))
    #expect(runner.scripts[0].contains("end timeout"))
    #expect(runner.scripts[1].contains("with timeout of 3 seconds"))
    #expect(runner.scripts[1].contains("end timeout"))
}

@Test func tabListingReadsEachWindowsURLsInOneAppleEvent() throws {
    let runner = RecordingRunner([.success("")])
    let bridge = ChromiumBridge(browser: .vivaldi, runner: runner, isRunning: { true })
    _ = try bridge.meetTabs()
    #expect(runner.scripts[0].contains("URL of every tab of window windowIndex"))
    #expect(!runner.scripts[0].contains("URL of tab"))
}

@Test func describeExplainsAnAppleScriptTimeout() {
    let text = describe(ScriptError(number: -1712, message: "Apple event timed out."), browser: .vivaldi)
    #expect(text == "Vivaldi: not responding — AppleScript timed out after 3 s")
}
