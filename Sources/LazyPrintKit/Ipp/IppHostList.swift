import Foundation

// Twin of windows/LazyPrint.Core/Ipp/IppHostList.cs: the same file (ipp-hosts.json, a JSON list of
// address strings) and rules; each platform keeps its own in its own settings folder.

/// The network printers added by address: ipp-hosts.json in the settings folder, a JSON list of
/// address strings (["192.168.1.50", "printer.local:8631", "ipps://10.0.0.7"]). The "Add printer by
/// address" dialog writes it, and entries written by hand keep working. Entries that do not parse as
/// an address are kept but not used. The file follows the settings-file rules (CONTRACTS.md, Global
/// rule 5): a file that does not decode is kept aside as ipp-hosts.unreadable-<timestamp>.json, one
/// that cannot be read is never overwritten.
public final class IppHostList {
    public static let fileName = "ipp-hosts.json"

    public let fileURL: URL

    public convenience init() {
        self.init(directory: StoreFiles.defaultDirectory)
    }

    /// Keeps ipp-hosts.json in `directory` (tests).
    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(IppHostList.fileName)
    }

    /// The entries as written, in order; empty when there is no file or it could not be loaded.
    public func loadEntries() -> [String] {
        StoreFiles.load([String].self, from: fileURL) ?? []
    }

    /// The usable addresses, in order, without duplicates.
    public func load() -> [PrinterAddress] {
        var addresses: [PrinterAddress] = []
        for entry in loadEntries() {
            var error = ""
            if let address = PrinterAddress.tryParse(entry, error: &error), !addresses.contains(address) {
                addresses.append(address)
            }
        }
        return addresses
    }

    /// Adds `address` in its canonical form; false when it is already listed.
    @discardableResult
    public func add(_ address: PrinterAddress) -> Bool {
        var entries = loadEntries()
        if entries.contains(where: { IppHostList.matches($0, address) }) {
            return false
        }
        entries.append(address.description)
        StoreFiles.write(entries, to: fileURL)
        return true
    }

    /// Removes every entry meaning `address`; false when none did.
    @discardableResult
    public func remove(_ address: PrinterAddress) -> Bool {
        let entries = loadEntries()
        let kept = entries.filter { !IppHostList.matches($0, address) }
        if kept.count == entries.count {
            return false
        }
        StoreFiles.write(kept, to: fileURL)
        return true
    }

    private static func matches(_ entry: String, _ address: PrinterAddress) -> Bool {
        var error = ""
        return PrinterAddress.tryParse(entry, error: &error) == address
    }
}
