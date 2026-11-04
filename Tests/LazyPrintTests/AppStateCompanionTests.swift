import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import LazyPrintKit

// The phone's side of the phone link through the app's state (AppState+Companion.swift), against the stub
// desktop of CompanionFakes.swift. Swift only: Windows has no phone side. Every AppState here keeps its
// settings and phone link files in a folder of its own.

final class AppStateCompanionTests: XCTestCase {
    private var folder: URL!
    private var secrets: MemorySecretStore!

    private var companionFolder: URL { folder.appendingPathComponent("Network", isDirectory: true) }

    override func setUpWithError() throws {
        folder = try tempFolder()
        secrets = MemorySecretStore()
    }

    /// An AppState with `count` one-page PDFs added to its job, its phone link set up on the stub desktops.
    @MainActor
    private func makeState(files count: Int = 0) async throws -> AppState {
        let state = AppState(files: AppStateFiles.all(in: folder))
        if count > 0 {
            for number in 1...count {
                await state.addFiles([try writePDF(named: "File \(number).pdf", pages: 1, in: folder)])
            }
        }
        XCTAssertEqual(state.documents.count, count)
        state.companionProtocolClasses = [CompanionStubProtocol.self]
        state.setUpCompanion(in: companionFolder, secrets: secrets)
        return state
    }

    private func code(_ fake: CompanionFakeDesktop) throws -> String {
        try PairingUri(desktopId: CompanionLink.desktopId, name: "Office PC", fingerprint: CompanionVectors.fingerprintText,
                       addresses: [CompanionLink.address], port: fake.port, token: CompanionVectors.tokenText).format()
    }

    /// A PDF to put in the outbox of a desktop other than the paired one.
    private func pdf(_ name: String) throws -> URL {
        try writePDF(named: name, pages: 1, in: folder)
    }

    private func created(_ id: String) -> CompanionStubAnswer {
        .json(201, InboxResponse(packageId: id, duplicate: false).toJSON())
    }

    @MainActor
    private func pair(_ state: AppState, with fake: CompanionFakeDesktop) async throws {
        fake.on("POST " + CompanionProtocol.pairPath, CompanionLink.pairResponse())
        let uri = try code(fake)
        await state.pairDesktop(uri: uri, phoneName: "Test phone")
        XCTAssertNil(state.error)
    }

    /// The sync key the desktop hands out in `pairWithSyncKey`: 0x01...0x20.
    private let syncKey = Data((1...32).map { UInt8($0) })

    /// Pairs with a desktop that has the cloud sync folder.
    @MainActor
    private func pairWithSyncKey(_ state: AppState, with fake: CompanionFakeDesktop) async throws {
        fake.on("POST " + CompanionProtocol.pairPath,
                .json(200, PairResponse(desktopId: CompanionLink.desktopId, desktopName: "Office PC",
                                        deviceSecret: CompanionVectors.secretText, protocolVersion: CompanionProtocol.version,
                                        syncKey: CompanionProtocol.encodeBase64Url(syncKey)).toJSON()))
        let uri = try code(fake)
        await state.pairDesktop(uri: uri, phoneName: "Test phone")
        XCTAssertNil(state.error)
    }

    /// Sets `cloud` as the sync folder, opened by a resolver standing in for the iPhone's bookmarks.
    @MainActor
    private func setSyncFolder(_ state: AppState, _ cloud: URL) {
        state.resolveSyncFolderBookmark = { bookmark in (folder: cloud, bookmark: bookmark) }
        state.setSyncFolder(bookmark: Data("cloud folder".utf8))
    }

    @MainActor
    func test_pairDesktop_keepsTheDesktopAndItsSecret() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        XCTAssertEqual(state.companionStatus, .notPaired)

        try await pair(state, with: fake)

        let desktop = try XCTUnwrap(state.companionDesktop)
        XCTAssertEqual(desktop.id, CompanionLink.desktopId)
        XCTAssertEqual(desktop.name, "Office PC")
        XCTAssertEqual(desktop.addresses, [CompanionLink.address])
        XCTAssertTrue(CompanionProtocol.isValidId(desktop.phoneId))
        XCTAssertEqual(state.companionStatus, .reachable(desktopName: "Office PC"))
        XCTAssertEqual(state.statusAccessible, CompanionText.pairedMessage("Office PC"))
        XCTAssertEqual(try secrets.load(for: CompanionLink.desktopId), CompanionVectors.secret)
        XCTAssertEqual(PairedDesktopStore(directory: companionFolder, secrets: secrets).load(), desktop)
        let request = try XCTUnwrap(PairRequest.fromJSON(fake.requests("POST " + CompanionProtocol.pairPath)[0].body))
        XCTAssertEqual(request.phoneId, desktop.phoneId)
        XCTAssertEqual(request.phoneName, "Test phone")

        // A new start finds it again.
        let again = try await makeState()
        XCTAssertEqual(again.companionDesktop, desktop)
        XCTAssertEqual(again.companionStatus, .checking)
    }

    @MainActor
    func test_pairDesktop_refusal_saysTheDesktopsMessage() async throws {
        let fake = CompanionFakeDesktop()
        fake.on("POST " + CompanionProtocol.pairPath, .error(403, CompanionError.declined))
        let state = try await makeState()
        let uri = try code(fake)

        await state.pairDesktop(uri: uri, phoneName: "Test phone")

        XCTAssertEqual(state.error?.title, "Not paired")
        XCTAssertEqual(state.error?.detail, CompanionError.declined.message)
        XCTAssertNil(state.companionDesktop)
        XCTAssertEqual(state.companionStatus, .notPaired)
        XCTAssertEqual(secrets.count, 0)

        await state.pairDesktop(uri: "https://example.com", phoneName: "Test phone")
        XCTAssertEqual(state.error?.detail, PairingUri.notPairingCodeMessage)
    }

    @MainActor
    func test_checkDesktop_401_forgetsTheSecretAndSaysUnpaired() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.unauthorized)

        await state.checkDesktop()

        XCTAssertEqual(state.companionStatus, .unpaired(byDesktop: "Office PC"))
        XCTAssertNil(try secrets.load(for: CompanionLink.desktopId))
        XCTAssertNotNil(state.companionDesktop)
    }

    @MainActor
    func test_checkDesktop_reachable_thenUnreachableWithItsReason() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello())

        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .reachable(desktopName: "Office PC"))

        fake.downHosts = [CompanionLink.address]
        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .unreachable(reason: "Office PC is not on this network."))

        var asked: [String] = []
        state.companionDesktopSeenOnNetwork = { id in
            asked.append(id)
            return true
        }
        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .unreachable(reason: CompanionText.refusedReason))
        XCTAssertEqual(asked, [CompanionLink.desktopId])

        state.companionAccessDenied = { true }
        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .unreachable(reason: CompanionText.localNetworkOffReason))
        XCTAssertNotNil(try secrets.load(for: CompanionLink.desktopId))
    }

    @MainActor
    func test_sendJobToDesktop_sendsTheOriginalFilesAsOneBatch() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(files: 2)
        try await pair(state, with: fake)
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*") { request in
            self.created(String(request.path.dropFirst(CompanionProtocol.inboxPrefix.count)))
        }
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello())

        await state.sendJobToDesktop(from: "Aytu's iPhone")

        XCTAssertNil(state.error)
        XCTAssertEqual(state.sentMessage, "2 files sent to Office PC.")
        XCTAssertEqual(state.statusAccessible, "2 files sent to Office PC.")
        XCTAssertEqual(state.companionOutboxCount, 0)
        XCTAssertEqual(state.companionStatus, .reachable(desktopName: "Office PC"))
        XCTAssertEqual(state.documents.count, 2)
        let infos = try fake.requests.filter { $0.method == "PUT" }.map { try PrintPackage.read($0.body) }
        XCTAssertEqual(infos.map(\.name), ["File 1.pdf", "File 2.pdf"])
        XCTAssertEqual(infos.map(\.index), [0, 1])
        XCTAssertEqual(infos.map(\.count), [2, 2])
        XCTAssertEqual(infos.map(\.from), ["Aytu's iPhone", "Aytu's iPhone"])
        XCTAssertEqual(Set(infos.map(\.batch)).count, 1)
        XCTAssertTrue(CompanionProtocol.isValidId(infos[0].batch))
        let left = try FileManager.default.contentsOfDirectory(atPath: companionFolder.appendingPathComponent("Outbox").path)
        XCTAssertEqual(left.filter { $0.hasSuffix(".lppkg") }, [])
    }

    @MainActor
    func test_sendJobToDesktop_aPictureThatIsNotAnUprightJpeg_isSentAsItIs() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*") { request in
            self.created(String(request.path.dropFirst(CompanionProtocol.inboxPrefix.count)))
        }
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello())
        await state.addFiles([try writePicture(.png, ext: "png", colors: [Pixels.red])])
        XCTAssertEqual(state.documents.count, 1)

        await state.sendJobToDesktop(from: "Aytu's iPhone")

        XCTAssertNil(state.error)
        XCTAssertEqual(state.sentMessage, "1 file sent to Office PC.")
        let infos = try fake.requests.filter { $0.method == "PUT" }.map { try PrintPackage.read($0.body) }
        XCTAssertEqual(infos.map(\.contentType), ["image/png"])
    }

    @MainActor
    func test_sendJobToDesktop_anEmptyJob_hasNothingToSend() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)

        await state.sendJobToDesktop(from: "Aytu's iPhone")

        XCTAssertEqual(state.error?.title, "Nothing to send")
        XCTAssertEqual(state.error?.detail, CompanionText.nothingToSendMessage)
        XCTAssertEqual(state.companionOutboxCount, 0)
        XCTAssertTrue(fake.requests.filter { $0.method == "PUT" }.isEmpty)
    }

    @MainActor
    func test_sendJobToDesktop_whileADrainRuns_takesNoReasonFromAnOldStatus() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(files: 1)
        try await pair(state, with: fake)
        state.statusOverride = PrintText.printed
        state.companionDraining = true

        await state.sendJobToDesktop(from: "Aytu's iPhone")

        XCTAssertEqual(state.companionOutboxCount, 1)
        XCTAssertNil(state.error)
    }

    @MainActor
    func test_sendJobToDesktop_unreachable_keepsTheFilesUntilTheyGo() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(files: 1)
        try await pair(state, with: fake)
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*") { request in
            let id = String(request.path.dropFirst(CompanionProtocol.inboxPrefix.count))
            return .json(200, InboxResponse(packageId: id, duplicate: true).toJSON())
        }
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello())
        fake.downHosts = [CompanionLink.address]
        // Bars left by an earlier send or a print do not hide the notice.
        state.sentMessage = "2 files sent to Office PC."

        await state.sendJobToDesktop(from: "Aytu's iPhone")

        XCTAssertNil(state.sentMessage)
        XCTAssertEqual(state.statusAccessible, "Office PC cannot be reached on this network.")
        XCTAssertEqual(state.companionStatus, .unreachable(reason: "Office PC is not on this network."))
        XCTAssertEqual(state.companionOutboxCount, 1)
        // The status line is not on every screen, so the sender is told where the file waits.
        XCTAssertEqual(state.error?.title, "Not sent yet")
        XCTAssertEqual(state.error?.isNotice, true)
        XCTAssertEqual(state.error?.detail, CompanionText.waitingMessage("Office PC cannot be reached on this network."))

        fake.downHosts = []
        await state.drainOutbox()

        // A duplicate counts as sent: the desktop had it.
        XCTAssertEqual(state.statusAccessible, "1 file sent to Office PC.")
        XCTAssertEqual(state.companionOutboxCount, 0)
    }

    @MainActor
    func test_sendJobToDesktop_notPaired_isRefused() async throws {
        let state = try await makeState(files: 1)

        await state.sendJobToDesktop(from: "Aytu's iPhone")

        XCTAssertEqual(state.error?.detail, CompanionText.notPairedMessage)
        XCTAssertEqual(state.error?.isNotice, true)
        XCTAssertEqual(state.companionOutboxCount, 0)
    }

    @MainActor
    func test_sendJobToDesktop_moreThanTheOutboxHolds_isRefusedWhole() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(files: 2)
        try await pair(state, with: fake)
        let outbox = try XCTUnwrap(state.companionOutbox)
        for number in 0..<(PhoneOutbox.maxItems - 1) {
            try outbox.enqueue(file: try pdf("Waiting \(number).pdf"), name: "Waiting \(number).pdf", contentType: "application/pdf",
                               batch: "batch-0001", index: 0, count: 1, from: "x", desktopId: CompanionLink.desktopId)
        }

        await state.sendJobToDesktop(from: "Aytu's iPhone")

        XCTAssertEqual(state.error?.detail, CompanionText.outboxFullMessage)
        XCTAssertEqual(outbox.count, PhoneOutbox.maxItems - 1)
    }

    @MainActor
    func test_drainOutbox_sendsAFileOnlyToTheDesktopItWasFor() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*") { request in
            self.created(String(request.path.dropFirst(CompanionProtocol.inboxPrefix.count)))
        }
        let outbox = try XCTUnwrap(state.companionOutbox)
        try outbox.enqueue(file: try pdf("For another.pdf"), name: "For another.pdf", contentType: "application/pdf",
                           batch: "batch-0001", index: 0, count: 1, from: "x", desktopId: "desk-0002-other")

        await state.drainOutbox()

        XCTAssertTrue(fake.requests.filter { $0.method == "PUT" }.isEmpty)
        XCTAssertEqual(state.companionOutboxCount, 0)
        XCTAssertEqual(state.companionOtherOutboxCount, 1)
    }

    @MainActor
    func test_clearOutbox_removesTheWaitingFiles() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(files: 1)
        try await pair(state, with: fake)
        fake.downHosts = [CompanionLink.address]
        await state.sendJobToDesktop(from: "Aytu's iPhone")
        XCTAssertEqual(state.companionOutboxCount, 1)

        state.clearOutbox()

        XCTAssertEqual(state.companionOutboxCount, 0)
        let outbox = companionFolder.appendingPathComponent("Outbox")
        let packages = try FileManager.default.contentsOfDirectory(atPath: outbox.path)
            .filter { $0.hasSuffix("." + PrintPackage.fileExtension) }
        XCTAssertEqual(packages, [])
        XCTAssertEqual(state.documents.count, 1)
    }

    @MainActor
    func test_clearOutbox_keepsWhatWaitsForAnotherDesktop_clearOtherOutboxRemovesIt() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(files: 1)
        try await pair(state, with: fake)
        let outbox = try XCTUnwrap(state.companionOutbox)
        let other = try outbox.enqueue(file: try pdf("For another.pdf"), name: "For another.pdf", contentType: "application/pdf",
                                       batch: "batch-0001", index: 0, count: 1, from: "x", desktopId: "desk-0002-other")
        fake.downHosts = [CompanionLink.address]
        await state.sendJobToDesktop(from: "Aytu's iPhone")
        XCTAssertEqual(state.companionOutboxCount, 1)
        XCTAssertEqual(state.companionOtherOutboxCount, 1)

        state.clearOutbox()

        XCTAssertEqual(state.companionOutboxCount, 0)
        XCTAssertEqual(state.companionOtherOutboxCount, 1)
        XCTAssertEqual(outbox.items.map(\.id), [other.id])

        await state.sendJobToDesktop(from: "Aytu's iPhone")
        state.clearOtherOutbox()

        XCTAssertEqual(state.companionOutboxCount, 1)
        XCTAssertEqual(state.companionOtherOutboxCount, 0)
        XCTAssertEqual(outbox.items.map(\.desktopId), [CompanionLink.desktopId])
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.fileURL(of: other).path))
    }

    @MainActor
    func test_pairDesktop_anotherDesktop_countsWhatWaitsForTheFirstApart_andSendsNoneOfIt() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(files: 1)
        try await pairWithSyncKey(state, with: fake)
        let cloud = folder.appendingPathComponent("iCloud Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        setSyncFolder(state, cloud)
        fake.downHosts = [CompanionLink.address]
        await state.sendJobToDesktop(from: "Aytu's iPhone")
        XCTAssertEqual(state.companionInSyncFolderCount, 1)
        await state.unpairDesktop()

        // With none paired it still waits to be sent, for that desktop.
        XCTAssertEqual(state.companionOutboxCount, 1)
        XCTAssertEqual(state.companionOtherOutboxCount, 0)

        let laptopId = "desk-0002-laptop"
        let laptop = CompanionFakeDesktop()
        laptop.on("POST " + CompanionProtocol.pairPath,
                  .json(200, PairResponse(desktopId: laptopId, desktopName: "Laptop", deviceSecret: CompanionVectors.secretText,
                                          protocolVersion: CompanionProtocol.version).toJSON()))
        let uri = try PairingUri(desktopId: laptopId, name: "Laptop", fingerprint: CompanionVectors.fingerprintText,
                                 addresses: [CompanionLink.address], port: laptop.port,
                                 token: CompanionVectors.tokenText).format()
        await state.pairDesktop(uri: uri, phoneName: "Test phone")
        XCTAssertNil(state.error)

        XCTAssertEqual(state.companionOutboxCount, 0)
        XCTAssertEqual(state.companionOtherOutboxCount, 1)
        XCTAssertEqual(state.companionInSyncFolderCount, 0)

        laptop.on("PUT " + CompanionProtocol.inboxPrefix + "*") { request in
            self.created(String(request.path.dropFirst(CompanionProtocol.inboxPrefix.count)))
        }
        laptop.on("GET " + CompanionProtocol.helloPath,
                  .json(200, HelloResponse(desktopId: laptopId, desktopName: "Laptop", protocolVersion: CompanionProtocol.version,
                                           maxUploadBytes: CompanionProtocol.maxUploadBytes).toJSON()))
        await state.sendJobToDesktop(from: "Aytu's iPhone")

        XCTAssertEqual(state.statusAccessible, "1 file sent to Laptop.")
        XCTAssertEqual(laptop.requests.filter { $0.method == "PUT" }.count, 1)
        XCTAssertEqual(state.companionOutboxCount, 0)
        XCTAssertEqual(state.companionOtherOutboxCount, 1)
    }

    @MainActor
    func test_desktopFound_keepsTheNewAddresses_ofThePairedDesktopOnly() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello())

        await state.desktopFound(id: "desk-0002-other", addresses: ["192.168.1.99"], port: fake.port)
        XCTAssertEqual(state.companionDesktop?.addresses, [CompanionLink.address])

        // Anyone can advertise the desktop's id: where the desktop does not answer, nothing is kept.
        fake.downHosts = ["192.168.1.66"]
        let unanswered = await state.desktopFound(id: CompanionLink.desktopId, addresses: ["192.168.1.66"],
                                                  port: fake.port)
        XCTAssertFalse(unanswered)
        XCTAssertEqual(state.companionDesktop?.addresses, [CompanionLink.address])
        fake.downHosts = []

        let kept = await state.desktopFound(id: CompanionLink.desktopId,
                                            addresses: ["fe80::1%4", "192.168.1.30", "printer.local"], port: fake.port)
        XCTAssertTrue(kept)
        let desktop = try XCTUnwrap(state.companionDesktop)
        XCTAssertEqual(desktop.addresses, ["192.168.1.30", "fe80::1%4"])
        XCTAssertEqual(PairedDesktopStore(directory: companionFolder, secrets: secrets).load()?.addresses,
                       desktop.addresses)

        // The old address is gone: the desktop answers at the new one.
        fake.downHosts = [CompanionLink.address]
        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .reachable(desktopName: "Office PC"))
    }

    @MainActor
    func test_unpairDesktop_tellsTheDesktopAndForgetsIt() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        fake.on("DELETE " + CompanionProtocol.deviceSelfPath, .empty(204))

        await state.unpairDesktop()

        XCTAssertEqual(fake.requests("DELETE " + CompanionProtocol.deviceSelfPath).count, 1)
        XCTAssertNil(state.companionDesktop)
        XCTAssertEqual(state.companionStatus, .notPaired)
        XCTAssertEqual(secrets.count, 0)
        XCTAssertNil(PairedDesktopStore(directory: companionFolder, secrets: secrets).load())
    }

    @MainActor
    func test_pairDesktop_keepsTheSyncKey_andAnOldDesktopGivesNone() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        XCTAssertFalse(state.canUseSyncFolder)

        try await pairWithSyncKey(state, with: fake)

        XCTAssertTrue(state.canUseSyncFolder)
        XCTAssertEqual(try secrets.load(for: CompanionLink.desktopId + ".sync"), syncKey)
    }

    @MainActor
    func test_drainOutbox_unreachable_putsTheFileInTheSyncFolder() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(files: 1)
        try await pairWithSyncKey(state, with: fake)
        let cloud = folder.appendingPathComponent("iCloud Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        setSyncFolder(state, cloud)
        fake.downHosts = [CompanionLink.address]

        await state.sendJobToDesktop(from: "Aytu's iPhone")

        XCTAssertNil(state.error)
        XCTAssertEqual(state.companionOutboxCount, 1)
        XCTAssertEqual(state.companionOutbox?.items.first?.inSyncFolder, true)
        let names = try FileManager.default.contentsOfDirectory(atPath: cloud.path)
        XCTAssertEqual(names.count, 1)
        let name = try XCTUnwrap(names.first)
        XCTAssertTrue(name.hasSuffix("." + SyncPackage.fileExtension))
        let packageId = String(name.dropLast(SyncPackage.fileExtension.count + 1))
        XCTAssertTrue(CompanionProtocol.isValidId(packageId))
        let desktop = try XCTUnwrap(state.companionDesktop)
        let opened = try SyncPackage.open(Data(contentsOf: cloud.appendingPathComponent(name)), packageId: packageId,
                                          phoneId: desktop.phoneId, key: syncKey)
        XCTAssertEqual(try PrintPackage.read(opened).name, "File 1.pdf")
        XCTAssertEqual(state.statusAccessible, "Put File 1.pdf in the cloud folder for Office PC.")
        XCTAssertEqual(state.sentMessage, state.statusAccessible)
        XCTAssertEqual(state.companionInSyncFolderCount, 1)

        // It waits until the desktop takes the file out of the folder.
        await state.drainOutbox()
        XCTAssertEqual(state.companionOutboxCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.path), [name])
        try FileManager.default.removeItem(at: cloud.appendingPathComponent(name))
        await state.drainOutbox()
        XCTAssertEqual(state.companionOutboxCount, 0)
    }

    @MainActor
    func test_drainOutbox_unreachable_leavesWhatTheDesktopRefusedOutOfTheSyncFolder() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(files: 1)
        try await pairWithSyncKey(state, with: fake)
        let cloud = folder.appendingPathComponent("OneDrive", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        setSyncFolder(state, cloud)
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*",
                .error(422, CompanionError(code: CompanionErrorCode.invalidPackage, message: PrintPackage.contentMessage)))
        await state.sendJobToDesktop(from: "Aytu's iPhone")
        XCTAssertEqual(state.companionOutbox?.items.first?.refused, true)

        fake.downHosts = [CompanionLink.address]
        await state.sendJobToDesktop(from: "Aytu's iPhone")

        let items = try XCTUnwrap(state.companionOutbox?.items)
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items[0].inSyncFolder)
        XCTAssertTrue(items[1].inSyncFolder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.path), [SyncPackage.fileName(items[1].id)])
    }

    @MainActor
    func test_drainOutbox_anotherErrorStatus_stillLetsTheFileGoInTheSyncFolder() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(files: 1)
        try await pairWithSyncKey(state, with: fake)
        let cloud = folder.appendingPathComponent("OneDrive", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        setSyncFolder(state, cloud)
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*", .error(500, CompanionError.serverError))
        await state.sendJobToDesktop(from: "Aytu's iPhone")
        let item = try XCTUnwrap(state.companionOutbox?.items.first)
        XCTAssertFalse(item.refused)
        XCTAssertTrue(state.error?.detail.hasPrefix(item.name + " was not sent: ") == true, state.error?.detail ?? "")

        fake.downHosts = [CompanionLink.address]
        await state.drainOutbox()

        XCTAssertEqual(state.companionOutbox?.items.first?.inSyncFolder, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.path), [SyncPackage.fileName(item.id)])
    }

    @MainActor
    func test_drainOutbox_unreachableWithoutAFolder_saysWhereToSetOneOnce() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(files: 1)
        try await pairWithSyncKey(state, with: fake)
        fake.downHosts = [CompanionLink.address]

        await state.sendJobToDesktop(from: "Aytu's iPhone")

        XCTAssertEqual(state.statusAccessible,
                       "Office PC cannot be reached on this network. Set a cloud folder in My computer to send when the computer cannot be reached.")
        XCTAssertEqual(state.companionOutboxCount, 1)

        await state.drainOutbox()
        XCTAssertEqual(state.statusAccessible, "Office PC cannot be reached on this network.")
        XCTAssertEqual(state.companionOutboxCount, 1)
    }

    @MainActor
    func test_drainOutbox_unreachable_saysHowManyFilesWentInTheSyncFolder() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(files: 1)
        try await pairWithSyncKey(state, with: fake)
        fake.downHosts = [CompanionLink.address]
        await state.sendJobToDesktop(from: "Aytu's iPhone")
        await state.sendJobToDesktop(from: "Aytu's iPhone")
        XCTAssertEqual(state.companionOutboxCount, 2)
        // A desktop that does not answer is no success: only a file that went somewhere is.
        XCTAssertNil(state.sentMessage)

        let cloud = folder.appendingPathComponent("iCloud Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        setSyncFolder(state, cloud)
        await state.drainOutbox()

        XCTAssertEqual(state.statusAccessible, "Put 2 files in the cloud folder for Office PC.")
        XCTAssertEqual(state.sentMessage, state.statusAccessible)
        XCTAssertEqual(state.companionInSyncFolderCount, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.path).count, 2)
    }

    @MainActor
    func test_sendThroughSyncFolder_aWriteThatFails_keepsTheFileForTheFolder() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(files: 1)
        try await pairWithSyncKey(state, with: fake)
        setSyncFolder(state, folder.appendingPathComponent("Not there", isDirectory: true))
        fake.downHosts = [CompanionLink.address]

        await state.sendJobToDesktop(from: "Aytu's iPhone")

        XCTAssertEqual(state.companionOutboxCount, 1)
        let item = try XCTUnwrap(state.companionOutbox?.items.first)
        XCTAssertTrue(item.viaSyncFolder)
        XCTAssertTrue(state.error?.detail.hasPrefix(item.name + " was not sent: ") == true, state.error?.detail ?? "")

        // The folder is there now: the next round puts it there without asking the desktop.
        let cloud = folder.appendingPathComponent("Not there")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        fake.downHosts = []
        let puts = fake.requests.filter { $0.method == "PUT" }.count
        await state.drainOutbox()

        XCTAssertEqual(state.companionOutboxCount, 1)
        XCTAssertEqual(fake.requests.filter { $0.method == "PUT" }.count, puts)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.path), [SyncPackage.fileName(item.id)])

        // Sent over the network after all: it leaves the outbox, and its file the folder.
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*") { request in
            self.created(String(request.path.dropFirst(CompanionProtocol.inboxPrefix.count)))
        }
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello())
        await state.drainOutbox()

        XCTAssertEqual(state.companionOutboxCount, 0)
        XCTAssertEqual(fake.requests.filter { $0.method == "PUT" }.count, puts + 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.path), [])
    }

    @MainActor
    func test_checkDesktop_withASyncFolder_saysTheFolderIsUsed() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pairWithSyncKey(state, with: fake)
        fake.downHosts = [CompanionLink.address]
        state.companionDesktopSeenOnNetwork = { _ in true }

        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .unreachable(reason: CompanionText.refusedReason))

        setSyncFolder(state, folder)
        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .unreachable(reason: CompanionText.refusedSyncFolderReason))

        state.companionDesktopSeenOnNetwork = { _ in false }
        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .unreachable(reason: "Office PC is not on this network."))
    }
}
