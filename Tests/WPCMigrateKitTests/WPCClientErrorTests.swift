import XCTest
@testable import WPCMigrateKit

final class WPCClientErrorTests: XCTestCase {
    func testReadsTheErrorObjectFollowedByAHintLine() {
        let stderr = """
            {"error": "example_failure", "detail": "example detail"}
            hint: try again later
            """

        let error = WPCClient.error(command: "create", result: ProcessResult(exitCode: 1, stderr: stderr))

        XCTAssertEqual(error.code, "example_failure")
        XCTAssertEqual(error.detail, "example detail")
    }

    func testSkipsProgressObjectsWithoutAnErrorKey() {
        let stderr = """
            {"step": "pulling", "percent": 40}
            {"error": "example_failure", "detail": "example detail"}
            {"step": "cleanup"}
            """

        let error = WPCClient.error(command: "start", result: ProcessResult(exitCode: 1, stderr: stderr))

        XCTAssertEqual(error.code, "example_failure")
        XCTAssertEqual(error.detail, "example detail")
    }

    func testBracesInsideStringsDoNotBreakTheScan() {
        let stderr = #"{"error": "example_failure", "detail": "unexpected } in {value}"}"#

        let error = WPCClient.error(command: "create", result: ProcessResult(exitCode: 1, stderr: stderr))

        XCTAssertEqual(error.detail, "unexpected } in {value}")
    }

    func testFallsBackToTheLastLinesWithoutAnErrorObject() {
        let error = WPCClient.error(command: "create", result: ProcessResult(exitCode: 1, stderr: #"{"step": "pulling"}"# + "\nplain failure"))

        XCTAssertNil(error.code)
        XCTAssertTrue(error.detail.contains("plain failure"))
    }
}
