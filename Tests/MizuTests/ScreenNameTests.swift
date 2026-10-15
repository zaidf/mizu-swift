import XCTest
@testable import Mizu

final class SpokenScreenNameTests: XCTestCase {
    func testSpokenNamesReadLikeAPersonWouldSayThem() {
        XCTAssertEqual(ScreenName.spoken("PrewarmingViewController"), "prewarming")
        XCTAssertEqual(ScreenName.spoken("HotelDetailView"), "hotel detail")
        XCTAssertEqual(ScreenName.spoken("Chat"), "chat")
        XCTAssertEqual(ScreenName.spoken("View"), "view")
        XCTAssertEqual(ScreenName.spoken("settings_screen"), "settings screen")
        XCTAssertEqual(ScreenName.spoken("URLPreview"), "urlpreview")
    }
}
