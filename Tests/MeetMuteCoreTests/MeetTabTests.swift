import Testing
@testable import MeetMuteCore

@Test func meetCallURLMatchesMeetingCodes() {
    #expect(isMeetCallURL("https://meet.google.com/abc-defg-hij"))
    #expect(isMeetCallURL("https://meet.google.com/abc-defg-hij?authuser=1"))
    #expect(isMeetCallURL("https://meet.google.com/abc-defg-hij/"))
    #expect(isMeetCallURL("https://meet.google.com/abc-defg-hij#x"))
    // Form observed in a live call (docs/spike-findings.md)
    #expect(isMeetCallURL("https://meet.google.com/meet/qrs-tuvw-xyz"))
    #expect(isMeetCallURL("https://meet.google.com/meet/qrs-tuvw-xyz?authuser=1"))
}

@Test func meetCallURLRejectsNonCallPages() {
    #expect(!isMeetCallURL("https://meet.google.com/"))
    #expect(!isMeetCallURL("https://meet.google.com/landing"))
    #expect(!isMeetCallURL("https://meet.google.com/meet/"))
    #expect(!isMeetCallURL("https://meet.google.com/other/abc-defg-hij"))
    #expect(!isMeetCallURL("https://meet.google.com/abc-defg-hijk"))
    #expect(!isMeetCallURL("http://meet.google.com/abc-defg-hij"))
    #expect(!isMeetCallURL("https://evil.example/https://meet.google.com/abc-defg-hij"))
}

@Test func parseTabListingKeepsOnlyMeetCallTabsInOrder() {
    let listing = """
    1\t1\thttps://mail.google.com/
    1\t2\thttps://meet.google.com/abc-defg-hij
    2\t1\thttps://meet.google.com/meet/xyz-abcd-efg?authuser=0

    """
    #expect(parseTabListing(listing, browser: .vivaldi) == [
        MeetTab(browser: .vivaldi, window: 1, index: 2, url: "https://meet.google.com/abc-defg-hij"),
        MeetTab(browser: .vivaldi, window: 2, index: 1, url: "https://meet.google.com/meet/xyz-abcd-efg?authuser=0"),
    ])
}

@Test func parseTabListingIgnoresMalformedLines() {
    let listing = "\ngarbage\n1\tx\thttps://meet.google.com/abc-defg-hij\n3\t4\thttps://meet.google.com/abc-defg-hij\n"
    #expect(parseTabListing(listing, browser: .chrome) == [
        MeetTab(browser: .chrome, window: 3, index: 4, url: "https://meet.google.com/abc-defg-hij"),
    ])
}

@Test func browserMetadata() {
    #expect(Browser.allCases == [.vivaldi, .chrome])
    #expect(Browser.vivaldi.bundleID == "com.vivaldi.Vivaldi")
    #expect(Browser.chrome.displayName == "Chrome")
}
