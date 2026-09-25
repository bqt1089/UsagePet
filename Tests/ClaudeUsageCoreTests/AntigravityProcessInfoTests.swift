import XCTest
@testable import ClaudeUsageCore

final class AntigravityProcessInfoTests: XCTestCase {

    func testParsesEqualsForm() {
        let line = "12345 /Applications/Antigravity.app/Contents/MacOS/language_server --app_data_dir /Users/x/.antigravity --standalone --csrf_token=abcd-1234-efgh-5678 --https_server_port 56725"
        let result = AntigravityProcessInfo.parse(psLine: line)
        XCTAssertEqual(result?.pid, 12345)
        XCTAssertEqual(result?.csrfToken, "abcd-1234-efgh-5678")
    }

    func testParsesSpaceForm() {
        let line = "999 /Applications/Antigravity.app/Contents/MacOS/language_server --standalone --csrf_token abcd-1234-efgh-5678 --app_data_dir /Users/x/.antigravity"
        let result = AntigravityProcessInfo.parse(psLine: line)
        XCTAssertEqual(result?.pid, 999)
        XCTAssertEqual(result?.csrfToken, "abcd-1234-efgh-5678")
    }

    func testNonAntigravityLineReturnsNil() {
        let line = "555 /usr/bin/some_other_process --csrf_token=zzzz"
        XCTAssertNil(AntigravityProcessInfo.parse(psLine: line))
    }

    func testMissingCsrfTokenReturnsNil() {
        let line = "555 /Applications/Antigravity.app/Contents/MacOS/language_server --standalone"
        XCTAssertNil(AntigravityProcessInfo.parse(psLine: line))
    }

    func testEmptyLineReturnsNil() {
        XCTAssertNil(AntigravityProcessInfo.parse(psLine: ""))
    }

    func testParseListenPortsHandlesBothForms() {
        let output = """
        COMMAND     PID   USER   FD   TYPE   DEVICE SIZE/OFF NODE NAME
        language_s 12345 x      10u  IPv4 0x1234      0t0  TCP 127.0.0.1:56725 (LISTEN)
        language_s 12345 x      11u  IPv6 0x5678      0t0  TCP *:56726 (LISTEN)
        """
        let ports = AntigravityProcessInfo.parseListenPorts(lsofOutput: output)
        XCTAssertEqual(ports, [56725, 56726])
    }

    func testParseListenPortsDedupesAndIgnoresGarbage() {
        let output = """
        garbage line with no port
        language_s 1 x 1u IPv4 0x1 0t0 TCP 127.0.0.1:56725 (LISTEN)
        language_s 1 x 1u IPv4 0x1 0t0 TCP 127.0.0.1:56725 (LISTEN)
        """
        let ports = AntigravityProcessInfo.parseListenPorts(lsofOutput: output)
        XCTAssertEqual(ports, [56725])
    }

    func testParseListenPortsEmptyInput() {
        XCTAssertEqual(AntigravityProcessInfo.parseListenPorts(lsofOutput: ""), [])
    }
}
