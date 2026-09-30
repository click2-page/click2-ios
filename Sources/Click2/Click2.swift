import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// click2 deep links for iOS.
///
/// ```swift
/// // application(_:didFinishLaunchingWithOptions:)
/// Click2.configure(Click2Config(hosts: ["acme.click2.page"], appVersion: appVersion))
///
/// // application(_:continue:restorationHandler:) or scene(_:continue:)
/// if Click2.isClick2Link(userActivity) {
///     Task { route(await Click2.handle(userActivity)) }
///     return true
/// }
///
/// // Deferred deep link, e.g. from a UIPasteControl or your "paste link" screen
/// Task { if let result = await Click2.handleDeferredLink(pastedURL) { route(result) } }
/// ```
public enum Click2 {
    public static let sdkVersion = "0.2.0"

    private static let platform = "ios"
    static let defaultsSuiteName = "page.click2.sdk"
    private static let trackingKey = "tracking_enabled"
    private static let installReportedKey = "install_reported"

    private struct Configured: Sendable {
        let matcher: LinkMatcher
        let client: Click2Client
        let logging: Bool
    }

    /// Everything mutable, behind one lock. UserDefaults is thread-safe but not Sendable.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _configured: Configured?
        private var _defaults = UserDefaults(suiteName: Click2.defaultsSuiteName) ?? .standard
        private var installInFlight = false
        private var _installTask: Task<Void, Never>?
        private var _failFast = true

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        var configured: Configured? { locked { _configured } }
        var defaults: UserDefaults { locked { _defaults } }
        var installTask: Task<Void, Never>? { locked { _installTask } }
        var failFast: Bool {
            get { locked { _failFast } }
            set { locked { _failFast = newValue } }
        }

        func configure(_ configured: Configured?, defaults: UserDefaults) {
            locked {
                _configured = configured
                _defaults = defaults
                installInFlight = false
                _installTask = nil
            }
        }

        /// Claims the install report unless it's done or already running.
        func beginInstall() -> Bool {
            locked {
                guard !installInFlight, !_defaults.bool(forKey: Click2.installReportedKey) else { return false }
                installInFlight = true
                return true
            }
        }

        func setInstallTask(_ task: Task<Void, Never>) { locked { _installTask = task } }

        func endInstall(reported: Bool) {
            locked {
                installInFlight = false
                if reported { _defaults.set(true, forKey: Click2.installReportedKey) }
            }
        }
    }

    private static let state = State()

    /// Call once at launch. Calling again replaces the configuration.
    public static func configure(_ config: Click2Config) {
        configure(config, transport: URLSessionTransport(session: .shared))
    }

    static func configure(_ config: Click2Config, transport: HTTPTransport, defaults: UserDefaults? = nil) {
        let logging = config.logging
        let client = Click2Client(
            transport: transport,
            platform: platform,
            appVersion: config.appVersion,
            sdkVersion: sdkVersion,
            timeout: config.timeout,
            trackingEnabled: { Click2.isTrackingEnabled },
            log: { message in if logging { print("[Click2] \(message)") } }
        )
        let configured = Configured(matcher: LinkMatcher(hosts: config.hosts), client: client, logging: logging)
        state.configure(configured, defaults: defaults ?? UserDefaults(suiteName: defaultsSuiteName) ?? .standard)
        log("configured for \(config.hosts)")
    }

    /// Whether opens and installs are recorded. Set it from your consent settings (e.g. where you
    /// called `Branch.setTrackingDisabled`). Remembered across launches; default `true`.
    /// When `false`, links still resolve, but nothing is recorded and no install is reported.
    public static var isTrackingEnabled: Bool {
        get { state.defaults.object(forKey: trackingKey) as? Bool ?? true }
        set { state.defaults.set(newValue, forKey: trackingKey) }
    }

    /// Marks the install as already recorded, so the SDK never reports one. Call it at launch if
    /// an earlier app version recorded installs itself (e.g. through Branch).
    public static func markInstallReported() {
        state.defaults.set(true, forKey: installReportedKey)
    }

    /// Whether the URL is a link on one of the configured hosts (and not a service URL).
    public static func isClick2Link(_ url: URL?) -> Bool {
        guard let url, let s = configured() else { return false }
        return s.matcher.matches(url)
    }

    /// Whether a Universal Link activity carries a click2 link.
    public static func isClick2Link(_ userActivity: NSUserActivity) -> Bool {
        userActivity.activityType == NSUserActivityTypeBrowsingWeb && isClick2Link(userActivity.webpageURL)
    }

    /// Resolves a click2 link. Returns `.notAClick2Link` for any other URL.
    public static func resolve(_ url: URL) async -> Click2Result {
        guard let s = configured(), let host = s.matcher.linkHost(of: url) else { return .notAClick2Link }
        return await resolve(url, host: host, client: s.client)
    }

    private static func resolve(_ url: URL, host: String, client: Click2Client) async -> Click2Result {
        let result = await client.resolve(url, host: host)
        log("resolved \(url) -> \(result)")
        return result
    }

    /// Resolves the link of a Universal Link activity (`application(_:continue:restorationHandler:)`).
    public static func handle(_ userActivity: NSUserActivity) async -> Click2Result {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else { return .notAClick2Link }
        return await resolve(url)
    }

    /// Resolves a URL opened with `application(_:open:options:)` or `scene(_:openURLContexts:)`.
    /// For a link the user pasted, use `handleDeferredLink(_:)` instead so the install is recorded.
    public static func handle(_ url: URL) async -> Click2Result {
        await resolve(url)
    }

    /// Deferred deep link: a click2 link the user brought into a freshly installed app, typically
    /// by pasting it (the click2 fallback page copies the link before sending people to the App Store).
    /// Also records the install, once, in the background (not when tracking is off); if that fails
    /// it is retried on the next call. Returns `nil` if the URL isn't a click2 link.
    public static func handleDeferredLink(_ url: URL) async -> Click2Result? {
        guard let s = configured(), let host = s.matcher.linkHost(of: url) else { return nil }
        reportInstallIfNeeded(url, host: host, client: s.client)
        return await resolve(url, host: host, client: s.client)
    }

    /// Like `handleDeferredLink(_:)` for pasted text: uses the first URL in the text, which must be
    /// a click2 link. Returns `nil` otherwise.
    public static func handleDeferredLink(text: String) async -> Click2Result? {
        guard let s = configured(), let url = PastedText.link(in: text, matcher: s.matcher) else { return nil }
        return await handleDeferredLink(url)
    }

    private static func reportInstallIfNeeded(_ url: URL, host: String, client: Click2Client) {
        guard isTrackingEnabled else { return log("tracking is off: install not reported") }
        guard state.beginInstall() else { return }
        // Not awaited: routing mustn't wait for attribution.
        state.setInstallTask(Task {
            let reported = await client.reportInstall(url, host: host)
            state.endInstall(reported: reported)
            log(reported ? "install reported for \(url)" : "install report failed; will retry on the next deferred link")
        })
    }

    #if canImport(UIKit)
    /// Whether the pasteboard holds a URL. Doesn't read it, so iOS shows no paste prompt; use it to
    /// decide whether to offer your "continue where you left off" / paste screen.
    @MainActor
    public static var pasteboardHasURL: Bool {
        UIPasteboard.general.hasURLs
    }

    /// Reads a click2 link from the pasteboard (a URL, or else the first URL in its text) and handles
    /// it as a deferred deep link. On iOS 16+ this shows the system "Allow Paste" prompt, so call it
    /// after the user chose to paste (or use a `UIPasteControl` and pass its URL to
    /// `handleDeferredLink(_:)` instead, which never prompts).
    @MainActor
    public static func handleDeferredLinkFromPasteboard() async -> Click2Result? {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasURLs, let url = pasteboard.url {
            return await handleDeferredLink(url)
        }
        if pasteboard.hasStrings, let text = pasteboard.string {
            return await handleDeferredLink(text: text)
        }
        return nil
    }
    #endif

    /// The configuration, or `nil` (with a log line, and an assertion in debug builds) before `configure(_:)`.
    private static func configured(_ caller: String = #function) -> Configured? {
        if let configured = state.configured { return configured }
        print("[Click2] \(caller) called before Click2.configure(_:); ignoring it")
        if state.failFast { assertionFailure("Call Click2.configure(_:) first, e.g. in application(_:didFinishLaunchingWithOptions:)") }
        return nil
    }

    private static func log(_ message: String) {
        if state.configured?.logging == true { print("[Click2] \(message)") }
    }

    // MARK: Test hooks

    /// Forgets the configuration; `failFast: false` lets tests exercise the release behaviour.
    static func unconfigureForTesting(failFast: Bool) {
        state.configure(nil, defaults: state.defaults)
        state.failFast = failFast
    }

    /// The last background install report, so tests can wait for it.
    static var installTaskForTesting: Task<Void, Never>? { state.installTask }
}
