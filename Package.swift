// swift-tools-version: 6.0
import PackageDescription

// MailCore is the engine: protocols, parsing, accounts. It uses Foundation and
// Security only, so it runs unchanged on macOS, iPadOS and iOS.
// MailUI is the shared SwiftUI layer. App targets in Apps/ stay thin.
// The block composer (Settings → Experimental) uses Relevate's native editor (editor-next), a
// sibling in the Relevate repository, the same way Daybook's notes do.
let package = Package(
    name: "Margin",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MailCore", targets: ["MailCore"]),
        .library(name: "MailUI", targets: ["MailUI"]),
    ],
    dependencies: [
        // Relevate's native block editor (Rust core, SwiftUI/AppKit/UIKit surfaces).
        .package(path: "../goud-monorepo/packages/editor-next/apple"),
    ],
    targets: [
        .target(name: "MailCore"),
        .target(name: "MailUI", dependencies: ["MailCore", .product(name: "NativeEditor", package: "apple")]),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore"]),
        .testTarget(name: "MailUITests", dependencies: ["MailUI", "MailCore"]),
    ]
)
