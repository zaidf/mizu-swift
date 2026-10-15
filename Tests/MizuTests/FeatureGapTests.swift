import XCTest
@testable import Mizu

final class FeatureGapTests: XCTestCase {
    func testToolDefinitionsAreValidJSONInBothFormats() throws {
        let anthropic = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: FeatureGap.anthropicTool)) as! [String: Any]
        XCTAssertEqual(anthropic["name"] as? String, "report_unsupported_request")
        let schema = anthropic["input_schema"] as! [String: Any]
        XCTAssertEqual(schema["required"] as? [String], ["want", "user_words"])

        let openAI = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: FeatureGap.openAITool)) as! [String: Any]
        XCTAssertEqual(openAI["type"] as? String, "function")
        let function = openAI["function"] as! [String: Any]
        XCTAssertEqual(function["name"] as? String, "report_unsupported_request")
        XCTAssertNotNil(function["parameters"])

        XCTAssertTrue(FeatureGap.systemPrompt.contains("report_unsupported_request"))
    }

    func testBuildsTheRequestFromTheToolCall() throws {
        let history: [LLMMessage] = (1...15).map { .user("message \($0)") }
        let body = try XCTUnwrap(FeatureGap.requestBody(
            input: ["want": " Export the chat as a PDF ", "user_words": "can you export this?", "why": "", "extra": 1],
            conversation: history, userRef: "tester-7"))
        XCTAssertEqual(body["want"] as? String, "Export the chat as a PDF")
        XCTAssertEqual(body["user_words"] as? String, "can you export this?")
        XCTAssertNil(body["why"], "empty strings are dropped")
        XCTAssertEqual((body["conversation"] as? [[String: String]])?.count, 12, "only the recent conversation")
        XCTAssertEqual((body["conversation"] as? [[String: String]])?.last?["content"], "message 15")
        XCTAssertEqual(body["user_ref"] as? String, "tester-7")
    }

    func testMissingWantTellsTheModelToAsk() {
        XCTAssertNil(FeatureGap.requestBody(input: ["user_words": "x"], conversation: [], userRef: nil))
        XCTAssertTrue(Mizu.handleFeatureGap(input: [:]).contains("\"want\" was missing"))
    }

    func testSafeWhenMizuIsNotRunning() {
        XCTAssertEqual(Mizu.handleFeatureGap(inputJSON: Data(#"{"want":"dark mode"}"#.utf8)), FeatureGap.toolResult)
    }
}
