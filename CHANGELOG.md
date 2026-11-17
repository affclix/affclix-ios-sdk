# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-11-21

First release.

- Install attribution with IDFV, IDFA (with ATT authorization), `att_status`, Apple Search Ads token
- Install attribution result: `AffclixConfig.onAttribution` and `Affclix.attribution` give how the MMP matched the install (`click_id`, `device_id`, `probabilistic`, `view_through`, `ad_network`, `organic`, …) and the click
- Deep links, Universal Links, and opt-in deferred deep links through a clipboard handoff; web + app journeys (`af_web_id` → `DeepLinkResult.webVisitorID`)
- In-app events, validated App Store purchases (StoreKit 2)
- Impression-level ad revenue: `logAdRevenue(AdRevenue(...))` with mediation platform, network, ad unit, format, placement and precision (AppLovin MAX, LevelPlay, AdMob)
- Short links (`/l/{code}`) resolved through the MMP, matched deferred deep links, and custom-scheme links from in-app browsers
- Apple App Attest (opt in, `appAttest: true`): the install carries an attestation of a Secure Enclave key over an MMP challenge, waiting at most `integrityTimeout`
- Durable delivery: the install and events are saved before the first send and removed once the MMP answers; resent on launch, return to the foreground and reconnect
- SKAdNetwork: registration on first launch and automatic conversion values (fine, coarse, lock window on iOS 16.1+) from the schema set in the dashboard
- Backup-restore detection: a restore onto another iPhone is reported as an install
- Request signing (HMAC-SHA256)
- Consent: GDPR / CCPA data deletion, Google consent mode, IAB TCF v2
- Uninstall tracking through APNs
- Device signals for validation rules: `is_rooted` (jailbreak) and `is_emulator` (Simulator)
- `trackingDomain` defaults to `mmp.affclix.org`; leave it
- Privacy manifest (`PrivacyInfo.xcprivacy`)

[1.1.0]: https://github.com/affclix/affclix-ios-sdk/releases/tag/1.1.0
