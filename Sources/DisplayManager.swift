import Foundation
import CoreGraphics
import AppKit
import OSLog

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
    if flags.contains(.removeFlag) && !flags.contains(.beginConfigurationFlag) {
        if let userInfo = userInfo {
            let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
            manager.emergencyHardwareCheck()
            DispatchQueue.main.async {
                manager.handleHardwareDisplayChange()
            }
        }
    } else if flags.contains(.addFlag) && !flags.contains(.beginConfigurationFlag) {
        if let userInfo = userInfo {
            let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.handleHardwareDisplayChange()
            }
        }
    }
}

// MARK: - DisplayManager

class DisplayManager: ObservableObject {
    static let shared = DisplayManager()

    @Published var isInternalDisplayOff = UserDefaults.standard.bool(forKey: "IsInternalDisplayOff") {
        didSet {
            UserDefaults.standard.set(isInternalDisplayOff, forKey: "IsInternalDisplayOff")
        }
    }
    @Published var externalDisplayCount = 0
    @Published var lastError: String? = nil

    private var cachedInternalDisplayID: CGDirectDisplayID?
    private var fallbackTimer: DispatchSourceTimer?

    private var backupFileURL: URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return homeURL.appendingPathComponent(".internal_display_backup_id")
    }

    private func saveDisplayIDToDisk(_ displayID: CGDirectDisplayID) {
        let idString = String(displayID)
        do {
            try idString.write(to: backupFileURL, atomically: true, encoding: .utf8)
            logger.debug("Backed up internal display ID (\(displayID)) to \(self.backupFileURL.path)")
        } catch {
            logger.error("Failed to save display ID to disk: \(error)")
        }
    }

    private func loadDisplayIDFromDisk() -> CGDirectDisplayID? {
        do {
            let idString = try String(contentsOf: backupFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = UInt32(idString) {
                return CGDirectDisplayID(id)
            }
        } catch {
            logger.debug("Could not load display ID from disk: \(error.localizedDescription)")
        }
        return nil
    }

    private init() {
        if let diskBackup = loadDisplayIDFromDisk() {
            self.cachedInternalDisplayID = diskBackup
            logger.debug("Loaded backup display ID from disk: \(diskBackup)")
        } else if let backup = UserDefaults.standard.object(forKey: "BackupInternalDisplayID") as? Int {
            self.cachedInternalDisplayID = CGDirectDisplayID(backup)
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
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
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

    // Must be called on the main thread.
    private func performEmergencyCheck() {
        var validExternals = 0
        var seenIDs = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                if seenIDs.contains(displayID) { continue }
                seenIDs.insert(displayID)
                let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
                let name = screen.localizedName
                if !isBuiltin && !name.isEmpty && name.trimmingCharacters(in: .whitespaces) != "" {
                    validExternals += 1
                }
            }
        }

        if isInternalDisplayOff && validExternals == 0 {
            logger.warning("Emergency check: no valid external displays found. Restoring internal display.")
            ToastManager.shared.showToast(message: "Internal Display Restored")
            forceEnableFromBackup()
        }
    }

    func emergencyHardwareCheck() {
        DispatchQueue.main.async { [weak self] in
            self?.performEmergencyCheck()
        }
    }

    private func handleScreenParametersChange() {
        logger.debug("Screen parameters changed.")
        refreshDisplayInfo()
    }

    func refreshDisplayInfo() {
        let screens = NSScreen.screens
        var validExternals = 0
        var foundInternal: CGDirectDisplayID?
        var seenIDs = Set<CGDirectDisplayID>()

        logger.debug("Refreshing display info")
        for screen in screens {
            let description = screen.deviceDescription
            if let displayID = description[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                if seenIDs.contains(displayID) { continue }
                seenIDs.insert(displayID)

                let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
                let name = screen.localizedName.trimmingCharacters(in: .whitespaces)
                logger.debug("Display: ID=\(displayID), Name='\(name)', Built-in=\(isBuiltin)")

                if isBuiltin {
                    foundInternal = displayID
                } else if !name.isEmpty {
                    validExternals += 1
                } else {
                    logger.debug("Ignoring ghost/dummy display: ID=\(displayID)")
                }
            }
        }

        // Hardware-level cross-check
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        var onlineCount: UInt32 = 0
        let hwResult = CGGetOnlineDisplayList(16, &onlineDisplays, &onlineCount)
        var hwExternals = 0

        let knownInternal = foundInternal ?? self.cachedInternalDisplayID ?? loadDisplayIDFromDisk()

        if hwResult == .success {
            for i in 0..<Int(onlineCount) {
                let dID = onlineDisplays[i]
                if let kID = knownInternal, dID == kID { continue }
                if CGDisplayIsBuiltin(dID) == 0 {
                    hwExternals += 1
                }
            }
        }
        logger.debug("Hardware online external displays: \(hwExternals)")

        DispatchQueue.main.async {
            self.externalDisplayCount = validExternals

            if self.externalDisplayCount > 0 && self.lastError == "No external display detected." {
                self.lastError = nil
            }

            if let internalID = foundInternal {
                self.cachedInternalDisplayID = internalID
                UserDefaults.standard.set(Int(internalID), forKey: "BackupInternalDisplayID")
                self.saveDisplayIDToDisk(internalID)

                if self.isInternalDisplayOff {
                    self.isInternalDisplayOff = false
                }
            }

            if self.isInternalDisplayOff && validExternals == 0 {
                logger.warning("Emergency: no physical external displays detected. Auto-enabling internal display.")
                ToastManager.shared.showToast(message: "Internal Display Restored")
                self.forceEnableFromBackup()
            }
        }
    }

    func getInternalDisplayID() -> CGDirectDisplayID? {
        if let cached = cachedInternalDisplayID {
            return cached
        }
        if let diskBackup = loadDisplayIDFromDisk() {
            cachedInternalDisplayID = diskBackup
            return cachedInternalDisplayID
        }
        if let backup = UserDefaults.standard.object(forKey: "BackupInternalDisplayID") as? Int {
            cachedInternalDisplayID = CGDirectDisplayID(backup)
            return cachedInternalDisplayID
        }
        refreshDisplayInfo()
        return cachedInternalDisplayID
    }

    func toggleInternalDisplay() {
        if isInternalDisplayOff {
            enableInternalDisplay()
        } else {
            disableInternalDisplay()
        }
    }

    func disableInternalDisplay() {
        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)

        refreshDisplayInfo()

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

        logger.info("Attempting to disable display \(displayID)")

        var configRef: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&configRef)
        logger.debug("CGBeginDisplayConfiguration: \(result.rawValue)")

        if result == .success {
            result = configEnabled(configRef, displayID, 0)
            logger.debug("SLSConfigureDisplayEnabled(0): \(result.rawValue)")

            if result == .success {
                result = CGCompleteDisplayConfiguration(configRef, .forSession)
                logger.debug("CGCompleteDisplayConfiguration: \(result.rawValue)")
            } else {
                CGCancelDisplayConfiguration(configRef)
            }
        }

        if result == .success {
            DispatchQueue.main.async {
                self.isInternalDisplayOff = true
                self.lastError = nil
            }
            logger.info("Display disabled successfully.")
            ToastManager.shared.showToast(message: "Internal Display Disabled")
        } else {
            let errStr = "Failed to disable (Error: \(result.rawValue))"
            DispatchQueue.main.async {
                self.lastError = errStr
            }
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

        logger.info("Attempting to enable display \(displayID)")

        var configRef: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&configRef)
        logger.debug("CGBeginDisplayConfiguration: \(result.rawValue)")

        if result == .success {
            result = configEnabled(configRef, displayID, 1)
            logger.debug("SLSConfigureDisplayEnabled(1): \(result.rawValue)")

            if result == .success {
                result = CGCompleteDisplayConfiguration(configRef, .forSession)
                logger.debug("CGCompleteDisplayConfiguration: \(result.rawValue)")
            } else {
                CGCancelDisplayConfiguration(configRef)
            }
        }

        if result == .success {
            DispatchQueue.main.async {
                self.isInternalDisplayOff = false
                self.lastError = nil
            }
            logger.info("Display enabled successfully.")
            ToastManager.shared.showToast(message: "Internal Display Enabled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.refreshDisplayInfo()
            }
        } else {
            let errStr = "Failed to enable (Error: \(result.rawValue))"
            DispatchQueue.main.async {
                self.lastError = errStr
            }
            logger.error("Failed to enable display: \(result.rawValue)")
        }
    }

    func forceEnableFromBackup() {
        guard let displayID = getInternalDisplayID() else {
            logger.error("Could not find any backed-up internal display ID to restore.")
            return
        }

        guard let configEnabled = PrivateAPI.ConfigureDisplayEnabled else {
            logger.error("Private API not found during forced restore.")
            return
        }

        logger.info("Forcing enable for display \(displayID) unconditionally.")

        var configRef: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&configRef)

        if result == .success {
            result = configEnabled(configRef, displayID, 1)

            if result == .success {
                CGCompleteDisplayConfiguration(configRef, .forSession)
                logger.info("Forced display enable completed.")
            } else {
                CGCancelDisplayConfiguration(configRef)
                logger.error("configureDisplayEnabled returned \(result.rawValue)")
            }
        }

        DispatchQueue.main.async {
            self.isInternalDisplayOff = false
        }
        UserDefaults.standard.set(false, forKey: "IsInternalDisplayOff")
    }
}
