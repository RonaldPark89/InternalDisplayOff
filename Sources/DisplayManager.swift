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

// MARK: - DisplayManager

class DisplayManager: ObservableObject {
    static let shared = DisplayManager()

    @Published var isInternalDisplayOff = false
    @Published var externalDisplayCount = 0
    @Published var lastError: String? = nil

    private var cachedInternalDisplayID: CGDirectDisplayID?

    private init() {
        refreshDisplayInfo()
    }

    func refreshDisplayInfo() {
        let screens = NSScreen.screens
        var externals = 0
        var foundInternal: CGDirectDisplayID?
        
        print("--- Refreshing Display Info ---")
        for screen in screens {
            let description = screen.deviceDescription
            if let displayID = description[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
                print("Display: ID=\(displayID), Name=\(screen.localizedName), Built-in=\(isBuiltin)")
                
                if isBuiltin {
                    foundInternal = displayID
                } else {
                    externals += 1
                }
            }
        }
        
        DispatchQueue.main.async {
            self.externalDisplayCount = externals
            if let internalID = foundInternal {
                self.cachedInternalDisplayID = internalID
            }
        }
    }

    func getInternalDisplayID() -> CGDirectDisplayID? {
        if let cached = cachedInternalDisplayID {
            return cached
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
}
