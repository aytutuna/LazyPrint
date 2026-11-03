import Foundation

// Twin of windows/LazyPrint.Core/Ipp/IppSpool.cs: the same file rules on both platforms. The C# spool is
// disposed to delete its file; here `delete()` does it, and nothing is deleted behind the caller's back.

enum IppSpoolError: Error, Equatable, Sendable {
    /// `write` after `complete`.
    case completed
}

/// A job's document on disk while it is drawn and sent. Sheets are written one at a time, so a job never holds
/// more than one in memory, and the file is sent again as it is for every retry. `delete` removes the file,
/// whether the job was sent or abandoned.
public final class IppSpool {
    public let url: URL
    private var output: FileHandle?

    /// Creates an empty spool file in `directory`, the system's temporary folder by default.
    public init(directory: URL? = nil) throws {
        let folder = directory ?? FileManager.default.temporaryDirectory
        IppSpool.deleteStale(in: folder)
        let name = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        url = folder.appendingPathComponent("lp-" + name + ".spool")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        output = try FileHandle(forWritingTo: url)
    }

    /// Appends what `body` puts in the buffer it is given: the file header, or one sheet.
    public func write(_ body: (inout Data) throws -> Void) throws {
        guard let output else { throw IppSpoolError.completed }
        var chunk = Data()
        try body(&chunk)
        try output.write(contentsOf: chunk)
    }

    /// Closes the file for writing and returns its URL, ready to be sent.
    public func complete() throws -> URL {
        try output?.close()
        output = nil
        return url
    }

    // What a run that was killed left behind: spool files and the body files the client makes beside them.
    private static func deleteStale(in folder: URL) {
        let cutoff = Date().addingTimeInterval(-86400)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("lp-body-") || (name.hasPrefix("lp-") && name.hasSuffix(".spool")) else { continue }
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    public func delete() {
        try? output?.close()
        output = nil
        try? FileManager.default.removeItem(at: url)
    }
}
