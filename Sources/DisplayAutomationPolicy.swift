import Foundation

/// Pure policy decisions for display automation. Keeping these separate from
/// AppKit/private-API code makes the safety-critical transitions testable.
enum DisplayAutomationPolicy {
    static func shouldDisableAtStartup(
        autoMode: Bool,
        isInternalDisplayOff: Bool,
        externalDisplayCount: Int
    ) -> Bool {
        autoMode && !isInternalDisplayOff && externalDisplayCount > 0
    }

    static func shouldDisableAfterHardwareChange(
        autoMode: Bool,
        isInternalDisplayOff: Bool,
        previousExternalDisplayCount: Int,
        currentExternalDisplayCount: Int
    ) -> Bool {
        autoMode
            && !isInternalDisplayOff
            && previousExternalDisplayCount == 0
            && currentExternalDisplayCount > 0
    }

    static func shouldRestoreAfterWake(
        wasInternalDisplayOffBeforeSleep: Bool,
        externalDisplayCount: Int
    ) -> Bool {
        wasInternalDisplayOffBeforeSleep && externalDisplayCount > 0
    }

    static func shouldEnableInternalDisplayOnWake(
        wasInternalDisplayOffBeforeSleep: Bool,
        isInternalDisplayOff: Bool,
        externalDisplayCount: Int
    ) -> Bool {
        (wasInternalDisplayOffBeforeSleep || isInternalDisplayOff) && externalDisplayCount == 0
    }

    static func leavesAtLeastOneDisplayEnabled(_ targetStates: [Bool]) -> Bool {
        targetStates.contains(true)
    }
}
