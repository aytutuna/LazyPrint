#if os(macOS)
import CUPS
import Foundation
import LazyPrintKit

/// The Mac's `SheetPrinter` for the queues macOS has set up: one pass written as a PDF of sheets and sent with
/// cupsPrintFile2 under the options of `CupsOptions`, then followed until the scheduler says the job is done. Unlike the
/// Windows spooler printer it returns when the job has printed, so the two-sided card does not ask for the stack before
/// the fronts are out. Sending has a queue of its own, so a long job does not hold up the listing of the queues.
public final class CupsPrinter: SheetPrinter {
    /// Answers missed in a row before a job that was sent is given up on.
    private static let missedAnswers = 3
    /// IPP's client-error-not-found.
    private static let notFound = 0x0406

    private static let sending = DispatchQueue(label: "local.lazyprint.cups.send")

    private let poll: TimeInterval

    public init(pollInterval: TimeInterval = 2) {
        self.poll = pollInterval
    }

    public func print(_ job: SheetJob, pass: Int, progress: @Sendable (JobStatus) -> Void) async throws {
        let queue = String(job.printer.id.dropFirst("system:".count))
        let area = job.plan.plan.area
        try Task.checkCancellation()

        let prepared = await Self.prepare(queue: queue, paper: area.paper, borderless: area.margins == LayoutInsets(top: 0, left: 0, bottom: 0, right: 0))
        let problems = SystemQueueProblems.describe(prepared.states)
        if prepared.stopped, let problem = problems.first(where: { $0.isError }) ?? problems.first {
            throw PrinterProblemError(problem: problem)
        }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lp-" + UUID().uuidString.lowercased() + ".pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let sides = JobSides.of(job, pass: pass)
        progress(JobStatus(state: .preparing, sidesDone: 0))
        try SheetRenderer(documents: job.documents).writePDF(sides, area: area, to: file)
        try Task.checkCancellation()

        let options = CupsOptions.forJob(sides: job.plan.plan.duplex ? .longEdge : .oneSided, copies: job.plan.copiesInJob,
                                         collate: job.settings.collate, color: job.settings.color,
                                         quality: job.settings.quality, media: prepared.media, duplexPass: job.plan.manualDuplex)
        progress(JobStatus(state: .sending, sidesDone: 0))
        let sent = await Self.submit(file, queue: queue, title: job.name, options: options)
        guard sent.id > 0 else { throw PrintError.refused(status: UInt16(truncatingIfNeeded: sent.status), detail: sent.message) }
        try await follow(queue, printer: job.printer.name, id: sent.id, sides: sides.count * job.plan.copiesInJob, progress)
    }

    /// Asks the scheduler about the job until it is done with it. A scheduler that misses an answer or two is asked again;
    /// cancelling cancels the job. A job the scheduler no longer knows may have printed or not, so it ends as sent, the way
    /// a printer that stopped answering does.
    private func follow(_ queue: String, printer: String, id: Int, sides: Int,
                        _ progress: @Sendable (JobStatus) -> Void) async throws {
        progress(JobStatus(state: .waiting, sidesDone: 0))
        var missed = 0
        do {
            while true {
                try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
                let answer = await Self.ask(queue: queue, id: id)
                if answer.gone { throw PrintError.lostContact(name: printer) }
                guard let state = answer.state else {
                    missed += 1
                    if missed < Self.missedAnswers { continue }
                    throw PrintError.refused(status: 0, detail: "The print system did not answer")
                }
                missed = 0
                let mapped = Self.jobState(state)
                switch mapped {
                case .done:
                    progress(JobStatus(state: .done, sidesDone: sides))
                    return
                case .canceled:
                    throw CancellationError()
                case .failed:
                    throw Self.stopped(answer.reasons)
                case .needsUser:
                    progress(JobStatus(state: .needsUser, sidesDone: answer.impressions,
                                       detail: Self.waiting(for: printer, answer)))
                case .printing:
                    progress(JobStatus(state: .printing, sidesDone: min(answer.impressions, sides)))
                default:
                    progress(JobStatus(state: .waiting, sidesDone: 0, detail: Self.waiting(for: printer, answer)))
                }
            }
        } catch {
            if Task.isCancelled {
                await Self.cancel(queue: queue, id: id)
                throw CancellationError()
            }
            throw error
        }
    }

    /// The Jobs tab's state for an IPP job-state: 3 pending, 4 pending-held, 5 processing, 6 processing-stopped,
    /// 7 canceled, 8 aborted, 9 completed.
    static func jobState(_ ipp: Int) -> JobState {
        switch ipp {
        case 4, 6: return .needsUser
        case 5: return .printing
        case 7: return .canceled
        case 8: return .failed
        case 9: return .done
        default: return .waiting
        }
    }

    private static func problem(_ reasons: [String]) -> PrinterProblem? {
        IppProblems.describe(reasons: reasons, message: nil, reachable: true).first
    }

    /// "Waiting for HP LaserJet", with the first reason the job or the printer gives that a person can act on.
    private static func waiting(for printer: String, _ answer: Answer) -> String {
        let text = PrintText.waiting(for: printer)
        guard let reason = problem(answer.reasons + answer.printerReasons), reason.isError else { return text }
        return text + ": " + reason.title
    }

    private static func stopped(_ reasons: [String]) -> Error {
        if let problem = problem(reasons) { return PrinterProblemError(problem: problem) }
        return PrintError.refused(status: 0, detail: "The printer stopped the job")
    }

    // MARK: libcups

    private struct Prepared: Sendable {
        var stopped: Bool
        var states: [SystemQueueState]
        var media: String?
    }

    private struct Submitted: Sendable {
        var id: Int
        var status: Int
        var message: String
    }

    private struct Answer: Sendable {
        /// The scheduler no longer knows the job: it finished and was let go of.
        var gone = false
        var state: Int?
        var reasons: [String] = []
        /// The printer's own reasons as CUPS copied them to the job (job-printer-state-reasons).
        var printerReasons: [String] = []
        var impressions = 0
    }

    private static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            sending.async { continuation.resume(returning: body()) }
        }
    }

    /// The queue's state, and the name of the paper in it that is closest to the sheet. The paper comes from
    /// cupsCopyDestInfo, which waits on the queue's printer; one that does not answer in time leaves it to CUPS.
    private static func prepare(queue: String, paper: LayoutSize, borderless: Bool) async -> Prepared {
        var prepared = await run { () -> Prepared in
            guard let dest = cupsGetNamedDest(nil, queue, nil) else { return Prepared(stopped: false, states: [], media: nil) }
            defer { cupsFreeDests(1, dest) }
            func option(_ name: String) -> String? {
                cupsGetOption(name, dest.pointee.num_options, dest.pointee.options).map { String(cString: $0) }
            }
            let state = Int(option("printer-state") ?? "") ?? 3
            let accepting = option("printer-is-accepting-jobs") != "false"
            let reasons = (option("printer-state-reasons") ?? "").split(separator: ",").map { String($0) }
            let states = CupsStates.describe(state: state, reasons: reasons, accepting: accepting)
            return Prepared(stopped: state == 5 || !accepting, states: states, media: nil)
        }
        prepared.media = await CupsQueues.within(CupsQueues.detailsTimeout) { mediaName(queue: queue, paper: paper, borderless: borderless) } ?? nil
        return prepared
    }

    private static func mediaName(queue: String, paper: LayoutSize, borderless: Bool) -> String? {
        guard let dest = cupsGetNamedDest(nil, queue, nil) else { return nil }
        defer { cupsFreeDests(1, dest) }
        guard let info = cupsCopyDestInfo(nil, dest) else { return nil }
        defer { cupsFreeDestInfo(info) }
        let width = Int32((paper.width * 2540 / 72).rounded())
        let length = Int32((paper.height * 2540 / 72).rounded())
        let exact = UInt32(CUPS_MEDIA_FLAGS_EXACT) | (borderless ? UInt32(CUPS_MEDIA_FLAGS_BORDERLESS) : 0)
        for flags in [exact, UInt32(CUPS_MEDIA_FLAGS_DEFAULT)] {
            var size = cups_size_t()
            if cupsGetDestMediaBySize(nil, dest, info, width, length, flags, &size) != 0 {
                return withUnsafePointer(to: &size.media) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
                }
            }
        }
        return nil
    }

    private static func submit(_ file: URL, queue: String, title: String, options: [String: String]) async -> Submitted {
        await run {
            var count: Int32 = 0
            var list: UnsafeMutablePointer<cups_option_t>?
            for (name, value) in options { count = cupsAddOption(name, value, count, &list) }
            defer { cupsFreeOptions(count, list) }
            let id = Int(cupsPrintFile2(nil, queue, file.path, title, count, list))
            return Submitted(id: id, status: Int(cupsLastError().rawValue), message: String(cString: cupsLastErrorString()))
        }
    }

    /// Get-Job-Attributes for the one job, so the queue's history is never read.
    private static func ask(queue: String, id: Int) async -> Answer {
        await run {
            guard let request = ippNewRequest(ipp_op_t(rawValue: 0x0009)) else { return Answer() }
            ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, "ipp://localhost/printers/" + queue)
            ippAddInteger(request, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "job-id", Int32(id))
            ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, NSUserName())
            let attributes: [String] = ["job-state", "job-state-reasons", "job-printer-state-reasons",
                                       "job-impressions-completed"]
            let wanted = attributes.map { strdup($0) }
            defer { wanted.forEach { free($0) } }
            let names: [UnsafePointer<CChar>?] = wanted.map { $0.map { UnsafePointer($0) } }
            ippAddStrings(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", Int32(names.count), nil, names)

            guard let response = cupsDoRequest(nil, request, "/") else { return Answer() }
            defer { ippDelete(response) }
            if Int(ippGetStatusCode(response).rawValue) == notFound { return Answer(gone: true) }

            var answer = Answer()
            if let state = ippFindAttribute(response, "job-state", IPP_TAG_ENUM) {
                answer.state = Int(ippGetInteger(state, 0))
            }
            if let reasons = ippFindAttribute(response, "job-state-reasons", IPP_TAG_KEYWORD) {
                for i in 0..<Int(ippGetCount(reasons)) {
                    if let reason = ippGetString(reasons, Int32(i), nil) { answer.reasons.append(String(cString: reason)) }
                }
            }
            if let reasons = ippFindAttribute(response, "job-printer-state-reasons", IPP_TAG_KEYWORD) {
                for i in 0..<Int(ippGetCount(reasons)) {
                    if let reason = ippGetString(reasons, Int32(i), nil) { answer.printerReasons.append(String(cString: reason)) }
                }
            }
            if let done = ippFindAttribute(response, "job-impressions-completed", IPP_TAG_INTEGER) {
                answer.impressions = Int(ippGetInteger(done, 0))
            }
            return answer
        }
    }

    private static func cancel(queue: String, id: Int) async {
        await run { _ = cupsCancelJob2(nil, queue, Int32(id), 0) }
    }
}
#endif
