import Foundation
import XCTest
import WaidCore

/// The idle threshold is a setting you can see and change (GLOSSARY.md: Present).
final class SettingsTests: XCTestCase {
    var store: Store!

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
    }

    func testTheIdleThresholdIsThreeMinutesUntilChanged() throws {
        XCTAssertEqual(try store.idleThreshold(), 180)
        try store.setIdleThreshold(300)
        XCTAssertEqual(try store.idleThreshold(), 300)
        try store.setIdleThreshold(0)
        XCTAssertEqual(try store.idleThreshold(), 0, "zero is allowed: no pause counts as present")
        try store.setIdleThreshold(86_400)
        XCTAssertEqual(try store.idleThreshold(), 86_400, "a full day is allowed")
    }

    func testAnIdleThresholdBelowZeroOrAboveADayIsRejectedNamingTheLimit() throws {
        try store.setIdleThreshold(300)
        XCTAssertThrowsError(try store.setIdleThreshold(-1)) { error in
            XCTAssertTrue("\(error)".contains("0"), "\(error)")
        }
        XCTAssertThrowsError(try store.setIdleThreshold(86_401)) { error in
            XCTAssertTrue("\(error)".contains("86400"), "\(error)")
        }
        XCTAssertEqual(try store.idleThreshold(), 300, "a rejected value changes nothing")
    }
}

/// `waid settings idle-threshold [seconds]`, without the process around it.
final class SettingsCommandTests: XCTestCase {
    var store: Store!

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
    }

    func run(_ args: String...) throws -> String { try SettingsCommand.run(args, store: store) }

    func message(_ args: String...) -> String {
        do { _ = try SettingsCommand.run(args, store: store); return "no error" } catch { return "\(error)" }
    }

    func testWithNoValueItPrintsTheCurrentThreshold() throws {
        XCTAssertEqual(try run("idle-threshold"), "180")
    }

    func testWithAValueItChangesTheThreshold() throws {
        XCTAssertEqual(try run("idle-threshold", "300"), "idle threshold set to 300 seconds")
        XCTAssertEqual(try run("idle-threshold"), "300")
        XCTAssertEqual(try store.idleThreshold(), 300)
    }

    func testOutOfRangeOrMalformedValuesAreRejected() throws {
        XCTAssertTrue(message("idle-threshold", "-1").contains("below 0"))
        XCTAssertTrue(message("idle-threshold", "86401").contains("86400"))
        XCTAssertTrue(message("idle-threshold", "5m").contains("whole number of seconds"))
        XCTAssertTrue(message("idle-threshold", "1", "2").contains("usage"))
        XCTAssertTrue(message().contains("usage"))
        XCTAssertTrue(message("colour").contains("unknown setting \"colour\""))
        XCTAssertEqual(try store.idleThreshold(), 180, "nothing changed")
    }
}
