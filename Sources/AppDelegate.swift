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

    private var hotKeyRef: EventHotKeyRef?
    private var carbonEventHandlerRef: EventHandlerRef?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupDisplayObserver()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("DisplayWillToggle"),
            object: nil, queue: .main
        ) { _ in
            if let popover = self.popover, popover.isShown {
                popover.performClose(nil)
            }
        }

        setupGlobalHotKey()
    }

    private func setupGlobalHotKey() {
        let hotKeyID = EventHotKeyID(signature: 0x49444f66, id: 1)
        let eventSpec = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]

        let handler: EventHandlerUPP = { (_, _, _) -> OSStatus in
            DispatchQueue.main.async {
                DisplayManager.shared.toggleInternalDisplay()
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.updateStatusIcon()
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, eventSpec, nil, &carbonEventHandlerRef)
        let result = RegisterEventHotKey(UInt32(2), UInt32(cmdKey | controlKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if result == noErr { logger.info("Registered global hotkey: ⌃⌘D") }
        else { logger.error("Failed to register global hotkey: \(result)") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Application terminating: restoring all displays.")
        displayManager.forceEnableAll()
        displayManager.cleanup()
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = carbonEventHandlerRef { RemoveEventHandler(ref) }
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateStatusIcon()
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let contentView = PopoverView(
            displayManager: displayManager,
            sceneManager: SceneManager.shared,
            onQuit: { NSApp.terminate(nil) }
        )

        let hostingController = NSHostingController(rootView: contentView)
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
    }

    // MARK: - Display Observer

    private func setupDisplayObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Close any open popover before the screen layout changes: a stale anchor
            // position causes the popover to appear at wrong coordinates and breaks
            // the transient auto-dismiss (clicks don't land on the popover's new window).
            self?.closePopover()
            self?.displayManager.refreshDisplayInfo()
        }

        // Update status icon whenever display state changes
        displayManager.$displays
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        displayManager.$isInternalDisplayOff
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)
    }

    // MARK: - Status Icon

    func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let displays = displayManager.displays
        let onCount = displays.filter(\.isEnabled).count
        let totalCount = displays.count
        let isOff = displayManager.isInternalDisplayOff

        let iconSize = NSSize(width: 18, height: 18)
        let highContrastImage = NSImage(size: iconSize, flipped: false) { rect in
            let mainColor: NSColor = (onCount < totalCount && totalCount > 0) ? .systemOrange : .white
            let strokeColor: NSColor = mainColor == .systemOrange
                ? .systemOrange.withAlphaComponent(0.4)
                : NSColor.black.withAlphaComponent(0.4)

            // Screen body
            let screenRect = NSRect(x: 3, y: 7, width: 12, height: 8)
            let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 1, yRadius: 1)
            mainColor.setFill(); screenPath.fill()
            strokeColor.setStroke(); screenPath.lineWidth = 0.5; screenPath.stroke()

            // Base
            let basePath = NSBezierPath()
            basePath.move(to: NSPoint(x: 1, y: 5))
            basePath.line(to: NSPoint(x: 17, y: 5))
            basePath.lineWidth = 1.2; mainColor.setStroke(); basePath.stroke()

            // Slash when internal is off
            if isOff {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 4, y: 15))
                slash.line(to: NSPoint(x: 14, y: 4))
                NSColor.red.setStroke(); slash.lineWidth = 1.5; slash.stroke()
            }

            // Dot badge when multiple displays exist and some external is off but internal is on
            if !isOff && onCount < totalCount && totalCount > 1 {
                let dot = NSBezierPath(ovalIn: NSRect(x: 12, y: 12, width: 5, height: 5))
                NSColor.systemOrange.setFill(); dot.fill()
                NSColor.black.withAlphaComponent(0.3).setStroke()
                dot.lineWidth = 0.5; dot.stroke()
            }

            return true
        }

        highContrastImage.isTemplate = false
        button.image = highContrastImage
        button.contentTintColor = nil

        if onCount == totalCount || totalCount == 0 {
            button.toolTip = "All Displays On (⌃⌘D toggles built-in)"
        } else if isOff {
            button.toolTip = "Internal Display: OFF (⌃⌘D to restore)"
        } else {
            button.toolTip = "\(onCount)/\(totalCount) displays on (⌃⌘D toggles built-in)"
        }
    }

    // MARK: - Actions

    @objc func togglePopover(_ sender: AnyObject?) {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        displayManager.refreshDisplayInfo()
        LaunchManager.shared.refreshStatus()
        // One-tick defer so the status bar window's frame settles after any
        // display reconfiguration or drag in System Preferences → Arrange.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }
}
