import Foundation

/// Chromium browsers we drive, in priority order (Vivaldi first).
public enum Browser: String, CaseIterable, Sendable {
    case vivaldi = "com.vivaldi.Vivaldi"
    case chrome = "com.google.Chrome"

    public var bundleID: String { rawValue }

    public var displayName: String {
        switch self {
        case .vivaldi: "Vivaldi"
        case .chrome: "Chrome"
        }
    }
}

/// A browser tab whose URL is a Meet meeting code. Window and tab indexes are
/// 1-based AppleScript indexes, valid only until the user rearranges tabs.
public struct MeetTab: Equatable, Sendable {
    public let browser: Browser
    public let window: Int
    public let index: Int
    public let url: String

    public init(browser: Browser, window: Int, index: Int, url: String) {
        self.browser = browser
        self.window = window
        self.index = index
        self.url = url
    }
}

private let meetCallPattern = try! Regex(#"^https://meet\.google\.com/(?:meet/)?[a-z]{3}-[a-z]{4}-[a-z]{3}(?:[/?#]|$)"#)

public func isMeetCallURL(_ url: String) -> Bool {
    url.firstMatch(of: meetCallPattern) != nil
}

/// Parses `window<TAB>index<TAB>url` lines (the AppleScript tab listing) and
/// keeps only Meet call tabs, preserving order.
public func parseTabListing(_ listing: String, browser: Browser) -> [MeetTab] {
    listing.split(whereSeparator: \.isNewline).compactMap { line in
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3,
              let window = Int(fields[0]),
              let index = Int(fields[1]) else { return nil }
        let url = String(fields[2])
        return isMeetCallURL(url) ? MeetTab(browser: browser, window: window, index: index, url: url) : nil
    }
}
