import Foundation
@testable import LazyPrintKit

// The files the phone link tests send, as in windows/LazyPrint.Core.Tests/CompanionFixtures.cs: a package of a small
// PDF (or of the bytes given).
enum CompanionFixtures {
    static let pdf = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8)

    static func package(batch: String = "batch-0001", index: Int = 0, count: Int = 1, name: String = "Report.pdf",
                        from: String = "Aytu's iPhone") throws -> Data {
        try PrintPackage.make(name: name, contentType: "application/pdf", batch: batch, index: index, count: count, from: from,
                              bytes: pdf)
    }

    /// A package with the header as written, which `PrintPackage.make` would refuse.
    static func raw(_ headerJson: String, _ bytes: Data? = nil) -> Data {
        let header = Data(headerJson.utf8)
        let length = UInt32(header.count)
        var package = Data("LPPKG01".utf8) + [0]
        package.append(contentsOf: [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF),
                                    UInt8((length >> 24) & 0xFF)])
        return package + header + (bytes ?? pdf)
    }
}
