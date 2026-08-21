import ColorSync
import CoreGraphics
import Foundation

/// A display identifier intended to survive reconnects and reboots.
///
/// `CGDirectDisplayID` values belong to the current WindowServer session and can
/// be reused. ColorSync UUIDs are the system-provided persistent identity for a
/// physical display, so persisted recovery data must use them instead.
struct DisplayIdentity: Codable, Hashable, Sendable {
    let uuid: String
    let isBuiltin: Bool

    init(uuid: String, isBuiltin: Bool) {
        self.uuid = uuid.lowercased()
        self.isBuiltin = isBuiltin
    }

    init?(displayID: CGDirectDisplayID) {
        guard displayID != kCGNullDirectDisplay,
              let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID),
              let uuidString = CFUUIDCreateString(nil, unmanagedUUID.takeRetainedValue()) else {
            return nil
        }

        self.init(
            uuid: uuidString as String,
            isBuiltin: CGDisplayIsBuiltin(displayID) != 0
        )
    }

    var storageKey: String {
        "\(isBuiltin ? "builtin" : "external"):\(uuid)"
    }

    /// Resolves the persistent UUID to this WindowServer session's display ID
    /// and verifies that the ID still describes the same display type.
    func resolve() -> CGDirectDisplayID? {
        guard let cfUUID = CFUUIDCreateFromString(nil, uuid as CFString) else {
            return nil
        }

        let displayID = CGDisplayGetDisplayIDFromUUID(cfUUID)
        guard displayID != kCGNullDirectDisplay else {
            return nil
        }

        // When the display is online/active, verify that it matches this identity.
        // When the display is offline/disabled, CoreGraphics may return nil from
        // CGDisplayCreateUUIDFromDisplayID, so accept the resolved displayID.
        if let current = DisplayIdentity(displayID: displayID) {
            guard current == self else { return nil }
        }
        return displayID
    }

    func matches(_ displayID: CGDirectDisplayID) -> Bool {
        guard let current = DisplayIdentity(displayID: displayID) else {
            return false
        }
        return current == self
    }
}

struct PersistedDisplayRecord: Codable, Hashable, Sendable {
    let identity: DisplayIdentity
}
