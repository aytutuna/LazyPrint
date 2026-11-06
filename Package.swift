// swift-tools-version: 6.0
import PackageDescription

// One shared core for the Mac and the iPhone, as in Lazy Scan:
// - LazyPrintKit: everything both apps share (page layout, the IPP protocol and PWG raster, printer
//   problems, settings files). No AppKit, UIKit or SwiftUI; its protocol and layout code needs
//   Foundation alone.
// - LazyPrintMac: the Mac's views and its system services (the queues macOS has set up, through libcups).
//   Every file is wrapped in `#if os(macOS)`, so it builds to nothing for iOS.
// - LazyPrintIOS: the iPhone's views and its services (AirPrint, the file inbox, UIKit's lifecycle and background time).
//   Every file is wrapped in `#if os(iOS)`, so it builds to nothing for macOS.
// - LazyPrint: the Mac app for `swift build` and scripts/make_app.sh; the Mac App Store build is mac/project.yml, which
//   starts LazyPrintMac's `LazyPrintApp` from the library product, as the iPhone's project starts LazyPrintIOS.
// iOS 18 needs PackageDescription 6.0; the code stays in the Swift 5 language mode.
let package = Package(
    name: "LazyPrint",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .executable(name: "LazyPrint", targets: ["LazyPrint"]),
        .library(name: "LazyPrintKit", targets: ["LazyPrintKit"]),
        .library(name: "LazyPrintMac", targets: ["LazyPrintMac"]),
        .library(name: "LazyPrintIOS", targets: ["LazyPrintIOS"]),
    ],
    targets: [
        .target(
            name: "LazyPrintKit",
            path: "Sources/LazyPrintKit"
        ),
        .target(
            name: "LazyPrintMac",
            dependencies: ["LazyPrintKit"],
            path: "Sources/LazyPrintMac",
            linkerSettings: [.linkedLibrary("cups", .when(platforms: [.macOS]))]
        ),
        .target(
            name: "LazyPrintIOS",
            dependencies: ["LazyPrintKit"],
            path: "Sources/LazyPrintIOS"
        ),
        .executableTarget(
            name: "LazyPrint",
            dependencies: [
                .target(name: "LazyPrintMac", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/LazyPrint"
        ),
        .testTarget(
            name: "LazyPrintTests",
            dependencies: ["LazyPrintKit"],
            // Reads Tests/Fixtures by #filePath, the folder the Windows tests read too.
            path: "Tests/LazyPrintTests"
        ),
        .testTarget(
            name: "LazyPrintMacTests",
            dependencies: ["LazyPrintKit", "LazyPrintMac"],
            // Reads Tests/Fixtures/Documents by #filePath, as the shared tests do.
            path: "Tests/LazyPrintMacTests"
        ),
        .testTarget(
            name: "LazyPrintIOSTests",
            dependencies: ["LazyPrintKit", "LazyPrintIOS"],
            path: "Tests/LazyPrintIOSTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
