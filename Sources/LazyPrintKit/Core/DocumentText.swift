import Foundation

// Twin of windows/LazyPrint.Core/Core/DocumentText.cs: why a file can't be printed.

public enum DocumentText {
    public static let lockedPdf = "This PDF is locked. Open it in a PDF app and print it from there."

    public static let notSupported = "Lazy Print prints PDFs and pictures. Save it as a PDF first."

    public static let unreadable = "Lazy Print can't read this file."

    public static let noPages = "This PDF has no pages."
}
