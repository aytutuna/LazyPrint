#if os(macOS)
import AppKit
import CUPS
import Foundation
import LazyPrintKit

/// The Mac's `PrinterSystem`: the queues macOS has set up, read with libcups. Every libcups call runs on one serial queue
/// and is awaited from the main actor; the error of a failed call is read in the same block, since libcups keeps it per
/// thread. A call with no connection passes nil (`CUPS_HTTP_DEFAULT` is a macro with a cast, which Swift does not import).
@MainActor
public final class CupsQueues: PrinterSystem {
    /// The scheduler refused a change because the user is not an administrator.
    private static let refusals: Set<Int> = [0x0401, 0x0402, 0x0403, 0x1000]

    private static let work = DispatchQueue(label: "local.lazyprint.cups")

    /// The queues read last; a scheduler that does not answer leaves them as they were, as on Windows.
    private var lastRead: [SystemPrinter] = []

    public init() {}

    public func queues() async -> [SystemPrinter] {
        if let read = await Self.run({ CupsQueues.readQueues() }) { lastRead = read }
        return lastRead
    }

    public func capabilities(ofQueue name: String) async -> PrinterCapabilities? {
        await Self.run { CupsQueues.readCapabilities(of: name) }
    }

    public func clearJobs(ofQueue name: String) async throws {
        let result = await Self.run { () -> CupsResult in
            let status = Int(cupsCancelJob2(nil, name, CUPS_JOBID_ALL, 0).rawValue)
            return CupsResult(done: status < 0x0400, status: status, message: String(cString: cupsLastErrorString()))
        }
        try finish(result)
    }

    /// Resume-Printer starts a stopped queue and CUPS-Accept-Jobs lets one that refuses jobs take them again; the
    /// queues the troubleshooter calls paused can be either.
    public func resume(queue name: String) async throws {
        let result = await Self.run { () -> CupsResult in
            let resumed = CupsQueues.admin(ipp_op_t(rawValue: 0x0011), queue: name)
            return resumed.done ? CupsQueues.admin(ipp_op_t(rawValue: 0x4008), queue: name) : resumed
        }
        try finish(result)
    }

    /// An administrator's job: when the scheduler says no, System Settings opens at the printers, where the user can.
    private func finish(_ result: CupsResult) throws {
        if result.done { return }
        let status = UInt16(truncatingIfNeeded: result.status)
        if Self.refusals.contains(result.status) {
            NSWorkspace.shared.open(SystemTroubleshooterService.printersAndScannersURL)
            throw PrintError.refused(status: status, detail: "Only an administrator can do this. Printers & Scanners is open instead.")
        }
        // The sandbox can refuse an admin request before the scheduler sees it, with no sentence of its own.
        let detail = result.message.isEmpty ? "The print system did not allow it. Printers & Scanners is open instead." : result.message
        if result.message.isEmpty { NSWorkspace.shared.open(SystemTroubleshooterService.printersAndScannersURL) }
        throw PrintError.refused(status: status, detail: detail)
    }

    private static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            work.async { continuation.resume(returning: body()) }
        }
    }

    // MARK: Pure

    /// A queue from what the scheduler lists of its destination.
    nonisolated static func systemPrinter(name: String, isDefault: Bool, options: [String: String],
                                          jobs: SystemQueueJobs) -> SystemPrinter {
        let uri = options["device-uri"]
        let state = Int(options["printer-state"] ?? "") ?? 3
        let reasons = (options["printer-state-reasons"] ?? "").split(separator: ",").map { String($0) }
        let model = options["printer-make-and-model"] ?? ""
        return SystemPrinter(
            name: name, model: model.isEmpty ? nil : model, port: uri, isDefault: isDefault,
            isVirtual: isVirtual(deviceURI: uri, printerType: Int(options["printer-type"] ?? "") ?? 0),
            states: CupsStates.describe(state: state, reasons: reasons, accepting: options["printer-is-accepting-jobs"] != "false"),
            jobs: jobs, uuid: uuid(printerUuid: options["printer-uuid"], deviceURI: uri))
    }

    /// The printer's UUID, lower case without "urn:uuid:": the queue's own when the scheduler reports it, else the one
    /// a driverless queue carries in its dnssd:// device URI.
    nonisolated static func uuid(printerUuid: String?, deviceURI: String?) -> String? {
        if let own = bare(printerUuid) { return own }
        guard let uri = deviceURI, uri.lowercased().hasPrefix("dnssd:"),
              let query = uri.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for item in query.split(separator: "&") where item.lowercased().hasPrefix("uuid=") {
            return bare(String(item.dropFirst("uuid=".count)))
        }
        return nil
    }

    private nonisolated static func bare(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trimmed.isEmpty else { return nil }
        let value = trimmed.hasPrefix("urn:uuid:") ? String(trimmed.dropFirst("urn:uuid:".count)) : trimmed
        return value.isEmpty ? nil : value
    }

    /// A queue that prints to a file or a fax, not to paper. printer-type 0x4 is CUPS_PRINTER_BW, a black-and-white
    /// printer, so only 0x40000 (CUPS_PRINTER_FAX) counts.
    nonisolated static func isVirtual(deviceURI: String?, printerType: Int) -> Bool {
        if printerType & 0x40000 != 0 { return true }
        guard let uri = deviceURI, let colon = uri.firstIndex(of: ":") else { return false }
        return ["cups-pdf", "file", "fax"].contains(uri[..<colon].lowercased())
    }

    // MARK: libcups

    private struct CupsResult: Sendable {
        var done: Bool
        var status: Int
        var message: String
    }

    /// A request to the scheduler's admin page for one queue.
    private nonisolated static func admin(_ operation: ipp_op_t, queue name: String) -> CupsResult {
        guard let request = ippNewRequest(operation) else {
            return CupsResult(done: false, status: 0, message: "The request could not be made.")
        }
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, "ipp://localhost/printers/" + name)
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, NSUserName())
        ippDelete(cupsDoRequest(nil, request, "/admin/"))
        let status = Int(cupsLastError().rawValue)
        return CupsResult(done: status < 0x0400, status: status, message: String(cString: cupsLastErrorString()))
    }

    /// No destinations and an error from the scheduler is a list that could not be read, not a list of no queues.
    nonisolated static func listFailed(count: Int, status: Int) -> Bool {
        count == 0 && status >= 0x0400
    }

    /// The queues, nil when the scheduler did not answer.
    private nonisolated static func readQueues() -> [SystemPrinter]? {
        var found: UnsafeMutablePointer<cups_dest_t>?
        let count = max(Int(cupsGetDests2(nil, &found)), 0)
        if listFailed(count: count, status: Int(cupsLastError().rawValue)) { return nil }
        guard let dests = found else { return [] }
        defer { cupsFreeDests(Int32(count), dests) }

        var defaultName: String?
        var entries: [(name: String, options: [String: String])] = []
        for i in 0..<count {
            let dest = dests[i]
            guard let name = dest.name.map({ String(cString: $0) }) else { continue }
            // An instance is a saved set of options of its queue, not a queue; the default flag goes to the queue.
            if dest.is_default != 0 { defaultName = name }
            if dest.instance != nil { continue }
            var options = [String: String]()
            for j in 0..<Int(dest.num_options) {
                let option = dest.options[j]
                options[String(cString: option.name)] = String(cString: option.value)
            }
            // No printer-state: a name in the user's options the scheduler has no queue for. A class is not a queue.
            if options["printer-state"] == nil || (Int(options["printer-type"] ?? "") ?? 0) & 0x1 != 0 { continue }
            entries.append((name: name, options: options))
        }
        return entries.map { entry in
            systemPrinter(name: entry.name, isDefault: entry.name == defaultName, options: entry.options,
                          jobs: readJobs(of: entry.name))
        }
    }

    private nonisolated static func readJobs(of queue: String) -> SystemQueueJobs {
        var found: UnsafeMutablePointer<cups_job_t>?
        let count = Int(cupsGetJobs2(nil, &found, queue, 0, CUPS_WHICHJOBS_ACTIVE))
        guard let jobs = found, count > 0 else { return .none }
        defer { cupsFreeJobs(Int32(count), jobs) }

        var inError = false
        var oldest = Int.max
        for i in 0..<count {
            let job = jobs[i]
            // IPP_JSTATE_STOPPED 6 and IPP_JSTATE_ABORTED 8.
            if job.state.rawValue == 6 || job.state.rawValue == 8 { inError = true }
            oldest = min(oldest, Int(job.creation_time))
        }
        let minutes = max(0, (Int(Date().timeIntervalSince1970) - oldest) / 60)
        return SystemQueueJobs(count: count, anyInError: inError, oldestMinutes: minutes)
    }

    private nonisolated static func readCapabilities(of name: String) -> PrinterCapabilities? {
        guard let dest = cupsGetNamedDest(nil, name, nil) else { return nil }
        defer { cupsFreeDests(1, dest) }
        guard let info = cupsCopyDestInfo(nil, dest) else { return nil }
        defer { cupsFreeDestInfo(info) }

        var caps = PrinterCapabilities()
        caps.name = name

        // Each paper with the margins the printer says, then the borderless ones.
        let flags: [UInt32] = [UInt32(CUPS_MEDIA_FLAGS_DEFAULT), UInt32(CUPS_MEDIA_FLAGS_BORDERLESS)]
        for flag in flags {
            let count = Int(cupsGetDestMediaCount(nil, dest, info, flag))
            for i in 0..<max(count, 0) {
                var size = cups_size_t()
                guard cupsGetDestMediaByIndex(nil, dest, info, Int32(i), flag, &size) != 0 else { continue }
                let margins = MediaMargins(top: Int(size.top), left: Int(size.left), bottom: Int(size.bottom), right: Int(size.right))
                caps.mediaColDatabase.append(MediaEntry(attributes: [], width: Int(size.width), height: Int(size.length),
                                                        isVariable: false, margins: margins, type: nil, source: nil))
            }
        }

        caps.sidesSupported = ["one-sided"]
        if cupsCheckDestSupported(nil, dest, info, "sides", "two-sided-long-edge") != 0 {
            caps.sidesSupported += ["two-sided-long-edge", "two-sided-short-edge"]
        }
        if let modes = cupsFindDestSupported(nil, dest, info, "print-color-mode") {
            for i in 0..<Int(ippGetCount(modes)) {
                if let mode = ippGetString(modes, Int32(i), nil) { caps.printColorModesSupported.append(String(cString: mode)) }
            }
        }
        if let copies = cupsFindDestSupported(nil, dest, info, "copies") {
            var upper: Int32 = 1
            let lower = ippGetRange(copies, 0, &upper)
            caps.copiesSupported = CopiesRange(lower: Int(lower), upper: Int(upper))
        }
        // CUPS makes and collates the copies itself, whatever the printer behind the queue can do.
        caps.multipleDocumentHandlingSupported = ["separate-documents-collated-copies"]
        if let qualities = cupsFindDestSupported(nil, dest, info, "print-quality") {
            for i in 0..<Int(ippGetCount(qualities)) {
                caps.printQualitySupported.append(Int(ippGetInteger(qualities, Int32(i))))
            }
        }
        return caps
    }
}
#endif
