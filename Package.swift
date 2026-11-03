// swift-tools-version: 6.0
import PackageDescription

// One shared core for the Mac and the iPhone, as in Lazy Scan:
// - LazyPrintKit: everything both apps share (page layout, the IPP protocol and PWG raster, printer
//   problems, settings files). No AppKit, UIKit or SwiftUI; its protocol and layout code needs
//   Foundation alone.
// iOS 18 needs PackageDescription 6.0; the code stays in the Swift 5 language mode.
let package = Package(
    name: "LazyPrint",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "LazyPrintKit", targets: ["LazyPrintKit"]),
    ],
    targets: [
        .target(
            name: "LazyPrintKit",
            path: "Sources/LazyPrintKit"
        ),
        .testTarget(
            name: "LazyPrintTests",
            dependencies: ["LazyPrintKit"],
            // Reads Tests/Fixtures by #filePath, the folder the Windows tests read too.
            path: "Tests/LazyPrintTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
