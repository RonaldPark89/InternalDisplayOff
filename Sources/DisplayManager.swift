import Foundation
import CoreGraphics
import AppKit
import OSLog

// MARK: - DisplayState

struct DisplayState: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let physicalSizeInches: Double
    let resolution: CGSize
    var frame: CGRect
    var isEnabled: Bool

    var sizeLabel: String {
        physicalSizeInches > 0 ? "\(Int(physicalSizeInches.rounded()))\"" : (isBuiltin ? "Built-in" : "Display")
    }
}

// MARK: - Private API Helper

private class PrivateAPI {
    typealias SLSConfigureDisplayEnabledFunc = @convention(c) (OpaquePointer?, CGDirectDisplayID, Int32) -> CGError

    static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static let ConfigureDisplayEnabled: SLSConfigureDisplayEnabledFunc? = {
        let names = ["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"]
        for name in names {
            if let sym = dlsym(skyLight, name) {
                logger.debug("Found private API: \(name)")
                return unsafeBitCast(sym, to: SLSConfigureDisplayEnabledFunc.self)
            }
        }
        return nil
    }()
}

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "InternalDisplayOff", category: "DisplayManager")

private func displayReconfigurationCallBack(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags, userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo = userInfo else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
    if flags.contains(.removeFlag) && !flags.contains(.beginConfigurationFlag) {
        manager.scheduleEmergencyChecks()
        DispatchQueue.main.async { manager.handleHardwareDisplayChange() }
    } else if flags.contains(.addFlag) && !flags.contains(.beginConfigurationFlag) {
        DispatchQueue.main.async {
            manager.handleHardwareDisplayChange()
            manager.scheduleOrphanedDisplayRecovery()
        }
    }
}

// MARK: - DisplayManager

class DisplayManager: ObservableObject {
    static let shared = DisplayManager()

    @Published var isInternalDisplayOff = UserDefaults.standard.bool(forKey: "IsInternalDisplayOff") {
        didSet {
            UserDefaults.standard.set(isInternalDisplayOff, forKey: "IsInternalDisplayOff")
            internalDisplayDisabledAt = isInternalDisplayOff ? Date() : nil
        }
    }
    @Published var autoMode = UserDefaults.standard.bool(forKey: "AutoMode") {
        didSet { UserDefaults.standard.set(autoMode, forKey: "AutoMode") }
    }
    @Published var displays: [DisplayState] = []
    @Published var externalDisplayCount = 0
    @Published var lastError: String? = nil

    private var cachedInternalDisplayID: CGDirectDisplayID?
    private var disabledDisplayCache: [CGDirectDisplayID: DisplayState] = [:]
    private var pendingDisabledIDs: Set<CGDirectDisplayID> = []
    private var lastKnownFrames: [CGDirectDisplayID: CGRect] = [:]
    private var fallbackTimer: DispatchSourceTimer?
    // Tracks external count as of the last hardware-change event (not polluted by
    // intermediate refreshes from didChangeScreenParametersNotification).
    private var lastHardwareExternalCount = 0
    // Saved before sleep so we can re-apply the setting after wake.
    private var wasInternalDisplayOffBeforeSleep = false
    // Retry bookkeeping for restoring the internal display. A restore attempt can
    // fail while the WindowServer is mid-reconfiguration (common when the last
    // external monitor is unplugged). We must keep retrying instead of dropping
    // the "off" flag, otherwise every safety net is disarmed.
    private var restoreAttempts = 0
    private var restoreRetryScheduled = false
    // When the built-in is disabled, some monitors briefly drop off the display
    // list while the WindowServer reconfigures. Do not treat that as "external
    // unplugged" until the reconfiguration has had time to settle.
    private var internalDisplayDisabledAt: Date?
    private let internalDisableSettleGrace: TimeInterval = 8.0
    private var pendingReDisableScheduled = false
    private var isInternalDisableSettling: Bool {
        guard let disabledAt = internalDisplayDisabledAt else { return false }
        return Date().timeIntervalSince(disabledAt) < internalDisableSettleGrace
    }

    private var backupFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".internal_display_backup_id")
    }

    // Persists external display IDs that we have disabled so they survive a crash/force-quit.
    // On next launch we immediately re-enable them before the user can interact.
    private let disabledExternalIDsKey = "DisabledExternalDisplayIDs"

    // Remembers that the user wanted the built-in display off. If the built-in is
    // temporarily restored because the last external monitor was unplugged, this
    // flag makes the app turn it back off automatically when a monitor returns.
    private let pendingInternalReDisableKey = "PendingInternalReDisable"
    private var pendingInternalReDisable: Bool {
        get { UserDefaults.standard.bool(forKey: pendingInternalReDisableKey) }
        set { UserDefaults.standard.set(newValue, forKey: pendingInternalReDisableKey) }
    }

    private func persistDisabledExternalIDs() {
        let ids = disabledDisplayCache.values
            .filter { !$0.isBuiltin }
            .map { Int($0.id) }
        UserDefaults.standard.set(ids, forKey: disabledExternalIDsKey)
    }

    private func restorePersistedExternalDisplays() {
        guard let ids = UserDefaults.standard.array(forKey: disabledExternalIDsKey) as? [Int],
              !ids.isEmpty else { return }

        logger.info("Restoring \(ids.count) persisted disabled external display(s) from previous session.")

        // Restore each display in its own transaction. One display may no longer be
        // attached (its ID is stale); batching them would make that single failure
        // prevent every other monitor from coming back up.
        var stillDisabled: [Int] = []
        for idInt in ids {
            let displayID = CGDirectDisplayID(idInt)
            let result = applyDisplayChanges([(displayID, true)])
            if result != .success {
                stillDisabled.append(idInt)
                logger.error("Failed to restore persisted external display \(displayID) (CGError \(result.rawValue)).")
            }
        }

        if stillDisabled.isEmpty {
            UserDefaults.standard.removeObject(forKey: disabledExternalIDsKey)
            logger.info("Restored persisted external display(s).")
        } else {
            // Keep only the IDs that still need restoring.
            UserDefaults.standard.set(stillDisabled, forKey: disabledExternalIDsKey)
        }
    }

    private func saveDisplayIDToDisk(_ displayID: CGDirectDisplayID) {
        try? String(displayID).write(to: backupFileURL, atomically: true, encoding: .utf8)
    }

    private func loadDisplayIDFromDisk() -> CGDirectDisplayID? {
        guard let s = try? String(contentsOf: backupFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let id = UInt32(s) else { return nil }
        return CGDirectDisplayID(id)
    }

    private init() {
        if let id = loadDisplayIDFromDisk() {
            cachedInternalDisplayID = id
        } else if let backup = UserDefaults.standard.object(forKey: "BackupInternalDisplayID") as? Int {
            cachedInternalDisplayID = CGDirectDisplayID(backup)
        }

        // Migration: if internal was previously disabled, pre-populate cache so it
        // appears in the displays array with isEnabled=false on first refresh.
        if isInternalDisplayOff, let id = cachedInternalDisplayID {
            disabledDisplayCache[id] = DisplayState(
                id: id, name: "Built-in Display", isBuiltin: true,
                physicalSizeInches: 0, resolution: .zero, frame: .zero, isEnabled: false
            )
        }

        // Recover any external displays that were left disabled by a previous session
        // (crash, force-quit, etc.). SLSConfigureDisplayEnabled(0) fully removes the
        // display from the system; persisting the ID is the only way to restore it.
        restorePersistedExternalDisplays()

        refreshDisplayInfo()
        setupObservers()
        startFallbackTimer()

        // If the app was force-quit while the built-in was off (or restored during
        // an unplug) and an external is connected now, re-apply the remembered state.
        schedulePendingReDisable(after: 3.0)
    }

    private func startFallbackTimer() {
        let queue = DispatchQueue.global(qos: .background)
        fallbackTimer = DispatchSource.makeTimerSource(queue: queue)
        // 10s interval — this is only a safety net for when the internal display
        // is already off. No need to wake the CPU every 2s while idle.
        fallbackTimer?.schedule(deadline: .now() + 10.0, repeating: 10.0)
        fallbackTimer?.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isInternalDisplayOff else { return }
                self.performEmergencyCheck()
            }
        }
        fallbackTimer?.resume()
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenParametersChange()
        }

        // Save state before sleep; macOS re-enables all displays on wake, which
        // causes refreshDisplayInfo() to clear isInternalDisplayOff. We use the
        // saved flag to re-apply the user's setting after the wake settles.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.wasInternalDisplayOffBeforeSleep = self?.isInternalDisplayOff ?? false
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleWakeFromSleep()
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallBack, userInfo)
    }

    private func handleWakeFromSleep() {
        // Also covers the case where the display was restored while unused and the
        // user's "built-in off" intent still applies.
        schedulePendingReDisable(after: 3.0)
        guard wasInternalDisplayOffBeforeSleep else { return }
        wasInternalDisplayOffBeforeSleep = false
        reapplyInternalDisplayOffAfterWake(attempt: 0)
    }

    private func reapplyInternalDisplayOffAfterWake(attempt: Int) {
        let maxAttempts = 5
        guard attempt < maxAttempts else {
            logger.error("Wake from sleep: could not re-apply internal display off setting.")
            return
        }

        // Give macOS time to finish reconfiguring displays after wake before
        // we re-disable the internal display.
        let delay: TimeInterval = attempt == 0 ? 2.0 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isInternalDisplayOff else { return }
            guard self.externalDisplayCount > 0 else {
                // The display list can still be settling; try again shortly.
                self.reapplyInternalDisplayOffAfterWake(attempt: attempt + 1)
                return
            }
            logger.info("Wake from sleep: re-applying internal display off setting.")
            self.disableInternalDisplay()
            // Verify on the next tick; this is a no-op if the disable succeeded.
            self.reapplyInternalDisplayOffAfterWake(attempt: attempt + 1)
        }
    }

    /// Re-applies the remembered "built-in off" state after it was temporarily
    /// restored because the last external monitor was unplugged. Retries briefly
    /// while the WindowServer settles the newly connected monitor.
    private func schedulePendingReDisable(after delay: TimeInterval = 2.0, attempt: Int = 0) {
        guard pendingInternalReDisable else { return }
        // Display-list churn fires many refresh/reconfiguration callbacks. Coalesce
        // them into one pending disable; otherwise a replug can issue several
        // configuration transactions at once and knock both panels out.
        guard !pendingReDisableScheduled else { return }
        guard attempt < 5 else {
            logger.error("Could not re-apply remembered internal display off state.")
            return
        }

        pendingReDisableScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.pendingReDisableScheduled = false

            guard self.pendingInternalReDisable, !self.isInternalDisplayOff else { return }
            guard self.externalDisplayCount > 0 else { return }

            logger.info("External display available: re-applying remembered internal display off state.")
            self.disableInternalDisplay()
            // Verify on the next tick; a successful disable makes this a no-op.
            self.schedulePendingReDisable(after: 1.0, attempt: attempt + 1)
        }
    }

    func cleanup() {
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallBack, userInfo)
    }

    func handleHardwareDisplayChange() {
        logger.info("Hardware display reconfiguration detected.")
        let snapshot = lastHardwareExternalCount
        refreshDisplayInfo {
            defer { self.lastHardwareExternalCount = self.externalDisplayCount }
            let wantsInternalOff = self.autoMode || self.pendingInternalReDisable
            guard wantsInternalOff && !self.isInternalDisplayOff
                  && self.externalDisplayCount > 0 else { return }

            if self.pendingInternalReDisable {
                // The built-in was restored while the last monitor was unplugged.
                // Re-apply the remembered state now that a monitor is back.
                self.schedulePendingReDisable(after: 2.0)
                return
            }

            // Auto mode only reacts to the 0 → 1 external transition.
            guard snapshot == 0 else { return }

            // Delay so macOS fully settles the external monitor before we disable the
            // internal display. Without this, NSScreen.screens is still in flux:
            // disabledDisplayCache gets a zero-frame fallback entry and a second
            // reconfiguration event can evict it, leaving the display untracked.
            logger.info("Auto mode: external connected, scheduling internal disable in 2s.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                // Re-check — user may have manually re-enabled or disconnected by now
                guard self.autoMode && !self.isInternalDisplayOff
                      && self.externalDisplayCount > 0 else {
                    logger.info("Auto mode: conditions changed, skipping disable.")
                    return
                }
                logger.info("Auto mode: disabling internal display.")
                self.disableInternalDisplay()
            }
        }
    }

    private func handleScreenParametersChange() {
        logger.debug("Screen parameters changed.")
        refreshDisplayInfo()
    }

    // MARK: - Helpers

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private func sizeInInches(_ displayID: CGDirectDisplayID) -> Double {
        let size = CGDisplayScreenSize(displayID)
        guard size.width > 0, size.height > 0 else { return 0 }
        return sqrt(size.width * size.width + size.height * size.height) / 25.4
    }

    // Applies multiple enable/disable changes in one display configuration session.
    private func configureDisplays(_ changes: [(CGDirectDisplayID, Bool)]) -> CGError {
        // macOS fires one reconfiguration event per disabled display, not one per
        // transaction. Without tracking, refreshDisplayInfo() sees a display that is
        // "still in NSScreen.screens" during an intermediate event and evicts it from
        // disabledDisplayCache, making it unrestorable. Guard against this by holding
        // the IDs until the notification flurry settles.
        let disablingIDs = changes.filter { !$0.1 }.map { $0.0 }
        pendingDisabledIDs.formUnion(disablingIDs)

        let result = applyDisplayChanges(changes)
        guard result == .success else {
            pendingDisabledIDs.subtract(disablingIDs)
            return result
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.pendingDisabledIDs.subtract(disablingIDs)
            self.refreshDisplayInfo()
        }

        return result
    }

    /// Applies display changes in one transaction and verifies that the requested
    /// state actually took effect. `CGCompleteDisplayConfiguration` can return
    /// `kCGErrorIllegalArgument` (1001) even when the change succeeded — notably
    /// when enabling an already-enabled display, and with some monitors during a
    /// reconfiguration — so the observed display state is the source of truth.
    private func applyDisplayChanges(_ changes: [(CGDirectDisplayID, Bool)]) -> CGError {
        guard let configEnabled = PrivateAPI.ConfigureDisplayEnabled else { return .failure }

        var configRef: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&configRef)
        guard result == .success else { return result }

        for (id, enabled) in changes {
            result = configEnabled(configRef, id, enabled ? 1 : 0)
            if result != .success {
                CGCancelDisplayConfiguration(configRef)
                return result
            }
        }

        result = CGCompleteDisplayConfiguration(configRef, .forSession)
        if result == .success { return .success }

        // Treat the transaction as successful when the display list already
        // matches the requested state. Give the WindowServer a moment to finish
        // the reconfiguration before deciding it really failed.
        if configurationMatches(changes) { return .success }
        usleep(250_000)
        if configurationMatches(changes) { return .success }
        return result
    }

    private func configurationMatches(_ changes: [(CGDirectDisplayID, Bool)]) -> Bool {
        changes.allSatisfy { (id, enabled) in
            (CGDisplayIsActive(id) != 0) == enabled
        }
    }

    // MARK: - Multi-Display Operations

    func toggle(_ id: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == id }) else { return }

        if display.isEnabled {
            // Prevent turning off the last enabled display
            guard displays.filter({ $0.isEnabled }).count > 1 else { return }
            // Route internal display through its existing method (has extra checks)
            if display.isBuiltin { disableInternalDisplay(); return }
            disabledDisplayCache[id] = display
        } else {
            if display.isBuiltin { enableInternalDisplay(); return }
            disabledDisplayCache.removeValue(forKey: id)
        }

        let newEnabled = !display.isEnabled
        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)
        let result = configureDisplays([(id, newEnabled)])

        if result == .success {
            if newEnabled {
                disabledDisplayCache.removeValue(forKey: id)
            }
            persistDisabledExternalIDs()
            if newEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshDisplayInfo() }
            }
            ToastManager.shared.showToast(message: newEnabled ? "\(display.name) Enabled" : "\(display.name) Disabled")
        } else {
            // Undo cache change
            if newEnabled { disabledDisplayCache[id] = display } else { disabledDisplayCache.removeValue(forKey: id) }
            persistDisabledExternalIDs()
            DispatchQueue.main.async { self.lastError = "Failed to toggle display (Error: \(result.rawValue))" }
        }
    }

    func solo(_ id: CGDirectDisplayID) {
        // Soloing the built-in is an explicit request to keep it on.
        if cachedInternalDisplayID == id {
            pendingInternalReDisable = false
        }
        // Snapshot before mutating so a failed transaction does not wipe the
        // records of displays that were already disabled before this call.
        let cacheBefore = disabledDisplayCache
        for d in displays where d.id != id {
            disabledDisplayCache[d.id] = d
        }
        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)

        // Only include displays whose state actually needs to change.
        // Calling SLSConfigureDisplayEnabled on an already-disabled display
        // returns an error that fails the entire configuration transaction.
        let changes = displays.compactMap { d -> (CGDirectDisplayID, Bool)? in
            let target = (d.id == id)
            return d.isEnabled != target ? (d.id, target) : nil
        }
        guard !changes.isEmpty else {
            let name = displays.first(where: { $0.id == id })?.name ?? "Display"
            ToastManager.shared.showToast(message: "Only \(name) on")
            return
        }
        let result = configureDisplays(changes)

        if result == .success {
            disabledDisplayCache.removeValue(forKey: id)
            persistDisabledExternalIDs()
            let isInternal = cachedInternalDisplayID == id
            // Solo on an external means the built-in should stay off when that
            // monitor is unplugged and plugged back in.
            pendingInternalReDisable = !isInternal
            updateInternalDisplayOff(!isInternal)
            let name = displays.first(where: { $0.id == id })?.name ?? "Display"
            ToastManager.shared.showToast(message: "Only \(name) on")
        } else {
            disabledDisplayCache = cacheBefore
            persistDisabledExternalIDs()
            DispatchQueue.main.async { self.lastError = "Failed to solo display" }
        }
    }

    func enableAll() {
        // Explicit user request to turn everything on; drop the remembered
        // "keep the built-in off" intent.
        pendingInternalReDisable = false
        let disabled = displays.filter { !$0.isEnabled }
        guard !disabled.isEmpty else {
            ToastManager.shared.showToast(message: "All displays on")
            return
        }
        for d in disabled { disabledDisplayCache.removeValue(forKey: d.id) }
        persistDisabledExternalIDs()
        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)

        let result = configureDisplays(disabled.map { ($0.id, true) })

        if result == .success {
            updateInternalDisplayOff(false)
            ToastManager.shared.showToast(message: "All displays on")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshDisplayInfo() }
        } else {
            for d in disabled { disabledDisplayCache[d.id] = d }
            persistDisabledExternalIDs()
            DispatchQueue.main.async { self.lastError = "Failed to enable all displays" }
        }
    }

    // state keys are String(CGDirectDisplayID)
    func applySceneState(_ state: [String: Bool], sceneName: String) {
        var changes: [(CGDirectDisplayID, Bool)] = []
        for display in displays {
            guard let targetEnabled = state[String(display.id)] else { continue }
            if targetEnabled != display.isEnabled {
                changes.append((display.id, targetEnabled))
                if !targetEnabled { disabledDisplayCache[display.id] = display }
                else { disabledDisplayCache.removeValue(forKey: display.id) }
            }
        }
        persistDisabledExternalIDs()

        // Record the user's intent for the built-in as soon as the scene is
        // applied, so a later replug honours it even if the transaction fails.
        if let internal_ = displays.first(where: { $0.isBuiltin }),
           let targetEnabled = state[String(internal_.id)] {
            pendingInternalReDisable = !targetEnabled
        }

        guard !changes.isEmpty else {
            ToastManager.shared.showToast(message: "Applied: \(sceneName)")
            return
        }

        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)
        let result = configureDisplays(changes)

        if result == .success {
            if let internal_ = displays.first(where: { $0.isBuiltin }),
               let targetEnabled = state[String(internal_.id)] {
                updateInternalDisplayOff(!targetEnabled)
            }
            ToastManager.shared.showToast(message: "Applied: \(sceneName)")
            let hasEnables = changes.contains { $0.1 }
            if hasEnables {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshDisplayInfo() }
            }
        } else {
            for (id, enabled) in changes {
                if !enabled { disabledDisplayCache.removeValue(forKey: id) }
                else if let d = displays.first(where: { $0.id == id }) { disabledDisplayCache[d.id] = d }
            }
            persistDisabledExternalIDs()
            DispatchQueue.main.async { self.lastError = "Failed to apply scene" }
        }
    }

    // MARK: - Refresh

    func refreshDisplayInfo(completion: (() -> Void)? = nil) {
        let screens = NSScreen.screens
        var enabledDisplays: [DisplayState] = []
        var seenIDs = Set<CGDirectDisplayID>()
        var foundInternalID: CGDirectDisplayID?

        for screen in screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  !seenIDs.contains(displayID) else { continue }
            seenIDs.insert(displayID)

            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
            let name = screen.localizedName.trimmingCharacters(in: .whitespaces)
            if !isBuiltin && name.isEmpty {
                logger.debug("Ignoring ghost display: ID=\(displayID)")
                continue
            }

            if isBuiltin { foundInternalID = displayID }

            let inches = sizeInInches(displayID)
            let displayName = !name.isEmpty ? name : (inches > 0 ? "\(Int(inches.rounded()))\" Display" : "External Display")

            let state = DisplayState(
                id: displayID, name: displayName, isBuiltin: isBuiltin,
                physicalSizeInches: inches,
                resolution: CGSize(width: screen.frame.width, height: screen.frame.height),
                frame: screen.frame, isEnabled: true
            )
            enabledDisplays.append(state)
            if !pendingDisabledIDs.contains(displayID) {
                disabledDisplayCache.removeValue(forKey: displayID)
            }
        }

        // When the primary display changes (e.g. external disabled → internal becomes main),
        // macOS shifts the coordinate origin to the new primary. Cached frames for disabled
        // displays are still in the old coordinate system, causing them to overlap with the
        // enabled display in the spatial map. Detect the shift and adjust cached frames.
        if let newPrimary = enabledDisplays.first(where: { $0.frame.origin == .zero }),
           let oldFrame = lastKnownFrames[newPrimary.id],
           oldFrame.origin != .zero,
           !disabledDisplayCache.isEmpty {
            let shiftX = oldFrame.minX
            let shiftY = oldFrame.minY
            for id in Array(disabledDisplayCache.keys) {
                disabledDisplayCache[id]?.frame.origin.x -= shiftX
                disabledDisplayCache[id]?.frame.origin.y -= shiftY
            }
        }
        for d in enabledDisplays { lastKnownFrames[d.id] = d.frame }

        let enabledIDs = Set(enabledDisplays.map { $0.id })
        var allDisplays = enabledDisplays
        for var cached in disabledDisplayCache.values {
            guard !enabledIDs.contains(cached.id) else { continue }
            cached.isEnabled = false
            allDisplays.append(cached)
        }
        allDisplays.sort { a, b in
            if a.isBuiltin != b.isBuiltin { return a.isBuiltin }
            return a.physicalSizeInches > b.physicalSizeInches
        }

        let validExternals = enabledDisplays.filter { !$0.isBuiltin }.count

        DispatchQueue.main.async {
            self.displays = allDisplays
            self.externalDisplayCount = validExternals

            if validExternals > 0 && self.lastError == "No external display detected." {
                self.lastError = nil
            }

            if let id = foundInternalID {
                if self.cachedInternalDisplayID != id {
                    self.cachedInternalDisplayID = id
                    UserDefaults.standard.set(Int(id), forKey: "BackupInternalDisplayID")
                    self.saveDisplayIDToDisk(id)
                }
                if self.isInternalDisplayOff {
                    self.isInternalDisplayOff = false
                }
            }

            if self.isInternalDisplayOff && validExternals == 0 {
                self.performEmergencyCheck()
            }

            // Safety net: if we believe the internal display is disabled but it has
            // no entry in displays (cache miss), re-add a placeholder so the UI
            // can still show it and "All On" / enableInternalDisplay can restore it.
            if self.isInternalDisplayOff,
               let internalID = self.cachedInternalDisplayID,
               !self.displays.contains(where: { $0.id == internalID }) {
                let placeholder = DisplayState(
                    id: internalID, name: "Built-in Display", isBuiltin: true,
                    physicalSizeInches: 0, resolution: .zero, frame: .zero, isEnabled: false
                )
                self.disabledDisplayCache[internalID] = placeholder
                self.displays.append(placeholder)
            }

            // If the built-in was temporarily restored during an unplug, re-apply
            // the remembered off state as soon as an external is usable again.
            if self.pendingInternalReDisable,
               self.externalDisplayCount > 0,
               !self.isInternalDisplayOff {
                self.schedulePendingReDisable()
            }
            completion?()
        }
    }

    // MARK: - Internal Display (legacy path, also used by ⌃⌘D hotkey)

    func getInternalDisplayID() -> CGDirectDisplayID? {
        if let cached = cachedInternalDisplayID { return cached }
        if let id = loadDisplayIDFromDisk() { cachedInternalDisplayID = id; return id }
        if let backup = UserDefaults.standard.object(forKey: "BackupInternalDisplayID") as? Int {
            cachedInternalDisplayID = CGDirectDisplayID(backup); return cachedInternalDisplayID
        }
        refreshDisplayInfo()
        return cachedInternalDisplayID
    }

    func toggleInternalDisplay() {
        isInternalDisplayOff ? enableInternalDisplay() : disableInternalDisplay()
    }

    func disableInternalDisplay() {
        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)
        // Do NOT call refreshDisplayInfo() here: the async state update it queues would
        // overwrite displays with a stale snapshot that shows the internal as enabled,
        // racing with the success handler. externalDisplayCount is already current from
        // the last screen-change notification.

        guard externalDisplayCount > 0 else {
            lastError = "No external display detected."
            return
        }
        guard let displayID = getInternalDisplayID() else {
            lastError = "Could not find internal display ID."
            return
        }

        // Always rebuild the cache entry from the freshest source so that the spatial
        // map thumbnail has correct frame/size data after disabling.
        // Prefer a live NSScreen lookup, then the displays array, then a zero fallback.
        let cacheState: DisplayState
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) {
            let inches = sizeInInches(displayID)
            let name = screen.localizedName.trimmingCharacters(in: .whitespaces)
            cacheState = DisplayState(
                id: displayID,
                name: name.isEmpty ? "Built-in Display" : name,
                isBuiltin: true,
                physicalSizeInches: inches,
                resolution: CGSize(width: screen.frame.width, height: screen.frame.height),
                frame: screen.frame,
                isEnabled: true
            )
        } else if let existing = displays.first(where: { $0.id == displayID }) {
            cacheState = existing
        } else {
            cacheState = DisplayState(id: displayID, name: "Built-in Display", isBuiltin: true,
                                      physicalSizeInches: 0, resolution: .zero, frame: .zero, isEnabled: true)
        }
        disabledDisplayCache[displayID] = cacheState

        logger.info("Disabling internal display \(displayID)")
        let result = applyDisplayChanges([(displayID, false)])

        if result == .success {
            pendingInternalReDisable = true
            updateInternalDisplayOff(true)
            lastError = nil
            ToastManager.shared.showToast(message: "Internal Display Disabled")
        } else {
            disabledDisplayCache.removeValue(forKey: displayID)
            let errStr = "Failed to disable (Error: \(result.rawValue))"
            DispatchQueue.main.async { self.lastError = errStr }
            logger.error("Failed to disable display: \(result.rawValue)")
        }
    }

    func enableInternalDisplay() {
        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)
        // The user explicitly asked for the built-in to be on; forget any
        // remembered "turn it off when an external returns" intent.
        pendingInternalReDisable = false
        guard let displayID = getInternalDisplayID() else {
            lastError = "Internal display ID lost."
            return
        }

        logger.info("Enabling internal display \(displayID)")
        let result = applyDisplayChanges([(displayID, true)])

        if result == .success {
            disabledDisplayCache.removeValue(forKey: displayID)
            updateInternalDisplayOff(false)
            lastError = nil
            ToastManager.shared.showToast(message: "Internal Display Enabled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.refreshDisplayInfo() }
        } else {
            let errStr = "Failed to enable (Error: \(result.rawValue))"
            DispatchQueue.main.async { self.lastError = errStr }
            logger.error("Failed to enable display: \(result.rawValue)")
        }
    }

    /// Best-effort restore of the built-in display.
    ///
    /// Returns true only when the display configuration transaction actually
    /// completed. On failure `isInternalDisplayOff` deliberately stays set: that
    /// flag arms every safety net (reconfiguration callback, refresh emergency
    /// branch and the watchdog timer). Clearing it after a single failed attempt
    /// — common while the WindowServer is mid-reconfiguration after unplugging the
    /// last external monitor — used to leave both screens black permanently.
    @discardableResult
    func forceEnableFromBackup(scheduleRetry: Bool = true, preserveIntent: Bool = true) -> Bool {
        guard let displayID = getInternalDisplayID() else {
            logger.error("No backed-up internal display ID to restore.")
            return false
        }

        if preserveIntent && isInternalDisplayOff {
            // The built-in is being restored because the last external went away.
            // Remember that the user still wants it off once a monitor returns.
            pendingInternalReDisable = true
        }

        let result = applyDisplayChanges([(displayID, true)])

        guard result == .success else {
            restoreAttempts += 1
            logger.error("Failed to restore internal display \(displayID) (attempt \(self.restoreAttempts), CGError \(result.rawValue)).")
            if scheduleRetry { scheduleRestoreRetry() }
            return false
        }

        restoreAttempts = 0
        restoreRetryScheduled = false
        disabledDisplayCache.removeValue(forKey: displayID)
        updateInternalDisplayOff(false)
        logger.info("Internal display \(displayID) restored.")

        // A monitor can come back while the restore transaction was in flight.
        // If so, honour the remembered intent and turn the built-in off again.
        if preserveIntent && pendingInternalReDisable {
            schedulePendingReDisable(after: 1.0)
        }
        return true
    }

    private func updateInternalDisplayOff(_ off: Bool) {
        if Thread.isMainThread {
            isInternalDisplayOff = off
        } else {
            DispatchQueue.main.async { self.isInternalDisplayOff = off }
        }
    }

    private func scheduleRestoreRetry() {
        guard !restoreRetryScheduled else { return }
        restoreRetryScheduled = true

        // 0.5s, 1s, 2s, then every 4s. While this state persists the Mac has no
        // usable screen, so retrying indefinitely is better than giving up.
        let delay = min(pow(2.0, Double(max(0, restoreAttempts - 1))) * 0.5, 4.0)
        logger.info("Scheduling internal display restore retry in \(delay)s.")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.restoreRetryScheduled = false
            guard self.isInternalDisplayOff else { return }
            _ = self.forceEnableFromBackup()
        }
    }

    func forceEnableAll() {
        // Quitting is an explicit request to leave every display usable; drop any
        // remembered "built-in off" intent.
        pendingInternalReDisable = false

        // `applicationWillTerminate` cannot rely on the async retry loop, so make
        // a few synchronous attempts before the process exits.
        var restoredInternal = false
        for _ in 0..<3 {
            if forceEnableFromBackup(scheduleRetry: false, preserveIntent: false) {
                restoredInternal = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let disabled = disabledDisplayCache.values.filter { !$0.isBuiltin }
        var restoredExternals = true
        if !disabled.isEmpty {
            let result = configureDisplays(disabled.map { ($0.id, true) })
            if result == .success {
                for d in disabled { disabledDisplayCache.removeValue(forKey: d.id) }
            } else {
                restoredExternals = false
            }
        }

        // Keep the persisted IDs when anything failed so the next launch can
        // finish the job instead of orphaning the display.
        if restoredInternal && restoredExternals {
            UserDefaults.standard.removeObject(forKey: disabledExternalIDsKey)
        } else {
            persistDisabledExternalIDs()
            logger.error("Could not restore every display while terminating.")
        }
    }

    // MARK: - Orphaned displays

    /// A hot-plug can leave a display online at the WindowServer level but not
    /// active (and therefore missing from NSScreen). If we did not disable it
    /// ourselves it is safe to bring it back up; otherwise the monitor stays dark
    /// and the popover offers no way to restore it.
    func scheduleOrphanedDisplayRecovery() {
        // Give the WindowServer time to finish the hot-plug handshake.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.recoverOrphanedExternalDisplays()
        }
    }

    private func recoverOrphanedExternalDisplays() {
        // While the built-in is off its restoration is the priority, and touching
        // the display configuration concurrently would add another failure mode.
        guard !isInternalDisplayOff else { return }

        let activeIDs = Set(NSScreen.screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        })
        let orphans = onlineDisplayIDs().filter { id in
            CGDisplayIsBuiltin(id) == 0 &&
            !activeIDs.contains(id) &&
            disabledDisplayCache[id] == nil &&
            // Do not break a mirror set that macOS is intentionally maintaining.
            CGDisplayIsInMirrorSet(id) == 0
        }
        guard !orphans.isEmpty else { return }

        logger.warning("Recovering online external display(s) missing from NSScreen: \(orphans.map { String($0) }.joined(separator: ", ")).")
        let result = configureDisplays(orphans.map { ($0, true) })
        if result == .success {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refreshDisplayInfo()
            }
        } else {
            logger.error("Could not recover orphaned external display(s) (CGError \(result.rawValue)).")
        }
    }

    // MARK: - Emergency

    /// Run the emergency check immediately and a few more times while the
    /// WindowServer finishes removing the display. NSScreen/CoreGraphics can lag
    /// behind the physical unplug, and the internal display must come back as
    /// soon as there is no usable external screen left.
    func scheduleEmergencyChecks() {
        emergencyHardwareCheck()
        for delay in [0.5, 1.5, 3.0, 9.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.performEmergencyCheck()
            }
        }
    }

    func emergencyHardwareCheck() {
        DispatchQueue.main.async { self.performEmergencyCheck() }
    }

    private func activeExternalCount() -> Int {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return 0 }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return 0 }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }

    private func performEmergencyCheck() {
        guard isInternalDisplayOff else { return }

        // A monitor that briefly drops off the display list while the built-in is
        // being disabled is not an unplug. Wait for the reconfiguration to settle
        // before restoring the built-in, otherwise slow-syncing monitors (some
        // ultrawides) can end up with both panels dark.
        if isInternalDisableSettling {
            logger.info("Emergency check: waiting for displays to settle after disabling the built-in.")
            return
        }

        // Use the CoreGraphics active-display list instead of NSScreen: it is the
        // authoritative "is anything actually drawable?" source. An external that
        // is merely online but inactive cannot be used, so it does not count.
        if activeExternalCount() == 0 {
            logger.warning("Emergency check: no usable external display. Restoring internal display.")
            ToastManager.shared.showToast(message: "Internal Display Restored")
            forceEnableFromBackup()
        }
    }
}
