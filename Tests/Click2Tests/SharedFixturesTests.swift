import XCTest
@testable import Click2

/// Runs the shared cases in Fixtures/ (the Android SDK runs the same files; keep them identical).
final class SharedFixturesTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: (name as NSString).deletingPathExtension, withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func cases(_ f: [String: Any]) throws -> [[String: Any]] {
        let cases = try XCTUnwrap(f["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        return cases
    }

    func testLinkMatching() throws {
        let f = try fixture("link-matching.json")
        let matcher = LinkMatcher(hosts: try XCTUnwrap(f["hosts"] as? [String]))
        for c in try cases(f) {
            let raw = try XCTUnwrap(c["url"] as? String)
            let expected = try XCTUnwrap(c["expected"] as? Bool)
            let url = LenientURL.parse(raw)
            if #available(macOS 14, iOS 17, *) {
                // What older OS versions get: strict parsing of the pre-encoded string.
                XCTAssertNotNil(URL(string: LenientURL.encodeInvalidCharacters(raw), encodingInvalidCharacters: false), raw)
            }
            XCTAssertEqual(url.map(matcher.matches) ?? false, expected, raw)
        }
    }

    func testPastedText() throws {
        let f = try fixture("pasted-text.json")
        let matcher = LinkMatcher(hosts: try XCTUnwrap(f["hosts"] as? [String]))
        for c in try cases(f) {
            let text = try XCTUnwrap(c["text"] as? String)
            let expected = c["expected"] as? String
            XCTAssertTrue(expected != nil || c["expected"] is NSNull, "bad case \(c)")
            XCTAssertEqual(PastedText.link(in: text, matcher: matcher)?.absoluteString, expected, text)
        }
    }

    func testResolution() throws {
        let clicked = URL(string: "https://acme.click2.page/x")!
        for c in try cases(try fixture("resolution.json")) {
            let name = try XCTUnwrap(c["name"] as? String)
            let body = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["body"]))
            let result = ResolveMapper.map(
                clickedURL: clicked,
                platform: try XCTUnwrap(c["platform"] as? String),
                status: try XCTUnwrap(c["status"] as? Int),
                body: body
            )
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            switch (expected["action"] as? String, result) {
            case ("route", .openRoute(let path, _)):
                XCTAssertEqual(path, expected["path"] as? String, name)
            case ("web", .openWeb(let url, let inApp, _)):
                XCTAssertEqual(url.absoluteString, try XCTUnwrap(expected["url"] as? String), name)
                XCTAssertEqual(inApp, expected["inAppBrowser"] as? Bool, name)
            case ("failed", .failed(let reason, _)):
                XCTAssertEqual(reason.rawValue, expected["reason"] as? String, name)
            default:
                XCTFail("\(name): expected \(expected), got \(result)")
            }
        }
    }
}
