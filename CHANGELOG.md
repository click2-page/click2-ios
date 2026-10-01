# Changelog

All notable changes to the click2 iOS SDK. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/). While the version is 0.x, minor versions may contain breaking changes; they are called out here.

## [Unreleased]

- `Click2.reportAppleSearchAdsAttribution()`: Apple Search Ads install attribution through AdServices.

- In-app events and revenue: `Click2.track(_:revenue:currency:properties:)`, credited to the link that last opened
  the app within `Click2Config.attributionWindow` (default 7 days). `Click2Value` for property literals.
- `Click2.userId`: your user id, sent with installs and events for the team's integrations.

## [0.2.0] - 2026-09-30

First public release.

- Universal Links / App Links handling with per-platform routes (`OpenRoute`, `OpenWeb`, `Failed`, `NotAClick2Link`).
- Deferred deep links (pasteboard hand-off from the click2 fallback page, with `UIPasteControl` support).
- Install and open attribution, with a tracking switch (`isTrackingEnabled`) for consent.
- Only the configured link hosts are ever contacted.

[Unreleased]: https://github.com/click2-page/click2-ios/compare/0.2.0...HEAD
[0.2.0]: https://github.com/click2-page/click2-ios/releases/tag/0.2.0
