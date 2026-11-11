import Foundation
import XCTest
@testable import LazyPrintKit

// The Mac's side of the phone link through the app's state (AppState+CompanionHost.swift), against a stand-in for the
// server (`CompanionHosting`). Swift only for the stand-in; the Windows view model keeps its batches the same way.

/// The files phones sent, as the test says they are.
@MainActor
private final class SeamHosting: CompanionHosting {
    var onChange: (@MainActor () -> Void)?
    var stored: [PhoneBatch] = []
    var files: [String: [URL]] = [:]
    private(set) var taken: [String] = []
    private(set) var discarded: [String] = []

    func batches(now: Date) -> [PhoneBatch] {
        stored
    }

    func take(batch: String) async -> [URL] {
        taken.append(batch)
        stored.removeAll { $0.id == batch }
        return files.removeValue(forKey: batch) ?? []
    }

    func discard(batch: String) {
        discarded.append(batch)
        stored.removeAll { $0.id == batch }
        for file in files.removeValue(forKey: batch) ?? [] { try? FileManager.default.removeItem(at: file) }
    }
}

final class AppStateCompanionHostTests: XCTestCase {
    private func whole(_ id: String, count: Int = 1, from: String = "Aytu's iPhone") -> PhoneBatch {
        PhoneBatch(id: id, from: from, count: count, arrived: count, lastReceived: Date())
    }

    @MainActor
    private func makeState(_ host: SeamHosting) throws -> AppState {
        AppState(companion: host, files: AppStateFiles.all(in: try tempFolder()))
    }

    @MainActor
    func test_phoneBatches_listsTheWholeBatchesOnly() throws {
        let host = SeamHosting()
        host.stored = [whole("batch-0001"),
                       PhoneBatch(id: "batch-0002", from: "Pixel", count: 3, arrived: 2, lastReceived: Date())]

        let state = try makeState(host)

        XCTAssertEqual(state.phoneBatches.map(\.id), ["batch-0001"])
    }

    @MainActor
    func test_phoneBatches_followTheHostsChanges() throws {
        let host = SeamHosting()
        let state = try makeState(host)
        XCTAssertTrue(state.phoneBatches.isEmpty)

        host.stored = [whole("batch-0001")]
        host.onChange?()
        XCTAssertEqual(state.phoneBatches.map(\.id), ["batch-0001"])

        host.stored = [whole("batch-0001"), whole("batch-0002", count: 2)]
        host.onChange?()
        XCTAssertEqual(state.phoneBatches.map(\.id), ["batch-0001", "batch-0002"])
    }

    @MainActor
    func test_aBatchThatIsNotWhole_isListedOnceItsGraceHasPassed() async throws {
        let host = SeamHosting()
        let last = Date().addingTimeInterval(0.3 - CompanionInbox.batchGrace)
        host.stored = [PhoneBatch(id: "batch-0001", from: "Aytu's iPhone", count: 3, arrived: 2, lastReceived: last)]

        let state = try makeState(host)
        XCTAssertTrue(state.phoneBatches.isEmpty)

        let deadline = Date().addingTimeInterval(10)
        while state.phoneBatches.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(state.phoneBatches.map(\.id), ["batch-0001"])
    }

    @MainActor
    func test_aBatchThatIsOffered_staysOfferedWhenAFileOfItArrivesLate() throws {
        let host = SeamHosting()
        let old = Date().addingTimeInterval(-CompanionInbox.batchGrace - 5)
        host.stored = [PhoneBatch(id: "batch-0001", from: "Aytu's iPhone", count: 3, arrived: 1, lastReceived: old)]
        let state = try makeState(host)
        XCTAssertEqual(state.phoneBatches.map(\.arrived), [1])

        host.stored = [PhoneBatch(id: "batch-0001", from: "Aytu's iPhone", count: 3, arrived: 2, lastReceived: Date())]
        host.onChange?()

        XCTAssertEqual(state.phoneBatches.map(\.arrived), [2])
    }

    @MainActor
    func test_aBatchThatIsOffered_keepsItsPlaceWhenAFileOfItArrivesLate() throws {
        let host = SeamHosting()
        let old = Date().addingTimeInterval(-CompanionInbox.batchGrace - 5)
        let second = PhoneBatch(id: "batch-0002", from: "Ela's iPhone", count: 1, arrived: 1, lastReceived: old.addingTimeInterval(1))
        host.stored = [PhoneBatch(id: "batch-0001", from: "Aytu's iPhone", count: 2, arrived: 1, lastReceived: old), second]
        let state = try makeState(host)
        XCTAssertEqual(state.phoneBatches.map(\.id), ["batch-0001", "batch-0002"])

        host.stored = [second, PhoneBatch(id: "batch-0001", from: "Aytu's iPhone", count: 2, arrived: 2, lastReceived: Date())]
        host.onChange?()

        XCTAssertEqual(state.phoneBatches.map(\.id), ["batch-0001", "batch-0002"])
    }

    @MainActor
    func test_reportSyncProblem_putsANoticeInTheBar_butNotOverAFailure() throws {
        let state = try makeState(SeamHosting())

        state.reportSyncProblem("Report.pdf in the cloud folder could not be read.")

        XCTAssertEqual(state.error?.title, "Phone sync")
        XCTAssertEqual(state.error?.isNotice, true)

        state.showFailure("Not added", "Notes.txt: unreadable")
        state.reportSyncProblem("Another file could not be read.")

        XCTAssertEqual(state.error?.title, "Not added")
    }

    @MainActor
    func test_reportSyncProblem_keepsTheSentMessage_andTheNoticeLeavesWithTheProblem() throws {
        let state = try makeState(SeamHosting())
        state.sentMessage = "Sent 3 sheets to HP LaserJet"

        state.reportSyncProblem("Report.pdf in the cloud folder could not be read.")

        XCTAssertEqual(state.sentMessage, "Sent 3 sheets to HP LaserJet")
        XCTAssertEqual(state.error?.title, "Phone sync")

        state.reportSyncProblem(nil)

        XCTAssertNil(state.error)
    }

    @MainActor
    func test_takeBatch_addsTheFilesToTheJob() async throws {
        let host = SeamHosting()
        let state = try makeState(host)
        let folder = try tempFolder()
        await state.addFiles([try writePDF(named: "Mine.pdf", pages: 1, in: folder)])
        let first = try writePDF(named: "First.pdf", pages: 2, in: folder)
        let second = try writePDF(named: "Second.pdf", pages: 1, in: folder)
        host.stored = [whole("batch-0001", count: 2)]
        host.files["batch-0001"] = [first, second]
        host.onChange?()

        await state.takeBatch("batch-0001", startNew: false)

        XCTAssertEqual(state.documents.map { $0.url.lastPathComponent }, ["Mine.pdf", "First.pdf", "Second.pdf"])
        XCTAssertTrue(state.phoneBatches.isEmpty)
        XCTAssertNil(state.error)
    }

    @MainActor
    func test_takeBatch_withNoTask_startsNoneAndLeavesTheSettings() async throws {
        let host = SeamHosting()
        let state = try makeState(host)
        let folder = try tempFolder()
        state.settings.pagesPerSheet = 2
        state.settings.sides = .longEdge
        host.stored = [whole("batch-0001")]
        host.files["batch-0001"] = [try writePDF(named: "Sent.pdf", pages: 1, in: folder)]
        host.onChange?()

        await state.takeBatch("batch-0001", startNew: false)

        XCTAssertEqual(state.documents.map { $0.url.lastPathComponent }, ["Sent.pdf"])
        XCTAssertNil(state.task)
        XCTAssertEqual(state.settings.pagesPerSheet, 2)
        XCTAssertEqual(state.settings.sides, .longEdge)
    }

    @MainActor
    func test_takeBatch_asANewJob_clearsTheJobFirst() async throws {
        let host = SeamHosting()
        let state = try makeState(host)
        let folder = try tempFolder()
        await state.addFiles([try writePDF(named: "Mine.pdf", pages: 3, in: folder)])
        state.setPageRange("1-2")
        let sent = try writePDF(named: "Sent.pdf", pages: 1, in: folder)
        host.stored = [whole("batch-0001")]
        host.files["batch-0001"] = [sent]
        host.onChange?()

        await state.takeBatch("batch-0001", startNew: true)

        XCTAssertEqual(state.documents.map { $0.url.lastPathComponent }, ["Sent.pdf"])
        XCTAssertEqual(state.pageRange, "")
        XCTAssertTrue(state.phoneBatches.isEmpty)
    }

    @MainActor
    func test_takeBatch_asANewJob_keepsTheJobWhenNothingOpens() async throws {
        let host = SeamHosting()
        let state = try makeState(host)
        let folder = try tempFolder()
        await state.addFiles([try writePDF(named: "Mine.pdf", pages: 3, in: folder)])
        state.setPageRange("1-2")
        let notes = folder.appendingPathComponent("Notes.txt")
        try Data("not a picture".utf8).write(to: notes)
        host.stored = [whole("batch-0001")]
        host.files["batch-0001"] = [notes]
        host.onChange?()

        await state.takeBatch("batch-0001", startNew: true)

        XCTAssertEqual(state.documents.map { $0.url.lastPathComponent }, ["Mine.pdf"])
        XCTAssertEqual(state.pageRange, "1-2")
        XCTAssertEqual(state.error?.title, "Not added")
        XCTAssertEqual(state.error?.detail.hasPrefix("Notes.txt: "), true)
    }

    @MainActor
    func test_takeBatch_whenNothingOpens_keepsTheSettingsOfTheJobToo() async throws {
        let host = SeamHosting()
        let state = try makeState(host)
        let folder = try tempFolder()
        await state.addFiles([try writePDF(named: "Mine.pdf", pages: 3, in: folder)])
        state.settings.pagesPerSheet = 2
        let notes = folder.appendingPathComponent("Notes.txt")
        try Data("not a picture".utf8).write(to: notes)
        host.stored = [whole("batch-0001")]
        host.files["batch-0001"] = [notes]
        host.onChange?()

        await state.takeBatch("batch-0001", startNew: true)

        XCTAssertNil(state.task)
        XCTAssertEqual(state.settings.pagesPerSheet, 2)
    }

    @MainActor
    func test_takeBatch_aFileThatCannotBeRead_isSaidAndTheOthersStillGoIn() async throws {
        let host = SeamHosting()
        let state = try makeState(host)
        let folder = try tempFolder()
        let notes = folder.appendingPathComponent("Notes.txt")
        try Data("not a picture".utf8).write(to: notes)
        let good = try writePDF(named: "Good.pdf", pages: 1, in: folder)
        host.stored = [whole("batch-0001", count: 2)]
        host.files["batch-0001"] = [notes, good]

        await state.takeBatch("batch-0001", startNew: false)

        XCTAssertEqual(state.documents.map { $0.url.lastPathComponent }, ["Good.pdf"])
        XCTAssertEqual(state.error?.title, "Not added")
    }

    @MainActor
    func test_dismissBatch_deletesTheFiles() throws {
        let host = SeamHosting()
        let state = try makeState(host)
        let folder = try tempFolder()
        let file = folder.appendingPathComponent("Sent.pdf")
        try Data("%PDF-1.7".utf8).write(to: file)
        host.stored = [whole("batch-0001")]
        host.files["batch-0001"] = [file]
        host.onChange?()
        XCTAssertEqual(state.phoneBatches.count, 1)

        state.dismissBatch("batch-0001")

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(host.discarded, ["batch-0001"])
        XCTAssertEqual(host.taken, [])
        XCTAssertTrue(state.phoneBatches.isEmpty)
        XCTAssertTrue(state.documents.isEmpty)
    }

    @MainActor
    func test_takeBatch_aFileThatCouldNotBeMoved_isSaidAndTheOthersStillGoIn() async throws {
        let host = SeamHosting()
        let state = try makeState(host)
        let good = try writePDF(named: "Good.pdf", pages: 1, in: try tempFolder())
        host.stored = [whole("batch-0001", count: 2)]
        host.onChange?()
        host.files["batch-0001"] = [good]

        await state.takeBatch("batch-0001", startNew: false)

        XCTAssertEqual(state.documents.map { $0.url.lastPathComponent }, ["Good.pdf"])
        XCTAssertEqual(state.error?.title, "Not added")
        XCTAssertEqual(state.error?.detail, "1 of the 2 files from Aytu's iPhone could not be moved.")
    }

    @MainActor
    func test_takeBatch_waitsWhileAJobRuns() async throws {
        let host = SeamHosting()
        let state = try makeState(host)
        host.stored = [whole("batch-0001")]
        host.onChange?()
        state.isBusy = true

        await state.takeBatch("batch-0001", startNew: true)

        XCTAssertEqual(host.taken, [])
        XCTAssertEqual(state.phoneBatches.count, 1)
    }

    @MainActor
    func test_takeBatch_ofABatchThatIsGone_changesNothing() async throws {
        let state = try makeState(SeamHosting())

        await state.takeBatch("batch-0001", startNew: true)

        XCTAssertTrue(state.documents.isEmpty)
        XCTAssertNil(state.error)
    }
}
