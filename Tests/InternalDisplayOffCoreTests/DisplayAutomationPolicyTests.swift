import XCTest
@testable import InternalDisplayOffCore

final class DisplayAutomationPolicyTests: XCTestCase {
    func testStartupRequiresAutoModeAndAnExternalDisplay() {
        XCTAssertTrue(DisplayAutomationPolicy.shouldDisableAtStartup(
            autoMode: true,
            isInternalDisplayOff: false,
            externalDisplayCount: 1
        ))
        XCTAssertFalse(DisplayAutomationPolicy.shouldDisableAtStartup(
            autoMode: false,
            isInternalDisplayOff: false,
            externalDisplayCount: 1
        ))
        XCTAssertFalse(DisplayAutomationPolicy.shouldDisableAtStartup(
            autoMode: true,
            isInternalDisplayOff: false,
            externalDisplayCount: 0
        ))
        XCTAssertFalse(DisplayAutomationPolicy.shouldDisableAtStartup(
            autoMode: true,
            isInternalDisplayOff: true,
            externalDisplayCount: 1
        ))
    }

    func testHardwareAutomationOnlyRunsOnZeroToNonzeroTransition() {
        XCTAssertTrue(DisplayAutomationPolicy.shouldDisableAfterHardwareChange(
            autoMode: true,
            isInternalDisplayOff: false,
            previousExternalDisplayCount: 0,
            currentExternalDisplayCount: 1
        ))
        XCTAssertFalse(DisplayAutomationPolicy.shouldDisableAfterHardwareChange(
            autoMode: true,
            isInternalDisplayOff: false,
            previousExternalDisplayCount: 1,
            currentExternalDisplayCount: 2
        ))
        XCTAssertFalse(DisplayAutomationPolicy.shouldDisableAfterHardwareChange(
            autoMode: true,
            isInternalDisplayOff: true,
            previousExternalDisplayCount: 0,
            currentExternalDisplayCount: 1
        ))
    }

    func testWakeRestoreRequiresThePreviousStateAndAnExternalDisplay() {
        XCTAssertTrue(DisplayAutomationPolicy.shouldRestoreAfterWake(
            wasInternalDisplayOffBeforeSleep: true,
            externalDisplayCount: 1
        ))
        XCTAssertFalse(DisplayAutomationPolicy.shouldRestoreAfterWake(
            wasInternalDisplayOffBeforeSleep: true,
            externalDisplayCount: 0
        ))
        XCTAssertFalse(DisplayAutomationPolicy.shouldRestoreAfterWake(
            wasInternalDisplayOffBeforeSleep: false,
            externalDisplayCount: 1
        ))
    }

    func testWakeEnablesInternalDisplayWhenNoExternalDisplaysConnected() {
        XCTAssertTrue(DisplayAutomationPolicy.shouldEnableInternalDisplayOnWake(
            wasInternalDisplayOffBeforeSleep: true,
            isInternalDisplayOff: false,
            externalDisplayCount: 0
        ))
        XCTAssertTrue(DisplayAutomationPolicy.shouldEnableInternalDisplayOnWake(
            wasInternalDisplayOffBeforeSleep: false,
            isInternalDisplayOff: true,
            externalDisplayCount: 0
        ))
        XCTAssertFalse(DisplayAutomationPolicy.shouldEnableInternalDisplayOnWake(
            wasInternalDisplayOffBeforeSleep: true,
            isInternalDisplayOff: true,
            externalDisplayCount: 1
        ))
        XCTAssertFalse(DisplayAutomationPolicy.shouldEnableInternalDisplayOnWake(
            wasInternalDisplayOffBeforeSleep: false,
            isInternalDisplayOff: false,
            externalDisplayCount: 0
        ))
    }

    func testSceneMustLeaveAtLeastOneDisplayEnabled() {
        XCTAssertTrue(DisplayAutomationPolicy.leavesAtLeastOneDisplayEnabled([false, true]))
        XCTAssertFalse(DisplayAutomationPolicy.leavesAtLeastOneDisplayEnabled([false, false]))
        XCTAssertFalse(DisplayAutomationPolicy.leavesAtLeastOneDisplayEnabled([]))
    }
}
