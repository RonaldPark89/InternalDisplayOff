import Cocoa
import SwiftUI
import Carbon
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let displayManager = DisplayManager.shared
    private var displayObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - App Lifecycle

    private var hotKeyRef: EventHotKeyRef?

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
        // Use a 4-character code literal for 'IDOf' to avoid deprecated UTGetOSTypeFromString
        let hotKeyID = EventHotKeyID(signature: 0x49444f66, id: 1)
        var eventHandler: EventHandlerRef?
        
        let eventSpec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        ]

        // Define the handler function
        let handler: EventHandlerUPP = { (nextHandler, theEvent, userData) -> OSStatus in
            // When shortcut is pressed
            DispatchQueue.main.async {
                print(">>> Carbon HotKey Triggered! <<<")
                DisplayManager.shared.toggleInternalDisplay()
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.updateStatusIcon()
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, eventSpec, nil, &eventHandler)
        
        // Register Ctrl (0x1000) + Cmd (0x0100) + D (keyCode 2)
        // cmdKey = 0x0100, controlKey = 0x1000
        let modifiers = UInt32(cmdKey | controlKey)
        let result = RegisterEventHotKey(UInt32(2), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        
        if result == noErr {
            print("Successfully registered Carbon HotKey: Ctrl+Cmd+D")
        } else {
            print("Failed to register Carbon HotKey: \(result)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Safety: always re-enable the internal display when the app quits
        print("Application terminating: Unconditionally forcing internal display to enable...")
        displayManager.forceEnableFromBackup()
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
        popover.contentSize = NSSize(width: 300, height: 280)
        popover.behavior = .transient
        popover.animates = true

        let contentView = PopoverView(
            displayManager: displayManager,
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        popover.contentViewController = NSHostingController(rootView: contentView)
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Bring popover to front
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }
}
