# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [0.2.1] - 2026-11-01

### Fixed

- Events and the install are saved before the first send and removed once the server answers, so closing the app during the retries no longer loses them
- Saved events are also sent when the connection returns, not only on launch or return to the foreground
- A data deletion now drops events still waiting to be sent, so they cannot bring back erased data
- The first session waits for the deferred deep link and carries its click
- An existing install is never asked to paste for a deferred deep link
- The ATT request waits for the app to be active, because iOS shows no prompt otherwise

## [0.2.0] - 2026-10-27

First public release.

- Install attribution with IDFV, IDFA (with ATT authorization), Apple Search Ads token
- Deep links, Universal Links, and opt-in deferred deep links through a clipboard handoff
- In-app events, validated App Store purchases (StoreKit 2), ad revenue
- Retry with back-off and an offline queue
- Request signing (HMAC-SHA256)
- SKAdNetwork conversion values, including coarse values and lock window (iOS 16.1+), from the dashboard schema
- Consent: GDPR / CCPA data deletion, Google consent mode, IAB TCF v2
- Uninstall tracking through APNs
- Privacy manifest (`PrivacyInfo.xcprivacy`)

[0.2.1]: https://github.com/affclix/affclix-ios-sdk/releases/tag/0.2.1
[0.2.0]: https://github.com/affclix/affclix-ios-sdk/releases/tag/0.2.0
