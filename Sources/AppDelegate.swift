import Cocoa
import SwiftUI
import Carbon
import Combine
import OSLog

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let displayManager = DisplayManager.shared
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "InternalDisplayOff", category: "AppDelegate")

    // MARK: - App Lifecycle

    private var hotKeyRef: EventHotKeyRef?
    private var carbonEventHandlerRef: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupDisplayObserver()

        // Close popover when display status is about to change to prevent UI glitches
        NotificationCenter.default.addObserver(forName: NSNotification.Name("DisplayWillToggle"), object: nil, queue: .main) { _ in
            if let popover = self.popover, popover.isShown {
                popover.performClose(nil)
            }
        }

        // Carbon HotKey Registration (Ctrl+Cmd+D)
        setupGlobalHotKey()
    }

    private func setupGlobalHotKey() {
        let hotKeyID = EventHotKeyID(signature: 0x49444f66, id: 1)

        let eventSpec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        ]

        // Handler function
        let handler: EventHandlerUPP = { (nextHandler, theEvent, userData) -> OSStatus in
            DispatchQueue.main.async {
                DisplayManager.shared.toggleInternalDisplay()
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.updateStatusIcon()
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, eventSpec, nil, &carbonEventHandlerRef)

        // Register Ctrl (0x1000) + Cmd (0x0100) + D (keyCode 2)
        let modifiers = UInt32(cmdKey | controlKey)
        let result = RegisterEventHotKey(UInt32(2), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if result == noErr {
            logger.info("Registered global hotkey: ⌃⌘D")
        } else {
            logger.error("Failed to register global hotkey: \(result)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Application terminating: forcing internal display to enable.")
        displayManager.forceEnableFromBackup()
        displayManager.cleanup()
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = carbonEventHandlerRef { RemoveEventHandler(ref) }
    }

    // MARK: - Status Bar Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateStatusIcon()
        }
    }

    // MARK: - Popover Setup

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let contentView = PopoverView(
            displayManager: displayManager,
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        let hostingController = NSHostingController(rootView: contentView)
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
    }

    // MARK: - Display Change Observer

    private func setupDisplayObserver() {
        // Monitor for display configuration changes
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.displayManager.refreshDisplayInfo()
        }
        
        // Reactively update the icon whenever the DisplayManager state changes
        displayManager.$isInternalDisplayOff
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)
    }

    // MARK: - Status Icon

    func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let isOff = displayManager.isInternalDisplayOff
        
        // High Contrast Drawing: Always use white for the main body to ensure visibility on dark bars
        // but add a tiny dark shadow/stroke so it's visible on light bars too.
        let iconSize = NSSize(width: 18, height: 18)
        let highContrastImage = NSImage(size: iconSize, flipped: false) { rect in
            let mainColor: NSColor = isOff ? .systemOrange : .white
            let strokeColor: NSColor = isOff ? .systemOrange.withAlphaComponent(0.5) : NSColor.black.withAlphaComponent(0.5)
            
            // 1. Draw Screen (Laptop Body)
            let screenRect = NSRect(x: 3, y: 7, width: 12, height: 8)
            let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 1, yRadius: 1)
            
            mainColor.setFill()
            screenPath.fill()
            
            strokeColor.setStroke()
            screenPath.lineWidth = 0.5
            screenPath.stroke()
            
            // 2. Draw Keyboard/Base
            let basePath = NSBezierPath()
            basePath.move(to: NSPoint(x: 1, y: 5))
            basePath.line(to: NSPoint(x: 17, y: 5))
            basePath.lineWidth = 1.2
            mainColor.setStroke()
            basePath.stroke()
            
            // 3. Draw Slash if OFF
            if isOff {
                let slashPath = NSBezierPath()
                slashPath.move(to: NSPoint(x: 4, y: 15))
                slashPath.line(to: NSPoint(x: 14, y: 4))
                NSColor.red.setStroke()
                slashPath.lineWidth = 1.5
                slashPath.stroke()
            }
            
            return true
        }
        
        highContrastImage.isTemplate = false // Force our manual colors
        button.image = highContrastImage
        button.contentTintColor = nil

        // Update tooltip
        button.toolTip = isOff
            ? "Internal Display: OFF (⌃⌘D to toggle)"
            : "Internal Display: ON (⌃⌘D to toggle)"
    }

    // MARK: - Actions

    @objc func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        if let button = statusItem.button {
            displayManager.refreshDisplayInfo()
            LaunchManager.shared.refreshStatus()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }
}
