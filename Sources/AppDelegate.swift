import Cocoa
import SwiftUI
import Carbon
import Combine
import OSLog
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let displayManager = DisplayManager.shared
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "InternalDisplayOff", category: "AppDelegate")

    private let hotKeySignature = OSType(0x49444f66)  // "IDOf"
    private let hotKeyID = UInt32(1)
    private var hotKeyRef: EventHotKeyRef?
    private var carbonEventHandlerRef: EventHandlerRef?
    private var registeredShortcut: KeyboardShortcut?
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?

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
        installHotKeyHandler()
        if !registerGlobalHotKey(GlobalShortcutSettings.shared.shortcut),
           GlobalShortcutSettings.shared.shortcut != .defaultShortcut,
           registerGlobalHotKey(.defaultShortcut) {
            GlobalShortcutSettings.shared.save(.defaultShortcut)
        }

        setupBrightnessKeyMonitor()
    }

    private func installHotKeyHandler() {
        guard carbonEventHandlerRef == nil else { return }

        let eventSpec = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]

        let handler: EventHandlerUPP = { (_, event, _) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, UInt32(kEventParamDirectObject),
                              UInt32(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async {
                if hkID.id == (NSApp.delegate as? AppDelegate)?.hotKeyID {
                    DisplayManager.shared.toggleInternalDisplay()
                    (NSApp.delegate as? AppDelegate)?.updateStatusIcon()
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, eventSpec, nil, &carbonEventHandlerRef)
    }

    @discardableResult
    func setGlobalShortcut(_ shortcut: KeyboardShortcut) -> Bool {
        guard registerGlobalHotKey(shortcut) else {
            ToastManager.shared.showToast(message: "Shortcut is already in use")
            return false
        }

        GlobalShortcutSettings.shared.save(shortcut)
        updateStatusIcon()
        ToastManager.shared.showToast(message: "Shortcut set to \(shortcut.displayString)")
        return true
    }

    private func registerGlobalHotKey(_ shortcut: KeyboardShortcut) -> Bool {
        let previousShortcut = registeredShortcut
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
            registeredShortcut = nil
        }

        var newHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(signature: hotKeySignature, id: hotKeyID),
            GetApplicationEventTarget(),
            0,
            &newHotKeyRef
        )

        guard status == noErr, let newHotKeyRef else {
            logger.error("Failed to register hotkey \(shortcut.displayString, privacy: .public): \(status)")
            if let previousShortcut {
                _ = registerGlobalHotKey(previousShortcut)
            }
            return false
        }

        hotKeyRef = newHotKeyRef
        registeredShortcut = shortcut
        logger.info("Registered hotkey: \(shortcut.displayString, privacy: .public)")
        return true
    }

    private func setupBrightnessKeyMonitor() {
        // IOHIDManager receives raw Consumer Control HID events directly from the keyboard
        // driver — before the OS routes them to CoreBrightness. This works even when the
        // internal display is off (where CGEventTap and NSEvent monitors don't receive events).
        //
        // kHIDPage_Consumer = 0x0C
        // kHIDUsage_Csmr_BrightnessDecrement = 0x6F  (F1 / 🔅)
        // kHIDUsage_Csmr_BrightnessIncrement = 0x70  (F2 / 🔆)

        // IOHIDRequestAccess triggers the Input Monitoring TCC permission prompt.
        // IOHIDManagerOpen alone does NOT show the prompt — the explicit request is required.
        // IOHIDRequestAccess blocks until the user responds. For LSUIElement (menu-bar-only)
        // apps the TCC dialog may not appear, so we call it on a background thread and
        // schedule a re-try that installs the manager once access is granted.
        // CGEventTap at the HID level receives NX_SYSDEFINED (media key) events.
        // On macOS 15+, this requires Accessibility permission. Compared to IOHIDManager
        // (which needs Input Monitoring), Accessibility is obtainable for self-signed apps.
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        guard trusted else {
            logger.warning("Accessibility not granted — brightness key rerouting requires Accessibility permission")
            return
        }

        // NX_SYSDEFINED = 14; matches NSEvent.EventType.systemDefined media-key events.
        let eventMask = CGEventMask(1 << 14)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            guard type.rawValue == 14 else { return Unmanaged.passRetained(event) }
            let nsEvent = NSEvent(cgEvent: event)
            // NX_SUBTYPE_AUX_CONTROL_BUTTONS = 8 (media key subtype)
            guard nsEvent?.subtype.rawValue == 8,
                  nsEvent?.data2 != 0,
                  UserDefaults.standard.bool(forKey: "RerouteBrightnessKeys"),
                  DisplayManager.shared.isInternalDisplayOff else {
                return Unmanaged.passRetained(event)
            }

            let keyCode = Int((nsEvent?.data1 ?? 0) >> 16) & 0xFF
            // NX_KEYTYPE_BRIGHTNESS_UP = 2, NX_KEYTYPE_BRIGHTNESS_DOWN = 3
            let increase = keyCode == 2
            let decrease = keyCode == 3
            if increase || decrease {
                DispatchQueue.main.async {
                    BrightnessController.shared.adjustAllExternalBrightness(increase: increase)
                }
            }
            return Unmanaged.passRetained(event)
        }

        // kCGHIDEventTap=0, kCGHeadInsertEventTap=0, kCGEventTapOptionListenOnly=1
        guard let tap = CGEvent.tapCreate(
            tap: CGEventTapLocation(rawValue: 0)!,
            place: CGEventTapPlacement(rawValue: 0)!,
            options: CGEventTapOptions(rawValue: 1)!,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        ) else {
            logger.warning("CGEventTap creation failed — brightness key rerouting unavailable")
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        tapRunLoopSource = src
        logger.info("CGEventTap installed for F1/F2 brightness key monitoring")
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Application terminating: restoring all displays.")
        displayManager.forceEnableAll()
        displayManager.cleanup()
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = carbonEventHandlerRef { RemoveEventHandler(ref) }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = tapRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
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
        popover.delegate = self
        // contentViewController is set fresh each time the popover opens —
        // see showPopover(). Keeping a permanent NSHostingController alive
        // in the background keeps @ObservedObject subscriptions and
        // repeatForever animations running even when the popover is closed.
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Deallocate the hosting controller regardless of HOW the popover closed
        // (explicit close, transient click-outside, or DisplayWillToggle). Without
        // this, transient closes leave the NSHostingController alive indefinitely,
        // keeping @ObservedObject subscriptions active and burning ~9% CPU.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.popover.contentViewController = nil
        }
    }

    private func makePopoverController() -> NSHostingController<PopoverView> {
        let contentView = PopoverView(
            displayManager: displayManager,
            sceneManager: SceneManager.shared,
            onQuit: { NSApp.terminate(nil) }
        )
        let hc = NSHostingController(rootView: contentView)
        hc.sizingOptions = .preferredContentSize
        return hc
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

        // Update status icon whenever display state changes.
        // Use DispatchQueue.main (not RunLoop.main) — RunLoop.main fires on every
        // run loop iteration, which during Core Animation can be 60fps, causing
        // updateStatusIcon() to run at screen refresh rate and burn CPU.
        displayManager.$displays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        displayManager.$isInternalDisplayOff
            .receive(on: DispatchQueue.main)
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

        let shortcut = GlobalShortcutSettings.shared.shortcut.displayString
        if onCount == totalCount || totalCount == 0 {
            button.toolTip = "All Displays On (\(shortcut) toggles built-in)"
        } else if isOff {
            button.toolTip = "Internal Display: OFF (\(shortcut) to restore)"
        } else {
            button.toolTip = "\(onCount)/\(totalCount) displays on (\(shortcut) toggles built-in)"
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
        // Fresh controller every open — stops background @ObservedObject
        // subscriptions and Core Animation loops from the previous session.
        popover.contentViewController = makePopoverController()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func closePopover() {
        popover.performClose(nil)
        // NSPopoverDelegate.popoverDidClose handles the contentViewController cleanup.
    }

}
