// swift-tools-version: 6.0
import PackageDescription

// One shared core for the Mac and the iPhone, as in Lazy Scan:
// - LazyPrintKit: everything both apps share (page layout, the IPP protocol and PWG raster, printer
//   problems, settings files). No AppKit, UIKit or SwiftUI; its protocol and layout code needs
//   Foundation alone.
// - LazyPrintMac: the Mac's views and its system services (the queues macOS has set up, through libcups).
//   Every file is wrapped in `#if os(macOS)`, so it builds to nothing for iOS.
// - LazyPrint: the Mac app.
// iOS 18 needs PackageDescription 6.0; the code stays in the Swift 5 language mode.
let package = Package(
    name: "LazyPrint",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .executable(name: "LazyPrint", targets: ["LazyPrint"]),
        .library(name: "LazyPrintKit", targets: ["LazyPrintKit"]),
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
    ],
    swiftLanguageModes: [.v5]
)
