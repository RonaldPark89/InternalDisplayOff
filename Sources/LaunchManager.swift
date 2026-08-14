import Foundation
import ServiceManagement
import OSLog

@MainActor
final class LaunchManager: ObservableObject {
    static let shared = LaunchManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "InternalDisplayOff", category: "LaunchManager")

    @Published var isLaunchAtLoginEnabled: Bool {
        didSet {
            if !isSynchronizingStatus {
                updateLaunchAtLogin(enabled: isLaunchAtLoginEnabled)
            }
        }
    }
    private var isSynchronizingStatus = false

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
            synchronizeStatus(service.status == .enabled)
        }
    }

    private func synchronizeStatus(_ enabled: Bool) {
        isSynchronizingStatus = true
        isLaunchAtLoginEnabled = enabled
        isSynchronizingStatus = false
    }
    
    /// Sync status with system (useful when coming back from background)
    func refreshStatus() {
        let currentStatus = SMAppService.mainApp.status == .enabled
        if isLaunchAtLoginEnabled != currentStatus {
            synchronizeStatus(currentStatus)
        }
    }
}
