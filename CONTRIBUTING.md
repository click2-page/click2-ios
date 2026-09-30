# Contributing

Thanks for helping improve the click2 iOS SDK. Bug reports, fixes and documentation improvements are welcome.

## Reporting a bug

Open an issue with the SDK version, the iOS version and device, the link (you can replace the path), what you expected and what happened. Turn on `logging` in the config and include the log lines, with anything private removed. **Security issues:** please don't open an issue; see [SECURITY.md](SECURITY.md).

## Making a change

1. For anything bigger than a small fix, open an issue first so we can agree on the approach.
2. Fork the repository and create a branch.
3. Run the tests: `swift test`.
4. Update `CHANGELOG.md` under **Unreleased** and the README if behaviour changes.
5. Open a pull request. CI must pass.

### Shared test cases

`Tests/Click2Tests/Fixtures/` contains JSON test cases that both SDKs run, so they behave the same way. If you change how links are matched or resolved, change the fixture first; a matching pull request in [click2-android](https://github.com/click2-page/click2-android) keeps the two in sync (we can do that part for you).

### Guidelines

- No new third-party dependencies: the SDK is embedded in other people's apps.
- Public API changes need a note in the changelog; breaking changes need a good reason.
- Never log or send more than the SDK already does; privacy is a feature.

By contributing you agree that your contributions are licensed under the Apache License 2.0 (see [LICENSE](LICENSE)).
