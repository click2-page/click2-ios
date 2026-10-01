import Foundation

/// SDK configuration.
public struct Click2Config: Sendable {
    /// The team's link hosts this app handles, e.g. `["acme.click2.page"]` for the App Store build
    /// and `["acme-test.click2.page"]` for staging. Only links on these hosts are handled, and
    /// only these hosts are ever called.
    public var hosts: [String]
    /// Reported with opens and installs, e.g. `CFBundleShortVersionString`.
    public var appVersion: String?
    /// Total time budget per call, retries included. A request is retried once only when the
    /// connection couldn't be made.
    public var timeout: TimeInterval
    /// Prints debug logs (for debug builds).
    public var logging: Bool
    /// How long the last click2 link that opened the app gets credit for `Click2.track` events.
    public var attributionWindow: TimeInterval

    public init(hosts: [String], appVersion: String? = nil, timeout: TimeInterval = 10, logging: Bool = false, attributionWindow: TimeInterval = 7 * 86_400) {
        precondition(!hosts.isEmpty, "Click2Config needs at least one link host")
        for host in hosts {
            precondition(
                Self.isHostName(host.trimmingCharacters(in: .whitespaces)),
                "Click2Config hosts are bare host names like acme.click2.page (no scheme, port, path or user), got \"\(host)\""
            )
        }
        self.hosts = hosts
        self.appVersion = appVersion
        self.timeout = timeout
        self.logging = logging
        self.attributionWindow = attributionWindow
    }

    private static func isHostName(_ host: String) -> Bool {
        !host.isEmpty && host.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") }
    }
}

/// What the app should do with a click2 link.
public enum Click2Result: Sendable, Equatable {
    /// Open this in-app route (no leading slash; query parameters included), e.g. `product/123?src=email`.
    case openRoute(path: String, link: Click2Link)
    /// Open a web page. `inAppBrowser == false` means Safari (the link is "web only");
    /// `true` means show it inside the app (e.g. `SFSafariViewController`).
    case openWeb(url: URL, inAppBrowser: Bool, link: Click2Link)
    /// The link could not be resolved. Usually: stay where you are (or show the home screen).
    case failed(reason: Click2FailureReason, url: URL)
    /// Not a link on the configured hosts; handle it as before.
    case notAClick2Link
}

public enum Click2FailureReason: String, Sendable, Equatable {
    /// The link doesn't exist or expired.
    case unknownLink = "unknown_link"
    /// The server says the link doesn't belong to this app's team.
    case invalidLink = "invalid_link"
    /// The server answered with an error or an unexpected response.
    case serverError = "server_error"
    /// No connection or a timeout.
    case networkError = "network_error"
}

/// A property value for `Click2.track`: text, a number or true/false. Literals work directly:
/// `["sku": "A1", "quantity": 2, "gift": true]`.
public enum Click2Value: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    var json: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        }
    }
}

/// The resolved link, for analytics (campaign, channel, feature) or custom handling.
public struct Click2Link: Sendable, Equatable {
    /// The link that was clicked.
    public let url: URL
    public let alias: String?
    public let deeplinkPath: String?
    public let iosDeeplinkPath: String?
    public let androidDeeplinkPath: String?
    public let webOnly: Bool
    public let mobileWebOnly: Bool
    /// The link's web destination; `nil` if the server sent none or it wasn't an http(s) URL.
    public let webUrl: URL?
    /// iOS web destination, `webUrl` if not set.
    public let iosUrl: URL?
    /// Android web destination, `webUrl` if not set.
    public let androidUrl: URL?
    public let campaign: String?
    public let channel: String?
    public let feature: String?
    /// The click2 link itself, when it differs from `url` (e.g. `url` is an email click-tracking URL).
    public var linkURL: URL? = nil
}
