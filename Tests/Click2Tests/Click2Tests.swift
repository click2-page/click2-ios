import XCTest
@testable import Click2

private typealias Response = Result<(status: Int, body: Data), Error>

/// Answers GETs and POSTs from separate scripts (they may run concurrently); 500 when a script runs out.
private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var get: [Response]
    private var post: [Response]
    private var requests: [URLRequest] = []
    private var finished = 0
    private let delay: TimeInterval
    private let postDelay: TimeInterval

    init(get: [Response] = [], post: [Response] = [], delay: TimeInterval = 0, postDelay: TimeInterval = 0) {
        self.get = get
        self.post = post
        self.delay = delay
        self.postDelay = postDelay
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let isPost = request.httpMethod == "POST"
        let next: Response = locked {
            requests.append(request)
            if isPost { return post.isEmpty ? .success((500, Data())) : post.removeFirst() }
            return get.isEmpty ? .success((500, Data())) : get.removeFirst()
        }
        defer { locked { finished += 1 } }
        let wait = isPost ? postDelay : delay
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        return try next.get()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var sent: [URLRequest] { locked { requests } }
    var finishedCount: Int { locked { finished } }
    func sent(_ method: String) -> [URLRequest] { sent.filter { $0.httpMethod == method } }
}

private let okBody = Data("""
{"alias":"subs","deeplinkPath":"orders/subs?id=1&src=sms","iosDeeplinkPath":"orders/subs?id=1&src=sms","webOnly":false,"mobileWebOnly":false,
 "webUrl":"https://www.acme.com","iosUrl":"https://www.acme.com","androidUrl":"https://www.acme.com","campaign":"sms"}
""".utf8)

final class Click2Tests: XCTestCase {
    private let link = URL(string: "https://acme.click2.page/subs?id=1&src=sms+x")!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "page.click2.sdk.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        await Click2.installTaskForTesting?.value
        Click2.unconfigureForTesting(failFast: true)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func configure(get: [Response] = [], post: [Response] = [], delay: TimeInterval = 0, postDelay: TimeInterval = 0,
                           timeout: TimeInterval = 10) -> FakeTransport {
        let transport = FakeTransport(get: get, post: post, delay: delay, postDelay: postDelay)
        Click2.configure(Click2Config(hosts: ["acme.click2.page"], appVersion: "7.2.0", timeout: timeout), transport: transport, defaults: defaults)
        return transport
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func deferred(_ url: URL? = nil) async -> Click2Result? {
        let result = await Click2.handleDeferredLink(url ?? link)
        await Click2.installTaskForTesting?.value
        return result
    }

    // MARK: Resolving

    func testResolvesAgainstTheLinksHostWithAnEncodedURL() async throws {
        let transport = configure(get: [.success((200, okBody))])
        let result = await Click2.resolve(link)

        guard case .openRoute(let path, let resolved) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(path, "orders/subs?id=1&src=sms")
        XCTAssertEqual(resolved.campaign, "sms")

        let request = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(request.url?.host, "acme.click2.page")
        XCTAssertEqual(request.url?.path, "/api/v1/resolve")
        // "&", "=" and "+" inside the clicked link must not leak into the outer query.
        XCTAssertEqual(query(request), ["url": link.absoluteString, "platform": "ios", "appVersion": "7.2.0"])
        XCTAssertTrue(request.url!.absoluteString.contains("%26src%3Dsms%2Bx"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "click2-ios/\(Click2.sdkVersion)")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Tracking-Disabled"))
    }

    func testIgnoresOtherLinksWithoutCallingTheNetwork() async {
        let transport = configure()
        let other = await Click2.resolve(URL(string: "https://evil.com/subs")!)
        XCTAssertEqual(other, .notAClick2Link)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testTrackingOptOutIsSentAndRemembered() async throws {
        let transport = configure(get: [.success((200, okBody))])
        Click2.isTrackingEnabled = false
        _ = await Click2.resolve(link)
        XCTAssertEqual(try XCTUnwrap(transport.sent.first).value(forHTTPHeaderField: "X-Tracking-Disabled"), "1")
        XCTAssertFalse(Click2.isTrackingEnabled)
        XCTAssertFalse(defaults.bool(forKey: "tracking_enabled"))
    }

    func testUniversalLinkActivity() async {
        _ = configure(get: [.success((200, okBody))])
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = link
        XCTAssertTrue(Click2.isClick2Link(activity))
        if case .openRoute = await Click2.handle(activity) {} else { XCTFail("expected a route") }

        let other = NSUserActivity(activityType: "com.example.other")
        XCTAssertFalse(Click2.isClick2Link(other))
        let notOurs = await Click2.handle(other)
        XCTAssertEqual(notOurs, .notAClick2Link)
    }

    // MARK: Retries and timeouts

    func testRetriesOnceThenReportsANetworkError() async {
        let retried = configure(get: [.failure(URLError(.networkConnectionLost)), .success((200, okBody))])
        if case .openRoute = await Click2.resolve(link) {} else { XCTFail("expected a route after retry") }
        XCTAssertEqual(retried.sent.count, 2)

        let unreachable = configure(get: [.failure(URLError(.cannotConnectToHost)), .success((200, okBody))])
        if case .openRoute = await Click2.resolve(link) {} else { XCTFail("expected a route after retry") }
        XCTAssertEqual(unreachable.sent.count, 2)

        let offline = configure(get: [.failure(URLError(.notConnectedToInternet)), .failure(URLError(.notConnectedToInternet)), .success((200, okBody))])
        let result = await Click2.resolve(link)
        XCTAssertEqual(result, .failed(reason: .networkError, url: link))
        XCTAssertEqual(offline.sent.count, 2)
    }

    func testDoesNotRetryTimeoutsOrCancellation() async {
        for code in [URLError.Code.timedOut, .cancelled] {
            let transport = configure(get: [.failure(URLError(code)), .success((200, okBody))])
            let result = await Click2.resolve(link)
            XCTAssertEqual(result, .failed(reason: .networkError, url: link), "\(code)")
            XCTAssertEqual(transport.sent.count, 1, "\(code)")
        }
    }

    func testDoesNotRetryWhenTheTaskIsCancelled() async {
        let transport = configure(get: [.success((200, okBody)), .success((200, okBody))], delay: 5)
        let task = Task { await Click2.resolve(link) }
        while transport.sent.isEmpty { await Task.yield() }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .failed(reason: .networkError, url: link))
        XCTAssertEqual(transport.sent.count, 1)
    }

    func testSlowButActiveResponsesStillStopAtTheBudget() async {
        // The fake responds only after 5 s without ever being "idle"-timed-out; the hard cap must win.
        _ = configure(get: [.success((200, okBody))], delay: 5, timeout: 0.3)
        let started = Date()
        let result = await Click2.resolve(link)
        XCTAssertEqual(result, .failed(reason: .networkError, url: link))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTimeoutIsTheTotalBudget() async throws {
        let transport = configure(get: [.failure(URLError(.cannotConnectToHost)), .failure(URLError(.cannotConnectToHost))], delay: 0.2, timeout: 2)
        _ = await Click2.resolve(link)
        let intervals = transport.sent.map(\.timeoutInterval)
        XCTAssertEqual(intervals.count, 2)
        XCTAssertLessThanOrEqual(intervals[0], 2)
        XCTAssertLessThan(intervals[1], intervals[0] - 0.15)

        let exhausted = configure(get: [.failure(URLError(.cannotConnectToHost)), .success((200, okBody))], delay: 0.3, timeout: 0.2)
        let result = await Click2.resolve(link)
        XCTAssertEqual(result, .failed(reason: .networkError, url: link))
        XCTAssertEqual(exhausted.sent.count, 1, "no attempt after the budget is spent")
    }

    func testInstallIsRetriedOnlyWhenItWasNeverSent() async {
        for code in [URLError.Code.timedOut, .networkConnectionLost] {
            let transport = configure(get: [.success((200, okBody))], post: [.failure(URLError(code)), .success((204, Data()))])
            _ = await deferred()
            XCTAssertEqual(transport.sent("POST").count, 1, "\(code)")
        }
        let transport = configure(get: [.success((200, okBody))], post: [.failure(URLError(.cannotConnectToHost)), .success((204, Data()))])
        _ = await deferred()
        XCTAssertEqual(transport.sent("POST").count, 2)
    }

    // MARK: Deferred links and installs

    func testDeferredLinkReportsTheInstallOnlyOnce() async throws {
        let transport = configure(get: [.success((200, okBody)), .success((200, okBody))], post: [.success((204, Data()))])

        let first = await deferred()
        if case .openRoute = first {} else { XCTFail("got \(String(describing: first))") }
        let second = await deferred()
        if case .openRoute = second {} else { XCTFail("got \(String(describing: second))") }

        XCTAssertEqual(transport.sent("POST").map { $0.url!.path }, ["/api/v1/events"])
        XCTAssertEqual(transport.sent("GET").map { $0.url!.path }, ["/api/v1/resolve", "/api/v1/resolve"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(transport.sent("POST")[0].httpBody)) as? [String: String])
        XCTAssertEqual(body, ["type": "install", "url": link.absoluteString, "platform": "ios", "appVersion": "7.2.0"])

        let foreign = await Click2.handleDeferredLink(URL(string: "https://evil.com/x")!)
        XCTAssertNil(foreign)
    }

    func testNoInstallIsSentWhenTrackingIsOff() async {
        let transport = configure(get: [.success((200, okBody)), .success((200, okBody))], post: [.success((204, Data()))])
        Click2.isTrackingEnabled = false
        if case .openRoute = await deferred() {} else { XCTFail("expected a route") }
        XCTAssertTrue(transport.sent("POST").isEmpty)

        // Not marked as reported: turning tracking on later still records it.
        Click2.isTrackingEnabled = true
        _ = await deferred()
        XCTAssertEqual(transport.sent("POST").count, 1)
    }

    func testFailedInstallIsReportedOnTheNextDeferredLink() async {
        let transport = configure(
            get: [.success((200, okBody)), .success((200, okBody)), .success((200, okBody)), .success((200, okBody))],
            post: [.failure(URLError(.notConnectedToInternet)), .failure(URLError(.notConnectedToInternet)), .success((503, Data())), .success((204, Data()))]
        )
        if case .openRoute = await deferred() {} else { XCTFail("offline install must not break routing") }
        _ = await deferred()   // 503
        _ = await deferred()   // 204
        _ = await deferred()   // done
        XCTAssertEqual(transport.sent("POST").count, 4)
        XCTAssertTrue(defaults.bool(forKey: "install_reported"))
    }

    func testInstallRejectedByTheServerIsNotRetried() async {
        let transport = configure(get: [.success((200, okBody)), .success((200, okBody))], post: [.success((400, Data())), .success((204, Data()))])
        _ = await deferred()
        _ = await deferred()
        XCTAssertEqual(transport.sent("POST").count, 1)
    }

    func testConcurrentDeferredLinksReportOneInstall() async {
        let transport = configure(get: [.success((200, okBody)), .success((200, okBody))], post: [.success((204, Data())), .success((204, Data()))], postDelay: 0.2)
        async let a = Click2.handleDeferredLink(link)
        async let b = Click2.handleDeferredLink(link)
        _ = await (a, b)
        await Click2.installTaskForTesting?.value
        XCTAssertEqual(transport.sent("POST").count, 1)
        XCTAssertEqual(transport.sent("GET").count, 2)
    }

    func testRoutingDoesNotWaitForTheInstall() async {
        let transport = configure(get: [.success((200, okBody))], post: [.success((204, Data()))], postDelay: 0.3)
        let result = await Click2.handleDeferredLink(link)
        if case .openRoute = result {} else { XCTFail("got \(String(describing: result))") }
        XCTAssertEqual(transport.finishedCount, 1, "only the resolve has finished")
    }

    func testMarkInstallReportedSkipsTheInstall() async {
        let transport = configure(get: [.success((200, okBody))], post: [.success((204, Data()))])
        Click2.markInstallReported()
        _ = await deferred()
        XCTAssertTrue(transport.sent("POST").isEmpty)
    }

    func testDeferredLinkFromPastedText() async {
        let transport = configure(get: [.success((200, okBody))], post: [.success((204, Data()))])
        let result = await Click2.handleDeferredLink(text: "  Open \(link.absoluteString) \n")
        await Click2.installTaskForTesting?.value
        if case .openRoute = result {} else { XCTFail("got \(String(describing: result))") }
        XCTAssertEqual(query(transport.sent("GET")[0])["url"], link.absoluteString)
        let none = await Click2.handleDeferredLink(text: "https://evil.com/subs")
        XCTAssertNil(none)
    }

    // MARK: Parsing

    func testLenientURLEncodesOnlyInvalidCharacters() {
        XCTAssertEqual(
            LenientURL.encodeInvalidCharacters("https://h.page/s?u=hero|banner&x={id}&d=50%off&e=%2F#a#b"),
            "https://h.page/s?u=hero%7Cbanner&x=%7Bid%7D&d=50%25off&e=%2F#a%23b"
        )
        XCTAssertEqual(LenientURL.encodeInvalidCharacters("https://h.page/weekly ad/é"), "https://h.page/weekly%20ad/%C3%A9")
        XCTAssertEqual(LenientURL.encodeInvalidCharacters("https://[::1]/a[b]"), "https://[::1]/a%5Bb%5D")
        XCTAssertEqual(LenientURL.parse(" https://h.page/%61pi \n")?.absoluteString, "https://h.page/%61pi")
        XCTAssertNil(LenientURL.parse("  "))
    }

    // MARK: Not configured

    func testSafeResultsWhenNotConfigured() async {
        Click2.unconfigureForTesting(failFast: false)
        XCTAssertFalse(Click2.isClick2Link(link))
        let resolved = await Click2.resolve(link)
        XCTAssertEqual(resolved, .notAClick2Link)
        let handled = await Click2.handle(link)
        XCTAssertEqual(handled, .notAClick2Link)
        let deferredResult = await Click2.handleDeferredLink(link)
        XCTAssertNil(deferredResult)
        let pasted = await Click2.handleDeferredLink(text: link.absoluteString)
        XCTAssertNil(pasted)
    }
}
