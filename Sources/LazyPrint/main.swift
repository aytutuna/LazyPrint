#if os(macOS)
import AppKit
import LazyPrintMac

NSApplication.shared.setActivationPolicy(.regular)
LazyPrintApp.main()
#endif
