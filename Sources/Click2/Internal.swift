import Foundation

/// Parses URLs the way browsers accept them (spec/fixtures/link-matching.json): characters a URL can't
/// contain (space, `|`, `{}`, a bare `%`, a second `#`, non-ASCII) are percent-encoded first, so
/// `URL(string:)` doesn't return `nil` for them on iOS < 17. Valid escapes are kept as they are.
enum LenientURL {
    static func parse(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: encodeInvalidCharacters(trimmed))
    }

    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?".utf8)
    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    static func encodeInvalidCharacters(_ string: String) -> String {
        let bytes = Array(string.utf8)
        // "[" and "]" are only valid in the authority (IPv6 hosts).
        var authority = 0..<0
        if let sep = string.range(of: "://") {
            let start = string.utf8.distance(from: string.startIndex, to: sep.upperBound)
            let end = bytes[start...].firstIndex { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#") } ?? bytes.count
            authority = start..<end
        }
        func isHex(_ b: UInt8) -> Bool { hexDigits.contains(b) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(b) }

        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var inFragment = false
        for (i, b) in bytes.enumerated() {
            if b == UInt8(ascii: "%"), i + 2 < bytes.count, isHex(bytes[i + 1]), isHex(bytes[i + 2]) {
                out.append(b)
            } else if b == UInt8(ascii: "#"), !inFragment {
                inFragment = true
                out.append(b)
            } else if allowed.contains(b) || ((b == UInt8(ascii: "[") || b == UInt8(ascii: "]")) && authority.contains(i)) {
                out.append(b)
            } else {
                out += [UInt8(ascii: "%"), hexDigits[Int(b >> 4)], hexDigits[Int(b & 0x0F)]]
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Decides which URLs are click2 links (spec/fixtures/link-matching.json).
struct LinkMatcher: Sendable {
    private let hosts: Set<String>
    private static let servicePaths: Set<String> = ["api", "hooks", ".well-known", "robots.txt", "favicon.ico", "apple-app-site-association"]

    init(hosts: [String]) {
        self.hosts = Set(hosts.map { Self.normalize($0.trimmingCharacters(in: .whitespaces)) })
    }

    func matches(_ url: URL) -> Bool {
        linkHost(of: url) != nil
    }

    /// The normalized host of a click2 link, or `nil` if the URL isn't one.
    func linkHost(of url: URL) -> String? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https",
              c.percentEncodedUser == nil, c.percentEncodedPassword == nil,
              c.port == nil || c.port == 443,
              let host = c.percentEncodedHost.map(Self.normalize), hosts.contains(host)
        else { return nil }

        let path = c.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }
        let segments = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let first = String(segments[0])
        let decoded = first.removingPercentEncoding ?? first
        guard !Self.servicePaths.contains(decoded.lowercased()) else { return nil }
        // /p/<route> passthrough needs a route.
        if decoded == "p" && (segments.count < 2 || segments[1].trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty) {
            return nil
        }
        return host
    }

    private static func normalize(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }
}

/// Finds the deferred link in pasted text (spec/fixtures/pasted-text.json).
enum PastedText {
    /// The first URL in the text, if it is a click2 link.
    static func link(in text: String, matcher: LinkMatcher) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url: URL?
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            url = LenientURL.parse(trimmed)
        } else {
            url = firstURL(in: trimmed)
        }
        return url.flatMap { matcher.matches($0) ? $0 : nil }
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return LenientURL.parse(String(text[range])) ?? match.url
    }
}

/// Turns a /api/v1/resolve response into what the app should do (spec/fixtures/resolution.json).
enum ResolveMapper {
    static func map(clickedURL: URL, platform: String, status: Int, body: Data?) -> Click2Result {
        switch status {
        case 200:
            guard let link = parse(clickedURL: clickedURL, body: body) else { return .failed(reason: .serverError, url: clickedURL) }
            return action(for: link, platform: platform)
        case 404: return .failed(reason: .unknownLink, url: clickedURL)
        case 400: return .failed(reason: .invalidLink, url: clickedURL)
        default: return .failed(reason: .serverError, url: clickedURL)
        }
    }

    private static func action(for link: Click2Link, platform: String) -> Click2Result {
        let platformURL = (platform == "ios" ? link.iosUrl : link.androidUrl) ?? link.webUrl
        let platformRoute = platform == "ios" ? link.iosDeeplinkPath : link.androidDeeplinkPath
        let route = [platformRoute, link.deeplinkPath]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            .map { String($0.drop { $0 == "/" }) }
            .flatMap { $0.isEmpty ? nil : $0 }

        func web(inAppBrowser: Bool) -> Click2Result {
            guard let platformURL else { return .failed(reason: .serverError, url: link.url) }
            return .openWeb(url: platformURL, inAppBrowser: inAppBrowser, link: link)
        }
        if link.webOnly { return web(inAppBrowser: false) }
        if link.mobileWebOnly { return web(inAppBrowser: true) }
        if let route { return .openRoute(path: route, link: link) }
        return web(inAppBrowser: true)
    }

    private static func parse(clickedURL: URL, body: Data?) -> Click2Link? {
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            (json[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let webUrl = webURL(json["webUrl"])
        return Click2Link(
            url: clickedURL,
            alias: string("alias"),
            deeplinkPath: string("deeplinkPath"),
            iosDeeplinkPath: string("iosDeeplinkPath"),
            androidDeeplinkPath: string("androidDeeplinkPath"),
            webOnly: bool(json["webOnly"]),
            mobileWebOnly: bool(json["mobileWebOnly"]),
            webUrl: webUrl,
            iosUrl: webURL(json["iosUrl"]) ?? webUrl,
            androidUrl: webURL(json["androidUrl"]) ?? webUrl,
            campaign: string("campaign"),
            channel: string("channel"),
            feature: string("feature"),
            linkURL: webURL(json["link"]),
            variant: string("variant")
        )
    }

    /// Accepts `true`/`false` and `1`/`0`.
    private static func bool(_ value: Any?) -> Bool {
        switch value {
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "true" || s == "1"
        default: return false
        }
    }

    /// Only absolute http(s) URLs; anything else (e.g. `javascript:`) is dropped.
    private static func webURL(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = LenientURL.parse(string),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

/// Minimal HTTP abstraction so tests can replace the network.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Calls the click2 app API (spec/openapi.yaml).
struct Click2Client: Sendable {
    let transport: HTTPTransport
    let platform: String
    let appVersion: String?
    let sdkVersion: String
    /// Total budget per call, retries included.
    let timeout: TimeInterval
    let trackingEnabled: @Sendable () -> Bool
    let log: @Sendable (String) -> Void

    /// Connection failures after which a GET can safely be repeated.
    private static let retryableGET: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost]
    /// Failures that guarantee a POST never reached the server.
    private static let retryablePOST: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed]

    func resolve(_ clickedURL: URL, host: String) async -> Click2Result {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v1/resolve"
        var items = [("url", clickedURL.absoluteString), ("platform", platform)]
        if let appVersion { items.append(("appVersion", String(appVersion.prefix(32)))) }
        // Encoded by hand: URLQueryItem leaves "&", "=" and "+" unescaped, which would split the clicked link.
        components.percentEncodedQuery = items.map { "\($0.0)=\(Self.encode($0.1))" }.joined(separator: "&")
        guard let url = components.url else { return .failed(reason: .invalidLink, url: clickedURL) }

        guard let response = await send(url, method: "GET", body: nil, retryable: Self.retryableGET) else {
            return .failed(reason: .networkError, url: clickedURL)
        }
        return ResolveMapper.map(clickedURL: clickedURL, platform: platform, status: response.status, body: response.body)
    }

    /// Reports an install. Returns whether the server gave a final answer (2xx or 4xx); on a network
    /// error or 5xx the caller should try again later.
    func reportInstall(_ clickedURL: URL, host: String, userId: String? = nil) async -> Bool {
        guard let url = URL(string: "https://\(host)/api/v1/events") else { return false }
        var payload: [String: String] = ["type": "install", "url": clickedURL.absoluteString, "platform": platform]
        if let appVersion { payload["appVersion"] = String(appVersion.prefix(32)) }
        if let userId { payload["userId"] = userId }
        let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let response = await send(url, method: "POST", body: body, retryable: Self.retryablePOST) else { return false }
        return (200..<300).contains(response.status) || (400..<500).contains(response.status)
    }

    /// Reports an in-app event; true when click2 accepted it (2xx).
    func reportEvent(name: String, revenue: Double?, currency: String?, properties: [String: Click2Value], link: URL?, variant: String? = nil, userId: String?, host: String) async -> Bool {
        guard let url = URL(string: "https://\(host)/api/v1/events") else { return false }
        var payload: [String: Any] = ["type": "event", "name": name, "platform": platform]
        if let revenue { payload["revenue"] = revenue }
        if let currency { payload["currency"] = currency }
        if !properties.isEmpty { payload["properties"] = properties.mapValues { $0.json } }
        if let link { payload["url"] = link.absoluteString }
        if let variant { payload["variant"] = variant }
        if let userId { payload["userId"] = userId }
        if let appVersion { payload["appVersion"] = String(appVersion.prefix(32)) }
        guard JSONSerialization.isValidJSONObject(payload), let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return false }
        guard let response = await send(url, method: "POST", body: body, retryable: Self.retryablePOST) else { return false }
        if !(200..<300).contains(response.status) { log("event \(name) refused: \(response.status) \(String(data: response.body, encoding: .utf8) ?? "")") }
        return (200..<300).contains(response.status)
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// Sends within `timeout` in total, retrying once only on the given connection failures,
    /// never after a timeout or cancellation.
    /**
     * URLRequest.timeoutInterval only fires when the connection goes idle, so a slow-but-active
     * response could run past the budget. Race the request against the remaining time; the loser
     * is cancelled (URLSession cancels the transfer).
     */
    private func sendWithin(_ seconds: TimeInterval, _ request: URLRequest) async throws -> (status: Int, body: Data) {
        let transport = transport
        return try await withThrowingTaskGroup(of: (status: Int, body: Data).self) { group in
            group.addTask { try await transport.send(request) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.unknown) }
            return first
        }
    }

    private func send(_ url: URL, method: String, body: Data?, retryable: Set<URLError.Code>) async -> (status: Int, body: Data)? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        for attempt in 1...2 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, !Task.isCancelled else { return nil }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: remaining)
            req.httpMethod = method
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("click2-\(platform)/\(sdkVersion)", forHTTPHeaderField: "User-Agent")
            if !trackingEnabled() { req.setValue("1", forHTTPHeaderField: "X-Tracking-Disabled") }
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = body
            }
            do {
                return try await sendWithin(remaining, req)
            } catch {
                log("\(method) \(url.path) failed (attempt \(attempt)): \(error)")
                guard !Task.isCancelled, let code = (error as? URLError)?.code, retryable.contains(code) else { return nil }
            }
        }
        return nil
    }
}
