// swift-tools-version: 6.0
import PackageDescription

// MailCore is the engine: protocols, parsing, accounts. It uses Foundation and
// Security only, so it runs unchanged on macOS, iPadOS and iOS.
// MailUI is the shared SwiftUI layer. App targets in Apps/ stay thin.
let package = Package(
    name: "Margin",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MailCore", targets: ["MailCore"]),
        .library(name: "MailUI", targets: ["MailUI"]),
    ],
    targets: [
        .target(name: "MailCore"),
        .target(name: "MailUI", dependencies: ["MailCore"]),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore"]),
        .testTarget(name: "MailUITests", dependencies: ["MailUI", "MailCore"]),
    ]
)
