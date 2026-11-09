import AppKit

public struct ScriptError: Error, Equatable, Sendable {
    public let number: Int
    public let message: String

    public init(number: Int, message: String) {
        self.number = number
        self.message = message
    }
}

public protocol ScriptRunner {
    func run(_ source: String) throws -> String
}

/// Runs AppleScript in-process. NSAppleScript is not thread-safe: call on the main thread.
public struct NSAppleScriptRunner: ScriptRunner {
    public init() {}

    public func run(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw ScriptError(number: 0, message: "Could not create AppleScript")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw ScriptError(
                number: errorInfo[NSAppleScript.errorNumber] as? Int ?? 0,
                message: errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            )
        }
        return result.stringValue ?? ""
    }
}

public protocol MeetBrowser {
    var browser: Browser { get }
    func meetTabs() throws -> [MeetTab]
    func execute(javaScript: String, in tab: MeetTab) throws -> String
}

/// A hung browser must not freeze the main thread (and with it the menu) for AppleScript's 2-minute default.
let appleScriptTimeoutSeconds = 3

/// Drives a Chromium browser (Vivaldi, Chrome) through its AppleScript dictionary.
public struct ChromiumBridge: MeetBrowser {
    public let browser: Browser
    private let runner: ScriptRunner
    private let isRunning: () -> Bool

    public init(browser: Browser, runner: ScriptRunner = NSAppleScriptRunner(), isRunning: (() -> Bool)? = nil) {
        self.browser = browser
        self.runner = runner
        self.isRunning = isRunning ?? {
            !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty
        }
    }

    /// Meet call tabs in window/tab order. Never launches the browser.
    public func meetTabs() throws -> [MeetTab] {
        guard isRunning() else { return [] }
        return parseTabListing(try runner.run(listTabsScript), browser: browser)
    }

    /// Runs JavaScript in `tab`. Never launches the browser (a `tell` would), and refuses to run
    /// if the tab at that position no longer shows `tab.url`: AppleScript window indexes follow
    /// front-to-back order, so a cached position can point at a different tab after a focus change.
    public func execute(javaScript: String, in tab: MeetTab) throws -> String {
        guard isRunning() else {
            throw ScriptError(number: -600, message: "\(browser.displayName) is not running")
        }
        return try runner.run("""
        tell application id "\(browser.bundleID)"
            with timeout of \(appleScriptTimeoutSeconds) seconds
                set targetTab to tab \(tab.index) of window \(tab.window)
                if (URL of targetTab) is not \(appleScriptLiteral(tab.url)) then error "Meet tab moved" number -1728
                execute targetTab javascript \(appleScriptLiteral(javaScript))
            end timeout
        end tell
        """)
    }

    private var listTabsScript: String {
        """
        set fieldSeparator to character id 9
        set listing to ""
        tell application id "\(browser.bundleID)"
            with timeout of \(appleScriptTimeoutSeconds) seconds
                repeat with windowIndex from 1 to count of windows
                    set tabURLs to URL of every tab of window windowIndex
                    repeat with tabIndex from 1 to count of tabURLs
                        set listing to listing & windowIndex & fieldSeparator & tabIndex & fieldSeparator & (item tabIndex of tabURLs) & linefeed
                    end repeat
                end repeat
            end timeout
        end tell
        return listing
        """
    }
}

/// Quotes text as an AppleScript string literal.
public func appleScriptLiteral(_ text: String) -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

/// Turns an AppleScript failure into a menu-ready message with the fix.
public func describe(_ error: ScriptError, browser: Browser) -> String {
    let name = browser.displayName
    if error.number == -1743 {
        return "\(name): Automation not allowed — enable it in System Settings › Privacy & Security › Automation"
    }
    if error.number == -1712 {
        return "\(name): not responding — AppleScript timed out after \(appleScriptTimeoutSeconds) s"
    }
    if error.message.contains("JavaScript through AppleScript is turned off") {
        return "\(name): turn on Allow JavaScript from Apple Events (Chrome: View › Developer) in each profile you use for Meet"
    }
    return "\(name): AppleScript error \(error.number): \(error.message)"
}
