@preconcurrency import AppKit
@preconcurrency import CoreGraphics
import Foundation
import OSLog

// MARK: - DisplayState

struct DisplayState: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let identity: DisplayIdentity?
    let name: String
    let isBuiltin: Bool
    let physicalSizeInches: Double
    let resolution: CGSize
    var frame: CGRect
    var isEnabled: Bool
    // True when the display is enabled but mirroring another one. Mirrored
    // displays are absent from NSScreen.screens, so they must be discovered
    // through the CoreGraphics online list instead.
    var isMirrored: Bool = false

    var sizeLabel: String {
        physicalSizeInches > 0 ? "\(Int(physicalSizeInches.rounded()))\"" : (isBuiltin ? "Built-in" : "Display")
    }

    var persistenceKey: String {
        identity?.storageKey ?? "session:\(id)"
    }
}

// MARK: - Private API Helper

@MainActor
private enum PrivateAPI {
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

private func displayReconfigurationCallBack(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    let isFinalRemoval = flags.contains(.removeFlag) && !flags.contains(.beginConfigurationFlag)
    let isFinalAddition = flags.contains(.addFlag) && !flags.contains(.beginConfigurationFlag)
    guard isFinalRemoval || isFinalAddition else { return }

    Task { @MainActor in
        let manager = DisplayManager.shared
        if isFinalRemoval {
            manager.emergencyHardwareCheck()
        }
        manager.handleHardwareDisplayChange()
    }
}

// MARK: - DisplayManager

@MainActor
final class DisplayManager: ObservableObject {
    static let shared = DisplayManager()

    @Published var isInternalDisplayOff = UserDefaults.standard.bool(forKey: "IsInternalDisplayOff") {
        didSet { UserDefaults.standard.set(isInternalDisplayOff, forKey: "IsInternalDisplayOff") }
    }
    @Published var autoMode = UserDefaults.standard.bool(forKey: "AutoMode") {
        didSet {
            UserDefaults.standard.set(autoMode, forKey: "AutoMode")
            if autoMode {
                refreshDisplayInfo { [weak self] in
                    self?.scheduleAutoDisableIfNeeded(reason: "Auto mode enabled")
                }
            }
        }
    }
    @Published var displays: [DisplayState] = []
    @Published var externalDisplayCount = 0
    @Published var lastError: String? = nil

    private var cachedInternalDisplayID: CGDirectDisplayID?
    private var cachedInternalIdentity: DisplayIdentity?
    private var disabledDisplayCache: [CGDirectDisplayID: DisplayState] = [:]
    private var pendingDisabledIDs: Set<CGDirectDisplayID> = []
    private var lastKnownFrames: [CGDirectDisplayID: CGRect] = [:]
    private var fallbackTimer: Timer?
    private var autoDisableScheduled = false
    // Tracks external count as of the last hardware-change event (not polluted by
    // intermediate refreshes from didChangeScreenParametersNotification).
    private var lastHardwareExternalCount = 0
    // Saved before sleep so we can re-apply the setting after wake.
    private var wasInternalDisplayOffBeforeSleep = false

    private let internalIdentityKey = "InternalDisplayIdentityV2"
    private let cachedInternalDisplayIDKey = "CachedInternalDisplayID"
    private let disabledExternalRecordsKey = "DisabledExternalDisplaysV2"
    private let legacyDisabledExternalIDsKey = "DisabledExternalDisplayIDs"

    private var backupFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".internal_display_backup_id")
    }

    private func recoveryRecords(
        from cache: [CGDirectDisplayID: DisplayState]
    ) -> Set<PersistedDisplayRecord> {
        Set(cache.values
            .filter { !$0.isBuiltin }
            .compactMap(\.identity)
            .map(PersistedDisplayRecord.init(identity:)))
    }

    /// Before a mixed transaction, retain both the previous and intended
    /// recovery records. This closes the crash window between changing
    /// WindowServer state and committing the new recovery snapshot.
    private func persistDisabledExternalIDs(
        including additionalCache: [CGDirectDisplayID: DisplayState] = [:]
    ) {
        let records = recoveryRecords(from: disabledDisplayCache)
            .union(recoveryRecords(from: additionalCache))
            .sorted { $0.identity.storageKey < $1.identity.storageKey }
        savePersistedExternalRecords(records)
    }

    private func restorePersistedExternalDisplays() {
        var records = loadPersistedExternalRecords()
        records.append(contentsOf: migrateLegacyExternalRecords())
        records = Array(Set(records))
        guard !records.isEmpty else { return }

        let activeIDs = activeDisplayIDs()
        var unresolved: [PersistedDisplayRecord] = []
        var idsToEnable: [CGDirectDisplayID] = []

        for record in records where !record.identity.isBuiltin {
            guard let id = record.identity.resolve() else {
                unresolved.append(record)
                continue
            }
            if !activeIDs.contains(id) {
                idsToEnable.append(id)
            }
        }

        guard !idsToEnable.isEmpty else {
            savePersistedExternalRecords(unresolved)
            return
        }

        logger.info("Restoring \(idsToEnable.count) persisted disabled external display(s).")
        let result = configureDisplays(idsToEnable.map { ($0, true) })
        if result == .success {
            savePersistedExternalRecords(unresolved)
        } else {
            logger.error("Failed to restore persisted external displays: \(result.rawValue)")
            savePersistedExternalRecords(records)
        }
    }

    private func loadPersistedExternalRecords() -> [PersistedDisplayRecord] {
        guard let data = UserDefaults.standard.data(forKey: disabledExternalRecordsKey),
              let records = try? JSONDecoder().decode([PersistedDisplayRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func savePersistedExternalRecords(_ records: [PersistedDisplayRecord]) {
        if records.isEmpty {
            UserDefaults.standard.removeObject(forKey: disabledExternalRecordsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: disabledExternalRecordsKey)
        }
    }

    /// Migrates old raw IDs only when WindowServer still reports the ID as an
    /// online external display. The raw value is never used directly afterward.
    private func migrateLegacyExternalRecords() -> [PersistedDisplayRecord] {
        guard let rawIDs = UserDefaults.standard.array(forKey: legacyDisabledExternalIDsKey) as? [Int] else {
            return []
        }
        defer { UserDefaults.standard.removeObject(forKey: legacyDisabledExternalIDsKey) }

        let onlineIDs = onlineDisplayIDs()
        let records = rawIDs.compactMap { rawID -> PersistedDisplayRecord? in
            let id = CGDirectDisplayID(rawID)
            guard onlineIDs.contains(id),
                  CGDisplayIsBuiltin(id) == 0,
                  let identity = DisplayIdentity(displayID: id) else {
                return nil
            }
            return PersistedDisplayRecord(identity: identity)
        }
        if records.count != rawIDs.count {
            logger.warning("Discarded stale legacy display recovery IDs that could not be safely identified.")
        }
        return records
    }

    private func activeDisplayIDs() -> Set<CGDirectDisplayID> {
        displayIDs(from: CGGetActiveDisplayList)
    }

    private func onlineDisplayIDs() -> Set<CGDirectDisplayID> {
        displayIDs(from: CGGetOnlineDisplayList)
    }

    private func displayIDs(
        from query: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        guard query(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard query(count, &ids, &count) == .success else { return [] }
        return Set(ids.prefix(Int(count)))
    }

    private func loadInternalIdentity() -> DisplayIdentity? {
        guard let data = UserDefaults.standard.data(forKey: internalIdentityKey) else { return nil }
        return try? JSONDecoder().decode(DisplayIdentity.self, from: data)
    }

    private func cacheInternalDisplay(_ displayID: CGDirectDisplayID) {
        guard CGDisplayIsBuiltin(displayID) != 0 else { return }
        cachedInternalDisplayID = displayID
        UserDefaults.standard.set(Int(displayID), forKey: cachedInternalDisplayIDKey)
        if let identity = DisplayIdentity(displayID: displayID) {
            cachedInternalIdentity = identity
            if let data = try? JSONEncoder().encode(identity) {
                UserDefaults.standard.set(data, forKey: internalIdentityKey)
            }
        }
    }

    private func migrateLegacyInternalIdentity() -> DisplayIdentity? {
        var legacyIDs: [CGDirectDisplayID] = []
        if let value = try? String(contentsOf: backupFileURL, encoding: .utf8),
           let id = UInt32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            legacyIDs.append(id)
        }
        if let id = UserDefaults.standard.object(forKey: "BackupInternalDisplayID") as? Int {
            legacyIDs.append(CGDirectDisplayID(id))
        }

        let onlineIDs = onlineDisplayIDs()
        let identity = legacyIDs.lazy.compactMap { id -> DisplayIdentity? in
            guard onlineIDs.contains(id), CGDisplayIsBuiltin(id) != 0 else { return nil }
            return DisplayIdentity(displayID: id)
        }.first

        if identity != nil {
            UserDefaults.standard.removeObject(forKey: "BackupInternalDisplayID")
            try? FileManager.default.removeItem(at: backupFileURL)
        }
        return identity
    }

    private init() {
        let persistedID = CGDirectDisplayID(UserDefaults.standard.integer(forKey: cachedInternalDisplayIDKey))
        if persistedID != 0 && persistedID != kCGNullDirectDisplay {
            cachedInternalDisplayID = persistedID
        }

        cachedInternalIdentity = loadInternalIdentity() ?? migrateLegacyInternalIdentity()
        if let identity = cachedInternalIdentity,
           let id = identity.resolve(),
           identity.isBuiltin {
            cacheInternalDisplay(id)
        }

        // Migration: if internal was previously disabled, pre-populate cache so it
        // appears in the displays array with isEnabled=false on first refresh.
        if isInternalDisplayOff, let id = cachedInternalDisplayID {
            disabledDisplayCache[id] = DisplayState(
                id: id, identity: cachedInternalIdentity,
                name: "Built-in Display", isBuiltin: true,
                physicalSizeInches: 0, resolution: .zero, frame: .zero, isEnabled: false
            )
        }

        // Recover any external displays that were left disabled by a previous session
        // (crash, force-quit, etc.). SLSConfigureDisplayEnabled(0) fully removes the
        // display from the system; persisting the ID is the only way to restore it.
        restorePersistedExternalDisplays()

        refreshDisplayInfo()
        lastHardwareExternalCount = externalDisplayCount
        setupObservers()
        startFallbackTimer()
        scheduleAutoDisableIfNeeded(reason: "App launch")
    }

    private func startFallbackTimer() {
        // 5s interval — safety net for when the internal display is off
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in
                let manager = DisplayManager.shared
                guard manager.isInternalDisplayOff || manager.externalDisplayCount == 0 else { return }
                manager.performEmergencyCheck()
            }
        }
        fallbackTimer?.tolerance = 1
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChange()
            }
        }

        // Save state before sleep; macOS re-enables all displays on wake, which
        // causes refreshDisplayInfo() to clear isInternalDisplayOff. We use the
        // saved flag to re-apply the user's setting after the wake settles,
        // or restore immediately if external displays were disconnected during sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillSleep()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWakeFromSleep()
            }
        }

        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallBack, nil)
    }

    private func handleWillSleep() {
        wasInternalDisplayOffBeforeSleep = isInternalDisplayOff
        logger.info("System will sleep. wasInternalDisplayOffBeforeSleep: \(self.wasInternalDisplayOffBeforeSleep)")
    }

    private func handleWakeFromSleep() {
        logger.info("Wake from sleep: wasInternalDisplayOffBeforeSleep=\(self.wasInternalDisplayOffBeforeSleep), isInternalDisplayOff=\(self.isInternalDisplayOff)")

        // 1. Immediately check if external displays were disconnected while asleep.
        // If no external displays are connected, restore the internal display immediately
        // so the user does not face a black screen on opening the MacBook lid.
        emergencyHardwareCheck()
        refreshDisplayInfo { [weak self] in
            guard let self else { return }
            if self.externalDisplayCount == 0 && (self.isInternalDisplayOff || self.wasInternalDisplayOffBeforeSleep) {
                logger.info("Wake from sleep: no external displays connected, restoring internal display immediately.")
                self.wasInternalDisplayOffBeforeSleep = false
                self.forceEnableFromBackup()
            }
        }

        // 2. If an external display was connected and internal was off before sleep,
        // give macOS time to finish reconfiguring displays after wake before we re-disable,
        // or restore the internal display if no external display remains.
        guard wasInternalDisplayOffBeforeSleep else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            guard self.wasInternalDisplayOffBeforeSleep else { return }
            self.wasInternalDisplayOffBeforeSleep = false
            self.refreshDisplayInfo {
                if self.externalDisplayCount == 0 {
                    logger.info("Wake from sleep (settled): no external display, restoring internal display.")
                    self.forceEnableFromBackup()
                } else if DisplayAutomationPolicy.shouldRestoreAfterWake(
                    wasInternalDisplayOffBeforeSleep: true,
                    externalDisplayCount: self.externalDisplayCount
                ) {
                    logger.info("Wake from sleep: re-applying internal display off setting.")
                    self.disableInternalDisplay()
                }
            }
        }
    }

    func cleanup() {
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallBack, nil)
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    func handleHardwareDisplayChange() {
        logger.info("Hardware display reconfiguration detected.")
        Task { await BrightnessController.shared.invalidateCache() }
        restorePersistedExternalDisplays()
        let snapshot = lastHardwareExternalCount
        refreshDisplayInfo {
            defer { self.lastHardwareExternalCount = self.externalDisplayCount }
            guard DisplayAutomationPolicy.shouldDisableAfterHardwareChange(
                autoMode: self.autoMode,
                isInternalDisplayOff: self.isInternalDisplayOff,
                previousExternalDisplayCount: snapshot,
                currentExternalDisplayCount: self.externalDisplayCount
            ) else { return }
            self.scheduleAutoDisableIfNeeded(reason: "External display connected")
        }
    }

    private func scheduleAutoDisableIfNeeded(reason: String) {
        guard DisplayAutomationPolicy.shouldDisableAtStartup(
            autoMode: autoMode,
            isInternalDisplayOff: isInternalDisplayOff,
            externalDisplayCount: externalDisplayCount
        ), !autoDisableScheduled else { return }

        autoDisableScheduled = true
        logger.info("\(reason): scheduling internal display disable in 2s.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.autoDisableScheduled = false
            self.refreshDisplayInfo {
                guard DisplayAutomationPolicy.shouldDisableAtStartup(
                    autoMode: self.autoMode,
                    isInternalDisplayOff: self.isInternalDisplayOff,
                    externalDisplayCount: self.externalDisplayCount
                ) else {
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

    private func sizeInInches(_ displayID: CGDirectDisplayID) -> Double {
        let size = CGDisplayScreenSize(displayID)
        guard size.width > 0, size.height > 0 else { return 0 }
        return sqrt(size.width * size.width + size.height * size.height) / 25.4
    }

    // Applies multiple enable/disable changes in one display configuration session.
    private func configureDisplays(_ rawChanges: [(CGDirectDisplayID, Bool)]) -> CGError {
        guard let configEnabled = PrivateAPI.ConfigureDisplayEnabled else { return .failure }

        // Configuring a display into the state it is already in returns an error that
        // fails the whole transaction, so drop no-ops. The online list is the ground
        // truth here: SLSConfigureDisplayEnabled(0) removes a display from it.
        let onlineIDs = onlineDisplayIDs()
        let changes = rawChanges.filter { id, enabled in
            let alreadyEnabled = onlineIDs.contains(id)
            if alreadyEnabled == enabled {
                logger.debug("Skipping no-op display change: \(id) -> \(enabled)")
                return false
            }
            return true
        }
        guard !changes.isEmpty else { return .success }

        // macOS fires one reconfiguration event per disabled display, not one per
        // transaction. Without tracking, refreshDisplayInfo() sees a display that is
        // "still in NSScreen.screens" during an intermediate event and evicts it from
        // disabledDisplayCache, making it unrestorable. Guard against this by holding
        // the IDs until the notification flurry settles.
        let disablingIDs = changes.filter { !$0.1 }.map { $0.0 }
        pendingDisabledIDs.formUnion(disablingIDs)

        var configRef: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&configRef)
        guard result == .success else {
            pendingDisabledIDs.subtract(disablingIDs)
            return result
        }
        for (id, enabled) in changes {
            result = configEnabled(configRef, id, enabled ? 1 : 0)
            if result != .success {
                CGCancelDisplayConfiguration(configRef)
                pendingDisabledIDs.subtract(disablingIDs)
                return result
            }
        }
        result = CGCompleteDisplayConfiguration(configRef, .forSession)
        if result != .success {
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

    // MARK: - Multi-Display Operations

    func toggle(_ id: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == id }) else { return }
        let previousCache = disabledDisplayCache

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
        persistDisabledExternalIDs(including: previousCache)
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
            disabledDisplayCache = previousCache
            persistDisabledExternalIDs()
            lastError = "Failed to toggle display (Error: \(result.rawValue))"
        }
    }

    func solo(_ id: CGDirectDisplayID) {
        let previousCache = disabledDisplayCache
        for d in displays where d.id != id {
            disabledDisplayCache[d.id] = d
        }
        persistDisabledExternalIDs(including: previousCache)
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
            isInternalDisplayOff = !isInternal
            let name = displays.first(where: { $0.id == id })?.name ?? "Display"
            ToastManager.shared.showToast(message: "Only \(name) on")
        } else {
            disabledDisplayCache = previousCache
            persistDisabledExternalIDs()
            lastError = "Failed to solo display"
        }
    }

    func enableAll() {
        let disabled = displays.filter { !$0.isEnabled }
        guard !disabled.isEmpty else {
            ToastManager.shared.showToast(message: "All displays on")
            return
        }
        let previousCache = disabledDisplayCache
        for d in disabled { disabledDisplayCache.removeValue(forKey: d.id) }
        persistDisabledExternalIDs(including: previousCache)
        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)

        let result = configureDisplays(disabled.map { ($0.id, true) })

        if result == .success {
            isInternalDisplayOff = false
            ToastManager.shared.showToast(message: "All displays on")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshDisplayInfo() }
        } else {
            disabledDisplayCache = previousCache
            persistDisabledExternalIDs()
            lastError = "Failed to enable all displays"
        }
    }

    // State keys use persistent ColorSync UUIDs. Numeric keys are accepted only
    // for migration of scenes saved by older releases.
    func applySceneState(_ state: [String: Bool], sceneName: String) {
        let targetStates = displays.map { display in
            state[display.persistenceKey] ?? state[String(display.id)] ?? display.isEnabled
        }
        guard DisplayAutomationPolicy.leavesAtLeastOneDisplayEnabled(targetStates) else {
            lastError = "A scene must leave at least one display enabled."
            return
        }

        let previousCache = disabledDisplayCache
        var changes: [(CGDirectDisplayID, Bool)] = []
        for display in displays {
            guard let targetEnabled = state[display.persistenceKey] ?? state[String(display.id)] else { continue }
            if targetEnabled != display.isEnabled {
                changes.append((display.id, targetEnabled))
                if !targetEnabled { disabledDisplayCache[display.id] = display }
                else { disabledDisplayCache.removeValue(forKey: display.id) }
            }
        }
        persistDisabledExternalIDs(including: previousCache)

        guard !changes.isEmpty else {
            ToastManager.shared.showToast(message: "Applied: \(sceneName)")
            return
        }

        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)
        let result = configureDisplays(changes)

        if result == .success {
            if let internal_ = displays.first(where: { $0.isBuiltin }),
               let targetEnabled = state[internal_.persistenceKey] ?? state[String(internal_.id)] {
                isInternalDisplayOff = !targetEnabled
            }
            ToastManager.shared.showToast(message: "Applied: \(sceneName)")
            let hasEnables = changes.contains { $0.1 }
            if hasEnables {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshDisplayInfo() }
            }
        } else {
            disabledDisplayCache = previousCache
            persistDisabledExternalIDs()
            lastError = "Failed to apply scene"
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
                id: displayID,
                identity: DisplayIdentity(displayID: displayID),
                name: displayName,
                isBuiltin: isBuiltin,
                physicalSizeInches: inches,
                resolution: CGSize(width: screen.frame.width, height: screen.frame.height),
                frame: screen.frame, isEnabled: true
            )
            enabledDisplays.append(state)
            if !pendingDisabledIDs.contains(displayID) {
                disabledDisplayCache.removeValue(forKey: displayID)
            }
        }

        // NSScreen.screens omits displays that mirror another display, even though
        // they are powered and enabled. Treating them as missing made the app read
        // a mirroring built-in display as "off". The CoreGraphics online list is the
        // ground truth: SLSConfigureDisplayEnabled(0) removes a display from it.
        for displayID in onlineDisplayIDs() where !seenIDs.contains(displayID) {
            seenIDs.insert(displayID)
            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
            if isBuiltin { foundInternalID = displayID }

            let inches = sizeInInches(displayID)
            let bounds = CGDisplayBounds(displayID)
            let state = DisplayState(
                id: displayID,
                identity: DisplayIdentity(displayID: displayID),
                name: isBuiltin
                    ? "Built-in Display"
                    : (inches > 0 ? "\(Int(inches.rounded()))\" Display" : "External Display"),
                isBuiltin: isBuiltin,
                physicalSizeInches: inches,
                resolution: bounds.size,
                frame: bounds,
                isEnabled: true,
                isMirrored: CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
            )
            logger.debug("Online display \(displayID) not in NSScreen (mirrored: \(state.isMirrored))")
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

        displays = allDisplays
        externalDisplayCount = validExternals

        if validExternals > 0 && lastError == "No external display detected." {
            lastError = nil
        }

        if let id = foundInternalID {
            cacheInternalDisplay(id)
            // Don't clear the flag from an intermediate reconfiguration event while
            // a disable transaction for this display is still in flight.
            if isInternalDisplayOff && !pendingDisabledIDs.contains(id) {
                isInternalDisplayOff = false
            }
        }

        if (isInternalDisplayOff || foundInternalID == nil) && validExternals == 0 {
            logger.warning("Emergency: internal off, no external displays. Restoring.")
            if forceEnableFromBackup() {
                wasInternalDisplayOffBeforeSleep = false
                ToastManager.shared.showToast(message: "Internal Display Restored")
            }
        }

        // Safety net: if we believe the internal display is disabled but it has
        // no entry in displays (cache miss), re-add a placeholder so the UI
        // can still show it and "All On" / enableInternalDisplay can restore it.
        if isInternalDisplayOff,
           let internalID = cachedInternalDisplayID,
           !displays.contains(where: { $0.id == internalID }) {
            let placeholder = DisplayState(
                id: internalID,
                identity: cachedInternalIdentity,
                name: "Built-in Display",
                isBuiltin: true,
                physicalSizeInches: 0,
                resolution: .zero,
                frame: .zero,
                isEnabled: false
            )
            disabledDisplayCache[internalID] = placeholder
            displays.append(placeholder)
        }
        completion?()
    }

    // MARK: - Internal Display (legacy path, also used by ⌃⌘D hotkey)

    func getInternalDisplayID() -> CGDirectDisplayID? {
        if let current = onlineDisplayIDs().first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            cacheInternalDisplay(current)
            return current
        }
        if let cachedID = cachedInternalDisplayID, cachedID != kCGNullDirectDisplay {
            return cachedID
        }
        if let identity = cachedInternalIdentity,
           identity.isBuiltin,
           let resolved = identity.resolve() {
            cacheInternalDisplay(resolved)
            return resolved
        }
        let persistedID = CGDirectDisplayID(UserDefaults.standard.integer(forKey: cachedInternalDisplayIDKey))
        if persistedID != 0 && persistedID != kCGNullDirectDisplay {
            cachedInternalDisplayID = persistedID
            return persistedID
        }
        return nil
    }

    func toggleInternalDisplay() {
        isInternalDisplayOff ? enableInternalDisplay() : disableInternalDisplay()
    }

    func disableInternalDisplay() {
        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)
        // Do not refresh here: the current topology is already available and a
        // display reconfiguration notification will refresh after the transaction.

        guard externalDisplayCount > 0 else {
            lastError = "No external display detected."
            return
        }
        guard let displayID = getInternalDisplayID() else {
            lastError = "Could not find internal display ID."
            return
        }
        guard let configEnabled = PrivateAPI.ConfigureDisplayEnabled else {
            lastError = "Private API (SkyLight) not found."
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
                identity: cachedInternalIdentity ?? DisplayIdentity(displayID: displayID),
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
            cacheState = DisplayState(
                id: displayID,
                identity: cachedInternalIdentity ?? DisplayIdentity(displayID: displayID),
                name: "Built-in Display",
                isBuiltin: true,
                physicalSizeInches: 0,
                resolution: .zero,
                frame: .zero,
                isEnabled: true
            )
        }
        disabledDisplayCache[displayID] = cacheState

        logger.info("Disabling internal display \(displayID)")
        var configRef: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&configRef)
        if result == .success {
            result = configEnabled(configRef, displayID, 0)
            if result == .success {
                result = CGCompleteDisplayConfiguration(configRef, .forSession)
            } else {
                CGCancelDisplayConfiguration(configRef)
            }
        }

        if result == .success {
            isInternalDisplayOff = true
            lastError = nil
            ToastManager.shared.showToast(message: "Internal Display Disabled")
        } else {
            disabledDisplayCache.removeValue(forKey: displayID)
            let errStr = "Failed to disable (Error: \(result.rawValue))"
            lastError = errStr
            logger.error("Failed to disable display: \(result.rawValue)")
        }
    }

    func enableInternalDisplay() {
        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)
        guard let displayID = getInternalDisplayID() else {
            lastError = "Internal display ID lost."
            return
        }
        guard let configEnabled = PrivateAPI.ConfigureDisplayEnabled else {
            lastError = "Private API not found."
            return
        }

        // Already enabled (e.g. mirroring, or the flag went stale across a reboot):
        // enabling it again fails the configuration transaction, so just resync.
        if onlineDisplayIDs().contains(displayID) {
            logger.info("Internal display \(displayID) is already enabled; resyncing state.")
            disabledDisplayCache.removeValue(forKey: displayID)
            isInternalDisplayOff = false
            lastError = nil
            refreshDisplayInfo()
            return
        }

        logger.info("Enabling internal display \(displayID)")
        var configRef: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&configRef)
        if result == .success {
            result = configEnabled(configRef, displayID, 1)
            if result == .success {
                result = CGCompleteDisplayConfiguration(configRef, .forSession)
            } else {
                CGCancelDisplayConfiguration(configRef)
            }
        }

        if result == .success {
            disabledDisplayCache.removeValue(forKey: displayID)
            isInternalDisplayOff = false
            lastError = nil
            ToastManager.shared.showToast(message: "Internal Display Enabled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.refreshDisplayInfo() }
        } else {
            let errStr = "Failed to enable (Error: \(result.rawValue))"
            lastError = errStr
            logger.error("Failed to enable display: \(result.rawValue)")
        }
    }

    @discardableResult
    func forceEnableFromBackup() -> Bool {
        // Online, not NSScreen: a mirroring built-in display is enabled but hidden
        // from NSScreen.screens, and needs no recovery.
        if !isInternalDisplayOff,
           onlineDisplayIDs().contains(where: { CGDisplayIsBuiltin($0) != 0 }) {
            return true
        }
        guard let displayID = getInternalDisplayID() else {
            logger.error("No backed-up internal display ID to restore.")
            lastError = "Could not safely identify the internal display for recovery."
            return false
        }
        guard let configEnabled = PrivateAPI.ConfigureDisplayEnabled else {
            logger.error("Private API not found during forced restore.")
            lastError = "Private display API unavailable during recovery."
            return false
        }

        logger.info("Forcing enable of internal display \(displayID)")
        var configRef: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&configRef)
        if result == .success {
            result = configEnabled(configRef, displayID, 1)
            if result == .success {
                result = CGCompleteDisplayConfiguration(configRef, .forSession)
            } else {
                CGCancelDisplayConfiguration(configRef)
            }
        }

        guard result == .success else {
            let message = "Failed to restore internal display (Error: \(result.rawValue))"
            lastError = message
            logger.error("\(message)")
            return false
        }

        disabledDisplayCache.removeValue(forKey: displayID)
        isInternalDisplayOff = false
        lastError = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshDisplayInfo()
        }
        return true
    }

    func forceEnableAll() {
        if isInternalDisplayOff {
            _ = forceEnableFromBackup()
        }
        let disabled = disabledDisplayCache.values.filter { !$0.isBuiltin }
        if !disabled.isEmpty {
            let result = configureDisplays(disabled.map { ($0.id, true) })
            if result == .success {
                for display in disabled {
                    disabledDisplayCache.removeValue(forKey: display.id)
                }
                persistDisabledExternalIDs()
            } else {
                lastError = "Failed to restore all external displays (Error: \(result.rawValue))"
            }
        }
    }

    // MARK: - Emergency

    func emergencyHardwareCheck() {
        performEmergencyCheck()
    }

    /// Externals the user can actually see something on: named NSScreen displays,
    /// plus online externals that mirror another display (mirrors are omitted from
    /// NSScreen.screens but are still showing content).
    private func visibleExternalDisplayCount() -> Int {
        var validExternals = 0
        var seenIDs = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                if seenIDs.contains(id) { continue }
                seenIDs.insert(id)
                if CGDisplayIsBuiltin(id) == 0 {
                    let name = screen.localizedName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { validExternals += 1 }
                }
            }
        }
        for id in onlineDisplayIDs() where !seenIDs.contains(id) {
            if CGDisplayIsBuiltin(id) == 0, CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay {
                validExternals += 1
            }
        }
        return validExternals
    }

    private func performEmergencyCheck() {
        let validExternals = visibleExternalDisplayCount()
        if (isInternalDisplayOff || wasInternalDisplayOffBeforeSleep) && validExternals == 0 {
            logger.warning("Emergency check: no external displays. Restoring internal display.")
            if forceEnableFromBackup() {
                wasInternalDisplayOffBeforeSleep = false
                ToastManager.shared.showToast(message: "Internal Display Restored")
            }
        }
    }
}
