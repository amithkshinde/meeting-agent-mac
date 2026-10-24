import XCTest
@testable import MeetingAgent

final class CallDetectorTests: XCTestCase {
    func testGoogleMeetInChrome() {
        XCTAssertEqual(
            CallDetector.classify(owner: "Google Chrome", title: "Meet - abc-defg-hij", micOn: false),
            "Google Meet"
        )
    }

    func testChromeOnOtherSiteIsNotACall() {
        XCTAssertNil(CallDetector.classify(owner: "Google Chrome", title: "Inbox - Gmail", micOn: true))
    }

    func testZoomMeetingWindow() {
        XCTAssertEqual(
            CallDetector.classify(owner: "zoom.us", title: "Zoom Meeting", micOn: true),
            "Zoom"
        )
    }

    func testZoomHomeWindowIsNotACall() {
        XCTAssertNil(CallDetector.classify(owner: "zoom.us", title: "Zoom Workplace", micOn: true))
    }

    func testTeamsNeedsMicrophone() {
        XCTAssertNil(CallDetector.classify(owner: "Microsoft Teams", title: "Chat | Microsoft Teams", micOn: false))
        XCTAssertEqual(
            CallDetector.classify(owner: "Microsoft Teams", title: "Chat | Microsoft Teams", micOn: true),
            "Microsoft Teams"
        )
    }

    func testSlackHuddle() {
        XCTAssertEqual(
            CallDetector.classify(owner: "Slack", title: "Huddle with Priya", micOn: true),
            "Slack huddle"
        )
    }
}
