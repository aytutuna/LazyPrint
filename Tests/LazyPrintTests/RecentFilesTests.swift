import Foundation
import XCTest
@testable import LazyPrintKit

// Twin of RecentFilesTests.cs: the recent list, what opening files does to it, and the Lazy PDF hand-off.

@MainActor
private final class LazyPdfActions: FileActionService {
    var installed = false
    private(set) var opened: [URL] = []

    func open(_ url: URL) throws {}
    func reveal(_ url: URL) throws {}
    func openWith(_ url: URL) throws {}
    func copyText(_ text: String) throws {}
    func lazyScanInstalled() -> Bool { false }
    func openLazyScan() throws {}
    func lazyPDFInstalled() -> Bool { installed }
    func openInLazyPDF(_ url: URL) throws { opened.append(url) }
}

final class RecentFilesTests: XCTestCase {
    private func file(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func test_theNewestFileIsFirstAndAnOpenedOneMovesUp() throws {
        let folder = try tempFolder()
        let recent = RecentFiles(directory: folder)
        let a = try file("a.pdf", in: folder)
        let b = try file("b.pdf", in: folder)
        recent.add(a)
        recent.add(b)
        recent.add(a)

        XCTAssertEqual(recent.load().map { $0.path }, [a.path, b.path])
    }

    func test_theListKeepsTenFiles() throws {
        let folder = try tempFolder()
        let recent = RecentFiles(directory: folder)
        for i in 0..<12 { recent.add(try file("\(i).pdf", in: folder)) }

        let files = recent.load()
        XCTAssertEqual(files.count, 10)
        XCTAssertEqual(URL(fileURLWithPath: files[0].path).lastPathComponent, "11.pdf")
        XCTAssertEqual(URL(fileURLWithPath: files[9].path).lastPathComponent, "2.pdf")
    }

    func test_aRemovedFileGoesAndClearEmptiesTheList() throws {
        let folder = try tempFolder()
        let recent = RecentFiles(directory: folder)
        let a = try file("a.pdf", in: folder)
        let b = try file("b.pdf", in: folder)
        recent.add(a)
        recent.add(b)
        recent.remove(a)
        XCTAssertEqual(recent.load().map { $0.path }, [b.path])

        recent.clear()
        XCTAssertTrue(recent.load().isEmpty)
    }

    func test_aFileIsFoundAgainThroughItsEntry() throws {
        let folder = try tempFolder()
        let recent = RecentFiles(directory: folder)
        let a = try file("a.pdf", in: folder)
        recent.add(a)

        let entry = try XCTUnwrap(recent.load().first)
        XCTAssertEqual(recent.locate(entry).standardizedFileURL.resolvingSymlinksInPath(), a.standardizedFileURL.resolvingSymlinksInPath())
    }

    @MainActor
    func test_openedFilesAreRecentAndOnesThatAreGoneAreDropped() async throws {
        let folder = try tempFolder()
        let state = AppState(files: AppStateFiles.all(in: folder))
        let kept = try writePDF(named: "Kept.pdf", pages: 1, in: folder)
        let gone = try writePDF(named: "Gone.pdf", pages: 1, in: folder)
        await state.addFiles([gone, kept])
        state.remember([gone, kept])
        XCTAssertEqual(state.recentFiles.count, 2)

        try FileManager.default.removeItem(at: gone)
        state.refreshRecent()
        XCTAssertEqual(state.recentFiles.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["Kept.pdf"])
    }

    @MainActor
    func test_aFileThatDidNotOpenIsNotRecent() async throws {
        let folder = try tempFolder()
        let state = AppState(files: AppStateFiles.all(in: folder))
        let notes = folder.appendingPathComponent("blob.bin")
        try Data([0, 1, 2, 3]).write(to: notes)
        await state.addFiles([notes])
        state.remember([notes])

        XCTAssertTrue(state.recentFiles.isEmpty)
    }

    @MainActor
    func test_clearRecentEmptiesTheMenu() async throws {
        let folder = try tempFolder()
        let state = AppState(files: AppStateFiles.all(in: folder))
        let a = try writePDF(named: "A.pdf", pages: 1, in: folder)
        await state.addFiles([a])
        state.remember([a])
        XCTAssertFalse(state.recentFiles.isEmpty)

        state.clearRecent()
        XCTAssertTrue(state.recentFiles.isEmpty)
        XCTAssertTrue(RecentFiles(directory: folder).load().isEmpty)
    }

    @MainActor
    func test_lazyPdfIsOfferedForAPdfOnlyWhenItIsInstalled() async throws {
        let folder = try tempFolder()
        let actions = LazyPdfActions()
        let missing = AppState(fileActions: actions, files: AppStateFiles.all(in: folder))
        let a = try writePDF(named: "A.pdf", pages: 1, in: folder)
        await missing.addFiles([a])
        XCTAssertFalse(missing.canEditInLazyPDF(missing.documents[0]))

        actions.installed = true
        let state = AppState(fileActions: actions, files: AppStateFiles.all(in: folder))
        await state.addFiles([a])
        XCTAssertTrue(state.canEditInLazyPDF(state.documents[0]))

        state.editInLazyPDF(state.documents[0])
        XCTAssertEqual(actions.opened, [a])
    }

    @MainActor
    func test_lazyPdfIsNotOfferedForAPicture() async throws {
        let folder = try tempFolder()
        let actions = LazyPdfActions()
        actions.installed = true
        let state = AppState(fileActions: actions, files: AppStateFiles.all(in: folder))
        await state.addFiles([try writePicture(.png, ext: "png", colors: [Pixels.red])])

        XCTAssertFalse(state.canEditInLazyPDF(state.documents[0]))
    }
}
