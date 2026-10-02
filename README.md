# click2 iOS SDK

[![CI](https://github.com/click2-page/click2-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/click2-page/click2-ios/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
![iOS 14+](https://img.shields.io/badge/iOS-14%2B-lightgrey.svg)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)

Open [click2](https://click2.page) links in your iOS app: Universal Links, deferred deep links after install, and install/open attribution. A small Swift package with no dependencies.

The Android SDK is at [click2-page/click2-android](https://github.com/click2-page/click2-android).

## Install

**Swift Package Manager.** In Xcode: File → Add Package Dependencies → `https://github.com/click2-page/click2-ios`, then link the product **Click2**. Or in `Package.swift`:

```swift
.package(url: "https://github.com/click2-page/click2-ios", from: "0.2.0")
```

Requirements: iOS 14+, Xcode 15+ (Swift 5.9). Swift 6 language mode is supported.

## Set up

**1. Associated Domains.** Add a separate entry for each configuration:

```
applinks:$(CLICK2_HOST)        // acme.click2.page (App Store), acme-test.click2.page (staging)
```

In the click2 dashboard (Team settings → iOS app), add `TEAMID.bundle.id`. Use the live team for the App Store bundle and the test environment for staging bundles.

To see changes immediately during development, use `applinks:$(CLICK2_HOST)?mode=developer` in debug builds and turn on Settings → Developer → Associated Domains Development.

**2. Configure** at launch:

```swift
import Click2

let info = Bundle.main.infoDictionary ?? [:]
if let host = info["CLICK2_HOST"] as? String {
    Click2.configure(Click2Config(hosts: [host], appVersion: info["CFBundleShortVersionString"] as? String))
} else {
    assertionFailure("CLICK2_HOST missing from Info.plist")
}
Click2.isTrackingEnabled = consent.targetingAllowed     // keep in sync with your consent settings
```

Hosts are bare host names (`acme.click2.page`); a scheme, port, path or `user@` is a programmer error and traps. Calling the SDK before `configure` asserts in debug builds; in release it logs and treats every URL as not a click2 link.

**3. Handle Universal Links:**

```swift
func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                 restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    guard Click2.isClick2Link(userActivity) else { return false }   // not ours: handle as before
    Task { @MainActor in route(await Click2.handle(userActivity)) }
    return true
}

@MainActor func route(_ result: Click2Result) {
    switch result {
    case .openRoute(let path, _): coordinator.openDeeplink(path: path)
    case .openWeb(let url, let inAppBrowser, _): inAppBrowser ? showSafariView(url) : UIApplication.shared.open(url)
    case .failed, .notAClick2Link: break
    }
}
```

With scenes, do the same in `scene(_:continue:)` and in `scene(_:willConnectTo:options:)` using `connectionOptions.userActivities`.

**4. Deferred deep links.** The click2 fallback page copies the link before opening the App Store. On first launch, offer to continue:

```swift
// No prompt: only checks whether the pasteboard has a URL.
if isFirstLaunch && Click2.pasteboardHasURL { showContinueScreen() }

// Option A: a UIPasteControl on that screen (iOS 16+, no system prompt).
//   Pass the pasted URL on:
if let result = await Click2.handleDeferredLink(pastedURL) { route(result) }

// Option B: after the user taps your own "Paste" button (shows iOS's "Allow Paste" prompt):
if let result = await Click2.handleDeferredLinkFromPasteboard() { route(result) }

// Pasted text (e.g. a text field): the first URL in it is used.
if let result = await Click2.handleDeferredLink(text: pastedText) { route(result) }
```

Use `handleDeferredLink`, not `handle(_:)`, for pasted links: only it records the install. The install is reported once, in the background (routing doesn't wait for it). It isn't sent while `isTrackingEnabled` is `false`, and if it fails (offline, server error) the next deferred link tries again. If an earlier app version recorded installs itself, call `Click2.markInstallReported()` at launch so upgraded users aren't counted as new installs.

## In-app events and revenue

Record what users do after a link brought them in; the click2 dashboard shows each campaign's events and revenue.

```swift
Click2.userId = account.id            // optional; sent to the team's integrations (e.g. Braze). nil after sign-out.
await Click2.track("purchase", revenue: 24.99, currency: "USD", properties: ["sku": "A1", "quantity": 2])
await Click2.track("sign_up")
```

An event is credited to the click2 link that last opened the app within `attributionWindow` (default 7 days, in
`Click2Config`). Names are up to 64 letters, digits, spaces or `_ . : -`; up to 10 properties (text, numbers,
true/false). Nothing is sent while `isTrackingEnabled` is `false`. `track` returns whether click2 accepted the event.

## Apple Search Ads

```swift
Click2.reportAppleSearchAdsAttribution()   // once at launch, after configure
```

On the first launch after an install, sends the AdServices attribution token; click2 asks Apple which campaign led to
the install and shows it in analytics (channel `apple_search_ads`, campaign `asa-<campaign id>`). No ATT prompt
(AdServices doesn't use the IDFA). Nothing is sent while tracking is off. The token goes to the first configured host,
so `hosts[0]` must be a link host (`acme.click2.page`), not an email click-tracking domain. An attributed install
counts as the device's install: a link pasted later doesn't report another one.

## Notes

- Swift 6 ready: builds with strict concurrency checking and no warnings. The API is `async`.
- Uses `URLSession.shared`. `timeout` (default 10 s) is the total budget per call. A request is retried once only when the connection couldn't be made (no timeouts, lost connections, cancellation, or anything that may have reached the server), so an open is never counted twice. An install report answered with 5xx, 408 or 429 (or not answered) is sent again with the next deferred link.
- `Click2Link.webUrl`, `iosUrl` and `androidUrl` are optional (0.x API change): they are `nil` when the server sent no http(s) URL. A link with an in-app route still routes; a link that needs a web URL but has none fails with `.serverError`.
- Only the configured hosts are ever called. They are stored normalized (trimmed, lowercased, no trailing dot).
- `swift test` runs the tests, including the shared fixtures, on macOS; `xcodebuild test -scheme Click2 -destination 'platform=iOS Simulator,…'` runs them on iOS.
- **Existing installs.** If an earlier version of your app handled deferred links itself, call `Click2.markInstallReported()` at launch for users who already went through it, so they aren't reported as new installs.

## Concepts

- **Hosts:** the app configures its team's link hosts. Production builds use your team's host, e.g. `acme.click2.page`; staging and debug builds use its test environment, e.g. `acme-test.click2.page`. The SDK ignores other URLs and only ever calls these hosts.
- **Result:** every link resolves to one of:
  - `OpenRoute(path)`: an in-app route for this platform, e.g. `product/123?src=email`.
  - `OpenWeb(url, inAppBrowser)`: `inAppBrowser = false` for "web only" links (open in the external browser), `true` for "mobile web only" links and links without an app route.
  - `Failed(reason)`: `unknown_link`, `invalid_link`, `server_error` or `network_error`. The app usually just stays where it is.
  - `NotAClick2Link`: handle the URL as before.
- **Deferred deep links:**
  - **Android:** exact, via the Play Install Referrer. The fallback page sends the link through the Play Store.
  - **iOS:** the fallback page copies the link to the clipboard before opening the App Store, and the app hands the pasted URL to the SDK (`UIPasteControl` avoids the paste prompt). There's no fingerprinting.
- **Tracking consent:** set `isTrackingEnabled = false` and links still work but nothing is recorded (the SDK sends the `X-Tracking-Disabled: 1` header).

## From Branch

| Branch | click2 |
|---|---|
| `Branch.getAutoInstance` / `initSession` | `Click2.configure(...)` |
| `$android_deeplink_path` / `$ios_deeplink_path` / `$deeplink_path` | `OpenRoute.path` (platform route already chosen) |
| `$web_only` + `$android_url` / `$ios_url` | `OpenWeb(url, inAppBrowser = false)` |
| `$mobile_web_only` | `OpenWeb(url, inAppBrowser = true)` |
| `~campaign`, `~channel`, `~feature` | `link.campaign`, `link.channel`, `link.feature` |
| `~referring_link` query merged into the path | already merged by the server |
| `disableTracking` / `setTrackingDisabled` | `isTrackingEnabled = false` |
| `BranchEvent(.purchase)…logEvent()` / `userCompletedAction` | `Click2.track("purchase", revenue:currency:properties:)` |
| `setIdentity` / `logout` | `Click2.userId = id` / `nil` |
| test key / `*.test-app.link` | test environment host `<team>-test.click2.page` |

## Development

```bash
swift test                                                   # macOS
xcodebuild test -scheme Click2 -destination 'platform=iOS Simulator,name=iPhone 17'
```

`Tests/Click2Tests/Fixtures/` holds test cases shared with the Android SDK (link matching, resolution, pasted text). Keep them identical in both repositories; change a fixture first, then the code. See [CONTRIBUTING.md](CONTRIBUTING.md).

The HTTP API the SDK talks to is described in [`spec/openapi.yaml`](spec/openapi.yaml).

## License

Apache License 2.0, see [LICENSE](LICENSE).
