# Affclix iOS SDK

[![CI](https://github.com/affclix/affclix-ios-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/affclix/affclix-ios-sdk/actions/workflows/ci.yml)
[![SwiftPM compatible](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](#install)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Install and in-app event attribution for iOS apps, for
[Affclix](https://affclix.com) — the affiliate and mobile attribution platform.
Same server contract as the Android SDK: installs and events
are `POST /m/ev` (JSON), with the app key (`ak`) and request signature
(`sig`) in the query string.

iOS 13+, Swift Package Manager, no third-party dependencies on Apple
platforms.

## Install

Xcode: **File → Add Package Dependencies…** and enter
`https://github.com/affclix/affclix-ios-sdk`.

Or in `Package.swift`:

```swift
.package(url: "https://github.com/affclix/affclix-ios-sdk.git", from: "0.2.0")
// target dependency: .product(name: "AffclixSDK", package: "AffclixSDK")
```

## Use

```swift
import AffclixSDK

// application(_:didFinishLaunchingWithOptions:)
Affclix.start(AffclixConfig(
    appKey: "<app key from the dashboard>",
    appSecret: "<SDK signing secret>",          // optional; enables sig=
    trackingDomain: "acme.affclix.org",          // or your custom domain
    attWaitTimeout: 60,                          // hold the install up to 60 s for the ATT answer
    enableTCFDataCollection: true,               // read your CMP's IABTCF_* values
    onDeepLink: { link in route(link.deepLinkValue) },  // link.isDeferred on first launch
    deferredDeepLinking: .automatic              // iOS deferred deep links (below)
))

// When it suits your onboarding (needs NSUserTrackingUsageDescription):
Affclix.requestTrackingAuthorization { status in }

// Events. "e" is the tracker event token: without it the MMP records the
// event but does not report it to the tracker.
Affclix.logEvent("level_complete", params: ["level": 3, "e": "level3"])
Affclix.logPurchase(revenue: 4.99, currency: "USD",
                    transactionID: transaction.id.description, eventToken: "purchase")

// Validated App Store purchase (StoreKit 2) and ad revenue
Affclix.logAppStorePurchase(transactionID: transaction.id, productID: transaction.productID,
                            revenue: 4.99, currency: "USD", eventToken: "purchase")
Affclix.logAdRevenue(network: "applovin", revenue: 0.0021, adFormat: "rewarded")

// Deep links / Universal Links
Affclix.handleDeepLink(url)                      // application(_:open:options:)
Affclix.continueUserActivity(userActivity)       // application(_:continue:restorationHandler:)

// Deferred deep links with deferredDeepLinking: .manual — pass what your
// UIPasteControl received (no paste prompt), or nil when the user skips it:
Affclix.resolveDeferredDeepLink(pastedText)

// Consent (Google consent mode / EU DMA)
Affclix.setConsentData(isUserSubjectToGDPR: true,
                       hasConsentForDataUsage: false,
                       hasConsentForAdsPersonalization: false)

// Uninstall tracking (APNs): register the token, drop the MMP's silent check
//   func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
//       Affclix.setPushToken(token, sandbox: isDebugBuild)
//   }
//   func application(_ app: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
//                    fetchCompletionHandler done: @escaping (UIBackgroundFetchResult) -> Void) {
//       if Affclix.isUninstallCheck(userInfo) { return done(.noData) }
//       …
//   }
// Needs Push Notifications + Background Modes → Remote notifications, and the
// app's APNs auth key (.p8, Key ID) in the Affclix dashboard.

// Right to erasure (GDPR / CCPA): the MMP deletes this device's data
Affclix.requestDataDeletion { result in }

// SKAdNetwork conversion values (fine 0–63; coarse / lockWindow on iOS 16.1+)
Affclix.updateConversionValue(12, coarse: .medium)
```

## What it does

| | |
|---|---|
| Install | Reported once on first launch. Marked done only when the MMP accepted it or it is in the offline queue; otherwise the next launch retries. Carries IDFV, the IDFA only with ATT authorization, `att_status`, first-open `install_time`, the Apple Search Ads token (`asa_token`) and any deep-link `click_id`. |
| Events | `event_id` (UUID) per event — the MMP stores and reports each once, so retries and replays are not counted twice. `txid` for purchases. |
| Delivery | Retries with backoff on no connection / 429 / 5xx, then an offline queue (file in Application Support, protected until first unlock, excluded from backup) resent at start and on foreground, byte for byte. A `{"success":false}` answer (bad key, signature) is not retried. |
| Signing | With `appSecret`, `sig` = hex HMAC-SHA256 of the JSON body (CryptoKit). |
| ATT | `requestTrackingAuthorization`; with `attWaitTimeout` the install waits for the answer. |
| SKAdNetwork | Registers on first launch (conversion value 0); `updateConversionValue` uses the newest API the OS has (16.1 coarse/lock, 15.4, 14.0). |
| Consent | Explicit values, else IAB TCF v2 (`ad_user_data` = purposes 1+7, `ad_personalization` = 3+4). |
| Deep links | `click_id`, `deep_link_value`, UTMs; the click ID rides on later events (re-engagement). |
| Deferred deep links | Opt in (`deferredDeepLinking`, and "iOS deferred deep linking" on the app in the dashboard). A branded link opened before the install shows a "Continue to the App Store" page; the tap copies a one-time link. On first launch the SDK resolves it (`/m/dl`) before reporting the install (up to `deferredDeepLinkTimeout`, default 10 s), so the install carries the click; `onDeepLink` gets it with `isDeferred` true and the clipboard is cleared. `.automatic` reads the clipboard only when it holds a web link (iOS shows "Allow Paste"); `.manual` takes the text from your own `UIPasteControl` instead, with no prompt. No fingerprinting. |
| Privacy manifest | `PrivacyInfo.xcprivacy`: UserDefaults (CA92.1), collected data types. `NSPrivacyTracking` is false — see the note in the file. |

## Not done yet

- **Deferred deep links without the user's tap**: the clipboard handoff
  needs the tap on the handoff page and the paste permission; there is no
  probabilistic (IP / device) matching, by design. (The Affclix MMP serves
  `apple-app-site-association` for branded links, resolves `asa_token` with
  Apple, and receives SKAdNetwork / AdAttributionKit postbacks — set
  `NSAdvertisingAttributionReportEndpoint` to your Affclix domain and add
  `applinks:{domain}` to Associated Domains.)
- `SystemPasteboard` (UIKit) is not covered by the Linux tests; test the
  paste on a device.
- AdAttributionKit-specific APIs (iOS 17.4+); SKAdNetwork calls are used.
- Purchase validation runs on the MMP (`logAppStorePurchase`); sessions are
  automatic (`session_start`).
- Built and unit-tested on Linux (Swift 5.10, platform-independent core);
  the Apple-only parts (ATT, AdSupport, AdServices, StoreKit, UIKit) need an
  Xcode build and a device test.

## Development

```bash
swift build && swift test          # macOS, or Linux:
docker run --rm -v "$PWD":/sdk -w /sdk swift:5.10-jammy swift test
```

## Integration testing

Register your test device's advertising ID (GAID / IDFA) or IDFV in the
Affclix console (app → Test Devices), then open the app on it: installs and
events appear under **Live Test Events** within seconds, with the
attribution, the decision, and findings about anything missing (app key,
signature, install referrer, event tokens, …). Test events are never
reported to the tracker or counted in reports, and a test device can
install again and again.

## Support

- Documentation: [help.affclix.com](https://help.affclix.com)
- Issues: [GitHub Issues](https://github.com/affclix/affclix-ios-sdk/issues)
- Security: see [SECURITY.md](SECURITY.md)

## License

[MIT](LICENSE)
