import Foundation
import CoreGraphics
import AppKit

// MARK: - Private API Helper

private class PrivateAPI {
    typealias SLSConfigureDisplayEnabledFunc = @convention(c) (OpaquePointer?, CGDirectDisplayID, Int32) -> CGError

    static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    
    static let ConfigureDisplayEnabled: SLSConfigureDisplayEnabledFunc? = {
        let names = ["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"]
        for name in names {
            if let sym = dlsym(skyLight, name) {
                print("Found private API: \(name)")
                return unsafeBitCast(sym, to: SLSConfigureDisplayEnabledFunc.self)
            }
        }
        return nil
    }()
}

private func displayReconfigurationCallBack(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags, userInfo: UnsafeMutableRawPointer?) {
    // Only act on the completion of the remove event (not beginConfiguration)
    if flags.contains(.removeFlag) && !flags.contains(.beginConfigurationFlag) {
        if let userInfo = userInfo {
            let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
            // 🚨 CRITICAL: Execute synchronously on the callback thread before WindowServer sleeps the main thread!
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
            print("Successfully backed up internal display ID (\(displayID)) to \(backupFileURL.path)")
        } catch {
            print("Failed to save display ID to disk: \(error)")
        }
    }

    private func loadDisplayIDFromDisk() -> CGDirectDisplayID? {
        do {
            let idString = try String(contentsOf: backupFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = UInt32(idString) {
                return CGDirectDisplayID(id)
            }
        } catch {
            // It might not exist yet, which is fine
            print("Could not load display ID from disk: \(error.localizedDescription)")
        }
        return nil
    }

    private init() {
        if let diskBackup = loadDisplayIDFromDisk() {
            self.cachedInternalDisplayID = diskBackup
            print("Loaded backup display ID from disk: \(diskBackup)")
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
            // Only poll if we are currently off
            if self?.isInternalDisplayOff == true {
                self?.emergencyHardwareCheck()
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

    func handleHardwareDisplayChange() {
        print("Hardware display reconfiguration detected.")
        refreshDisplayInfo()
    }

    func emergencyHardwareCheck() {
        DispatchQueue.main.async {
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
            
            if self.isInternalDisplayOff && validExternals == 0 {
                print("🚨 Emergency Check: No valid external displays. Restoring IMMEDIATELY.")
                ToastManager.shared.showToast(message: "Internal Display Restored")
                self.forceEnableFromBackup()
            }
        }
    }

    private func handleScreenParametersChange() {
        print("Screen parameters changed.")
        refreshDisplayInfo()
    }

    func refreshDisplayInfo() {
        let screens = NSScreen.screens
        var validExternals = 0
        var foundInternal: CGDirectDisplayID?
        var seenIDs = Set<CGDirectDisplayID>()
        
        print("--- Refreshing Display Info ---")
        for screen in screens {
            let description = screen.deviceDescription
            if let displayID = description[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                if seenIDs.contains(displayID) { continue }
                seenIDs.insert(displayID)
                
                let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
                let name = screen.localizedName.trimmingCharacters(in: .whitespaces)
                print("Display: ID=\(displayID), Name='\(name)', Built-in=\(isBuiltin)")
                
                if isBuiltin {
                    foundInternal = displayID
                } else if !name.isEmpty {
                    validExternals += 1
                } else {
                    print("Ignoring ghost/dummy display: ID=\(displayID)")
                }
            }
        }
        
        // Hardware level check
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        var onlineCount: UInt32 = 0
        let hwResult = CGGetOnlineDisplayList(16, &onlineDisplays, &onlineCount)
        var hwExternals = 0
        
        let knownInternal = foundInternal ?? self.cachedInternalDisplayID ?? loadDisplayIDFromDisk()
        
        if hwResult == .success {
            for i in 0..<Int(onlineCount) {
                let dID = onlineDisplays[i]
                
                if let kID = knownInternal, dID == kID {
                    continue
                }
                
                if CGDisplayIsBuiltin(dID) == 0 {
                    // Check name if possible, otherwise rely on hardware flag
                    hwExternals += 1
                }
            }
        }
        print("Hardware online external displays: \(hwExternals)")
        
        DispatchQueue.main.async {
            self.externalDisplayCount = validExternals
            if let internalID = foundInternal {
                self.cachedInternalDisplayID = internalID
                UserDefaults.standard.set(Int(internalID), forKey: "BackupInternalDisplayID")
                self.saveDisplayIDToDisk(internalID) // Save to local file as well
                
                // If the display was found, it must be ON
                if self.isInternalDisplayOff {
                    self.isInternalDisplayOff = false
                }
            }
            
            // Auto-recovery: If internal is off and NO physical external displays are connected
            if self.isInternalDisplayOff && validExternals == 0 {
                print("🚨 Emergency: No physical external displays detected. Auto-enabling internal display.")
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
        // Notify to close popover before changes
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

        print("Action: Attempting to DISABLE display \(displayID)...")
        
        var configRef: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&configRef)
        print("1. CGBeginDisplayConfiguration: \(result.rawValue)")
        
        if result == .success {
            result = configEnabled(configRef, displayID, 0)
            print("2. SLSConfigureDisplayEnabled: \(result.rawValue)")
            
            if result == .success {
                result = CGCompleteDisplayConfiguration(configRef, .forSession)
                print("3. CGCompleteDisplayConfiguration: \(result.rawValue)")
            } else {
                CGCancelDisplayConfiguration(configRef)
            }
        }

        if result == .success {
            DispatchQueue.main.async {
                self.isInternalDisplayOff = true
                self.lastError = nil
            }
            print("SUCCESS: Display disabled.")
            ToastManager.shared.showToast(message: "Internal Display Disabled")
        } else {
            let errStr = "Failed to disable (Error: \(result.rawValue))"
            DispatchQueue.main.async {
                self.lastError = errStr
            }
            print(errStr)
        }
    }

    func enableInternalDisplay() {
        // Notify to close popover before changes
        NotificationCenter.default.post(name: NSNotification.Name("DisplayWillToggle"), object: nil)

        guard let displayID = getInternalDisplayID() else {
            lastError = "Internal display ID lost."
            return
        }

        guard let configEnabled = PrivateAPI.ConfigureDisplayEnabled else {
            lastError = "Private API not found."
            return
        }

        print("Action: Attempting to ENABLE display \(displayID)...")
        
        var configRef: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&configRef)
        print("1. CGBeginDisplayConfiguration: \(result.rawValue)")
        
        if result == .success {
            result = configEnabled(configRef, displayID, 1)
            print("2. SLSConfigureDisplayEnabled: \(result.rawValue)")
            
            if result == .success {
                result = CGCompleteDisplayConfiguration(configRef, .forSession)
                print("3. CGCompleteDisplayConfiguration: \(result.rawValue)")
            } else {
                CGCancelDisplayConfiguration(configRef)
            }
        }

        if result == .success {
            DispatchQueue.main.async {
                self.isInternalDisplayOff = false
                self.lastError = nil
            }
            print("SUCCESS: Display enabled.")
            ToastManager.shared.showToast(message: "Internal Display Enabled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.refreshDisplayInfo()
            }
        } else {
            let errStr = "Failed to enable (Error: \(result.rawValue))"
            DispatchQueue.main.async {
                self.lastError = errStr
            }
            print(errStr)
        }
    }

    func forceEnableFromBackup() {
        guard let displayID = getInternalDisplayID() else {
            print("Fatal: Could not find any backed up internal display ID to restore.")
            return
        }

        guard let configEnabled = PrivateAPI.ConfigureDisplayEnabled else {
            print("Fatal: Private API not found during forced restore.")
            return
        }

        print("Action: Forcing ENABLE for display \(displayID) unconditionally on exit...")
        
        var configRef: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&configRef)
        
        if result == .success {
            result = configEnabled(configRef, displayID, 1) // 1 means enable
            
            if result == .success {
                CGCompleteDisplayConfiguration(configRef, .forSession)
                print("SUCCESS: Forced display enable completed.")
            } else {
                CGCancelDisplayConfiguration(configRef)
                print("FAILED: configureDisplayEnabled returned \(result.rawValue)")
            }
        }
        
        // Ensure the state is reset so next launch is clean
        DispatchQueue.main.async {
            self.isInternalDisplayOff = false
        }
        UserDefaults.standard.set(false, forKey: "IsInternalDisplayOff")
    }
}
