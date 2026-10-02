# Changelog

All notable changes to the click2 iOS SDK. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/). While the version is 0.x, minor versions may contain breaking changes; they are called out here.

## [Unreleased]

## [0.3.2] - 2026-10-02

### Tests

- Shared fixture `campaign-referrer.json`: a Meta ads install referrer case (used by the Android, React Native and
  Flutter SDKs).

### Docs

- README: install snippet updated; app settings are now under Apps & SDKs → App settings in the click2 dashboard.

## [0.3.1] - 2026-10-02

### Fixed

- An attributed Apple Search Ads answer also marks the install as reported, so a link pasted later doesn't report a
  second install. Reconfiguring no longer clears the in-flight install guard while a report may still be running.
- Install reports answered with HTTP 408 or 429 are retried with the next deferred link instead of being treated as
  final.
- A resolve is no longer repeated after `.networkConnectionLost` (the first request may have counted the open); only
  failures that guarantee nothing was sent are retried, like the Android SDK.
- `Click2Config.hosts` is stored normalized (trimmed, lowercased, trailing dot removed, duplicates dropped) and that
  list is used everywhere, so `track()` attribution works when hosts were configured with capitals or a trailing dot.
- Link matching decodes the whole path before splitting it, like the Android SDK: `/api%2Fx` is a service path, not a
  link (new shared fixture case; also `campaign-referrer.json`, used by the Android and React Native SDKs).

### Documentation

- `hosts[0]` must be a link host, not an email click-tracking domain: Apple Search Ads tokens and events without a
  recent link go there.

## [0.3.0] - 2026-10-01

- `Click2.reportAppleSearchAdsAttribution()`: Apple Search Ads install attribution through AdServices.
- `Click2Link.linkURL` (the click2 link behind an email click-tracking URL) and `Click2Link.variant` (the link rule or
  A/B variant), remembered for event attribution.
- In-app events and revenue: `Click2.track(_:revenue:currency:properties:)`, credited to the link that last opened
  the app within `Click2Config.attributionWindow` (default 7 days). `Click2Value` for property literals.
- `Click2.userId`: your user id, sent with installs and events for the team's integrations.

## [0.2.0] - 2026-09-30

First public release.

- Universal Links / App Links handling with per-platform routes (`OpenRoute`, `OpenWeb`, `Failed`, `NotAClick2Link`).
- Deferred deep links (pasteboard hand-off from the click2 fallback page, with `UIPasteControl` support).
- Install and open attribution, with a tracking switch (`isTrackingEnabled`) for consent.
- Only the configured link hosts are ever contacted.

[Unreleased]: https://github.com/click2-page/click2-ios/compare/0.3.2...HEAD
[0.3.2]: https://github.com/click2-page/click2-ios/releases/tag/0.3.2
[0.3.1]: https://github.com/click2-page/click2-ios/releases/tag/0.3.1
[0.3.0]: https://github.com/click2-page/click2-ios/releases/tag/0.3.0
[0.2.0]: https://github.com/click2-page/click2-ios/releases/tag/0.2.0
