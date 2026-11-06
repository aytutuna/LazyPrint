import AppKit
import LazyPrintMac

// The Mac app of the App Store build. Everything it does is in the package (Sources/LazyPrintMac and the shared
// LazyPrintKit); this target only starts it, as Sources/LazyPrint does for `swift build`.
NSApplication.shared.setActivationPolicy(.regular)
LazyPrintApp.main()
