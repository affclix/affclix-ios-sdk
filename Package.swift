// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AffclixSDK",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "AffclixSDK", targets: ["AffclixSDK"]),
    ],
    dependencies: [
        // CryptoKit's API for Linux, where the SDK's core is unit-tested. Apple
        // builds use CryptoKit and never link it.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        .target(
            name: "AffclixSDK",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "AffclixSDKTests", dependencies: ["AffclixSDK"]),
    ]
)
