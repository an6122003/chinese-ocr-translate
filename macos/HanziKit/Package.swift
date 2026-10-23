// swift-tools-version: 6.2
// HanziKit — the platform-agnostic core shared by the macOS app (and a future iPad app):
// pinyin, Hán Việt, dictionary lookup, segmentation, OCR, translation and speech.
import PackageDescription

let package = Package(
    name: "HanziKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "HanziKit", targets: ["HanziKit"]),
    ],
    targets: [
        .target(
            name: "HanziKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "HanziKitTests",
            dependencies: ["HanziKit"]
        ),
    ]
)
