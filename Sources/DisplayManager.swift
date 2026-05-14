import Foundation
import CoreGraphics
import AppKit
import OSLog

// MARK: - DisplayState

struct DisplayState: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let physicalSizeInches: Double
    let resolution: CGSize
    let frame: CGRect
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
        manager.emergencyHardwareCheck()
        DispatchQueue.main.async { manager.handleHardwareDisplayChange() }
    } else if flags.contains(.addFlag) && !flags.contains(.beginConfigurationFlag) {
        DispatchQueue.main.async { manager.handleHardwareDisplayChange() }
    }
}

// MARK: - DisplayManager

class DisplayManager: ObservableObject {
    static let shared = DisplayManager()

    @Published var isInternalDisplayOff = UserDefaults.standard.bool(forKey: "IsInternalDisplayOff") {
        didSet { UserDefaults.standard.set(isInternalDisplayOff, forKey: "IsInternalDisplayOff") }
    }
    @Published var displays: [DisplayState] = []
    @Published var externalDisplayCount = 0
    @Published var lastError: String? = nil

    private var cachedInternalDisplayID: CGDirectDisplayID?
    private var disabledDisplayCache: [CGDirectDisplayID: DisplayState] = [:]
    private var fallbackTimer: DispatchSourceTimer?

    private var backupFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".internal_display_backup_id")
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

        refreshDisplayInfo()
        setupObservers()
        startFallbackTimer()
    }

    private func startFallbackTimer() {
        let queue = DispatchQueue.global(qos: .background)
        fallbackTimer = DispatchSource.makeTimerSource(queue: queue)
        fallbackTimer?.schedule(deadline: .now(), repeating: 2.0)
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
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallBack, userInfo)
    }

    func cleanup() {
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallBack, userInfo)
    }

    func handleHardwareDisplayChange() {
        logger.info("Hardware display reconfiguration detected.")
        refreshDisplayInfo()
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
    private func configureDisplays(_ changes: [(CGDirectDisplayID, Bool)]) -> CGError {
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
        return CGCompleteDisplayConfiguration(configRef, .forSession)
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshDisplayInfo() }
            }
            ToastManager.shared.showToast(message: newEnabled ? "\(display.name) Enabled" : "\(display.name) Disabled")
        } else {
            // Undo cache change
            if newEnabled { disabledDisplayCache[id] = display } else { disabledDisplayCache.removeValue(forKey: id) }
            DispatchQueue.main.async { self.lastError = "Failed to toggle display (Error: \(result.rawValue))" }
        }
    }

    func solo(_ id: CGDirectDisplayID) {
        for d in displays where d.id != id {
            disabledDisplayCache[d.id] = d
        }
        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)

        let changes = displays.map { ($0.id, $0.id == id) }
        let result = configureDisplays(changes)

        if result == .success {
            disabledDisplayCache.removeValue(forKey: id)
            let isInternal = cachedInternalDisplayID == id
            DispatchQueue.main.async { self.isInternalDisplayOff = !isInternal }
            let name = displays.first(where: { $0.id == id })?.name ?? "Display"
            ToastManager.shared.showToast(message: "Only \(name) on")
        } else {
            for d in displays where d.id != id { disabledDisplayCache.removeValue(forKey: d.id) }
            DispatchQueue.main.async { self.lastError = "Failed to solo display" }
        }
    }

    func enableAll() {
        let disabled = displays.filter { !$0.isEnabled }
        guard !disabled.isEmpty else {
            ToastManager.shared.showToast(message: "All displays on")
            return
        }
        for d in disabled { disabledDisplayCache.removeValue(forKey: d.id) }
        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)

        let result = configureDisplays(disabled.map { ($0.id, true) })

        if result == .success {
            DispatchQueue.main.async { self.isInternalDisplayOff = false }
            ToastManager.shared.showToast(message: "All displays on")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshDisplayInfo() }
        } else {
            for d in disabled { disabledDisplayCache[d.id] = d }
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
        guard !changes.isEmpty else {
            ToastManager.shared.showToast(message: "Applied: \(sceneName)")
            return
        }

        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)
        let result = configureDisplays(changes)

        if result == .success {
            if let internal_ = displays.first(where: { $0.isBuiltin }),
               let targetEnabled = state[String(internal_.id)] {
                DispatchQueue.main.async { self.isInternalDisplayOff = !targetEnabled }
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
            DispatchQueue.main.async { self.lastError = "Failed to apply scene" }
        }
    }

    // MARK: - Refresh

    func refreshDisplayInfo() {
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
            disabledDisplayCache.removeValue(forKey: displayID)
        }

        var allDisplays = enabledDisplays
        for var cached in disabledDisplayCache.values {
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
                logger.warning("Emergency: internal off, no external displays. Restoring.")
                ToastManager.shared.showToast(message: "Internal Display Restored")
                self.forceEnableFromBackup()
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
        guard let configEnabled = PrivateAPI.ConfigureDisplayEnabled else {
            lastError = "Private API (SkyLight) not found."
            return
        }

        // Build a cache entry so the display remains visible in the spatial map after
        // disabling. Prefer the already-tracked state; fall back to a live NSScreen lookup
        // in case displays hasn't been populated yet (e.g. very first interaction).
        if disabledDisplayCache[displayID] == nil {
            let state: DisplayState
            if let existing = displays.first(where: { $0.id == displayID }) {
                state = existing
            } else if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
            }) {
                let inches = sizeInInches(displayID)
                let name = screen.localizedName.trimmingCharacters(in: .whitespaces)
                state = DisplayState(
                    id: displayID,
                    name: name.isEmpty ? "Built-in Display" : name,
                    isBuiltin: true,
                    physicalSizeInches: inches,
                    resolution: CGSize(width: screen.frame.width, height: screen.frame.height),
                    frame: screen.frame,
                    isEnabled: true
                )
            } else {
                state = DisplayState(id: displayID, name: "Built-in Display", isBuiltin: true,
                                     physicalSizeInches: 0, resolution: .zero, frame: .zero, isEnabled: true)
            }
            disabledDisplayCache[displayID] = state
        }

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
            DispatchQueue.main.async {
                self.isInternalDisplayOff = true
                self.lastError = nil
            }
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
        guard let displayID = getInternalDisplayID() else {
            lastError = "Internal display ID lost."
            return
        }
        guard let configEnabled = PrivateAPI.ConfigureDisplayEnabled else {
            lastError = "Private API not found."
            return
        }

        disabledDisplayCache.removeValue(forKey: displayID)

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
            DispatchQueue.main.async {
                self.isInternalDisplayOff = false
                self.lastError = nil
            }
            ToastManager.shared.showToast(message: "Internal Display Enabled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.refreshDisplayInfo() }
        } else {
            let errStr = "Failed to enable (Error: \(result.rawValue))"
            DispatchQueue.main.async { self.lastError = errStr }
            logger.error("Failed to enable display: \(result.rawValue)")
        }
    }

    func forceEnableFromBackup() {
        guard let displayID = getInternalDisplayID() else {
            logger.error("No backed-up internal display ID to restore.")
            return
        }
        guard let configEnabled = PrivateAPI.ConfigureDisplayEnabled else {
            logger.error("Private API not found during forced restore.")
            return
        }

        disabledDisplayCache.removeValue(forKey: displayID)

        var configRef: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&configRef)
        if result == .success {
            result = configEnabled(configRef, displayID, 1)
            if result == .success {
                CGCompleteDisplayConfiguration(configRef, .forSession)
            } else {
                CGCancelDisplayConfiguration(configRef)
            }
        }
        DispatchQueue.main.async { self.isInternalDisplayOff = false }
        UserDefaults.standard.set(false, forKey: "IsInternalDisplayOff")
    }

    func forceEnableAll() {
        forceEnableFromBackup()
        let disabled = disabledDisplayCache.values.filter { !$0.isBuiltin }
        if !disabled.isEmpty {
            _ = configureDisplays(disabled.map { ($0.id, true) })
            for d in disabled { disabledDisplayCache.removeValue(forKey: d.id) }
        }
    }

    // MARK: - Emergency

    func emergencyHardwareCheck() {
        DispatchQueue.main.async { self.performEmergencyCheck() }
    }

    private func performEmergencyCheck() {
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
        if isInternalDisplayOff && validExternals == 0 {
            logger.warning("Emergency check: no external displays. Restoring internal display.")
            ToastManager.shared.showToast(message: "Internal Display Restored")
            forceEnableFromBackup()
        }
    }
}
