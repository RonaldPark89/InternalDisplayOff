import Foundation
import ServiceManagement
import OSLog

class LaunchManager: ObservableObject {
    static let shared = LaunchManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "InternalDisplayOff", category: "LaunchManager")

    @Published var isLaunchAtLoginEnabled: Bool {
        didSet {
            updateLaunchAtLogin(enabled: isLaunchAtLoginEnabled)
        }
    }

    private init() {
        // Check current status
        self.isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        let service = SMAppService.mainApp
        
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                    logger.info("Successfully registered launch at login service")
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                    logger.info("Successfully unregistered launch at login service")
                }
            }
        } catch {
            logger.error("Failed to update launch at login status: \(error.localizedDescription)")
            // Reset to actual status if failed
            DispatchQueue.main.async {
                self.isLaunchAtLoginEnabled = service.status == .enabled
            }
        }
    }
    
    /// Sync status with system (useful when coming back from background)
    func refreshStatus() {
        let currentStatus = SMAppService.mainApp.status == .enabled
        if isLaunchAtLoginEnabled != currentStatus {
            isLaunchAtLoginEnabled = currentStatus
        }
    }
}
