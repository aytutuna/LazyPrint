#if os(iOS)
import UIKit
import XCTest
@testable import LazyPrintIOS

// The iPhone's background time for a print pass (`BackgroundActivity`). The tests pass their own begin, end and time
// left, so UIApplication is never asked; the time check is called by hand.

/// The system's side of the background tasks: hands out identifiers, records the ones ended, keeps the time left.
@MainActor
private final class FakeSystem {
    var grants = true
    var left: TimeInterval = 600
    private(set) var begun: [String] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private var expirations: [UIBackgroundTaskIdentifier: @MainActor () -> Void] = [:]

    func begin(_ name: String, _ expired: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        guard grants else { return .invalid }
        begun.append(name)
        let identifier = UIBackgroundTaskIdentifier(rawValue: begun.count)
        expirations[identifier] = expired
        return identifier
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
    }

    /// The system's own expiration of the task begun `number`th.
    func expire(_ number: Int) {
        expirations[UIBackgroundTaskIdentifier(rawValue: number)]?()
    }

    func activity() -> UIKitBackgroundActivity {
        UIKitBackgroundActivity(begin: { (name: String, expired: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier in
            self.begin(name, expired)
        }, end: { (identifier: UIBackgroundTaskIdentifier) in
            self.end(identifier)
        }, remaining: { () -> TimeInterval in
            self.left
        })
    }
}

/// How many times a handler ran.
private final class CallCount {
    var value = 0
}

final class UIKitBackgroundActivityTests: XCTestCase {
    @MainActor
    func test_beginAndEnd_giveTheTimeBack() {
        let system = FakeSystem()
        let activity = system.activity()
        let token = activity.beginActivity("Printing", expired: {})

        XCTAssertNotNil(token)
        XCTAssertEqual(system.begun, ["Printing"])
        XCTAssertEqual(activity.runningCount, 1)
        activity.endActivity(token ?? 0)
        XCTAssertEqual(system.ended.count, 1)
        XCTAssertEqual(activity.runningCount, 0)
    }

    @MainActor
    func test_noTimeFromTheSystem_givesNoToken() {
        let system = FakeSystem()
        system.grants = false
        let activity = system.activity()

        XCTAssertNil(activity.beginActivity("Printing", expired: {}))
        XCTAssertEqual(activity.runningCount, 0)
    }

    @MainActor
    func test_endingTwice_endsTheTaskOnce() {
        let system = FakeSystem()
        let activity = system.activity()
        let token = activity.beginActivity("Printing", expired: {}) ?? 0
        activity.endActivity(token)
        activity.endActivity(token)

        XCTAssertEqual(system.ended.count, 1)
    }

    @MainActor
    func test_theWorkIsToldToStopWhenTheTimeLeftIsDownToTheWindDown_andOnlyOnce() {
        let system = FakeSystem()
        let activity = system.activity()
        let stops = CallCount()
        _ = activity.beginActivity("Printing", expired: { stops.value += 1 })

        activity.checkRemaining()
        XCTAssertEqual(stops.value, 0)
        system.left = UIKitBackgroundActivity.windDownTime
        activity.checkRemaining()
        activity.checkRemaining()
        XCTAssertEqual(stops.value, 1)
        // The task stays until the work gives it back, so it can wind down.
        XCTAssertEqual(activity.runningCount, 1)
        XCTAssertEqual(system.ended.count, 0)
    }

    @MainActor
    func test_theSystemsOwnExpiration_stopsTheWorkAndEndsTheTaskAtOnce() {
        let system = FakeSystem()
        let activity = system.activity()
        let stops = CallCount()
        _ = activity.beginActivity("Printing", expired: { stops.value += 1 })

        system.expire(1)

        XCTAssertEqual(stops.value, 1)
        XCTAssertEqual(system.ended.count, 1)
        XCTAssertEqual(activity.runningCount, 0)
    }

    @MainActor
    func test_theSystemsExpirationAfterTheWindDown_doesNotStopTheWorkTwice() {
        let system = FakeSystem()
        let activity = system.activity()
        let stops = CallCount()
        _ = activity.beginActivity("Printing", expired: { stops.value += 1 })
        system.left = 5
        activity.checkRemaining()
        system.expire(1)

        XCTAssertEqual(stops.value, 1)
        XCTAssertEqual(system.ended.count, 1)
    }
}
#endif
