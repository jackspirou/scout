import AppKit
import Foundation

// MARK: - HotkeyError

enum HotkeyError: LocalizedError {
    case eventTapCreationFailed
    case accessibilityPermissionDenied
    case alreadyRegistered

    var errorDescription: String? {
        switch self {
        case .eventTapCreationFailed:
            return "Failed to create event tap for global hotkey"
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required for global hotkeys"
        case .alreadyRegistered:
            return "Hotkey is already registered"
        }
    }
}

// MARK: - HotkeyService

/// Singleton service for registering global hotkeys.
/// Uses CGEvent tap for the global Opt+Space hotkey.
/// Requires accessibility permissions (System Settings > Privacy & Security > Accessibility).
final class HotkeyService: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = HotkeyService()

    // MARK: - Properties

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRegistered = false
    private let lock = NSLock()

    /// Called when the hotkey is activated. Set this before calling `register()`.
    var onHotkeyActivated: (() -> Void)?

    // MARK: - Init

    private init() {}

    deinit {
        unregister()
    }

    // MARK: - Public Methods

    /// Checks whether accessibility permissions are granted.
    func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user for accessibility permissions if not already granted.
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Registers the global Opt+Space hotkey.
    /// Throws if already registered or if accessibility permissions are not granted.
    func register() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isRegistered else {
            throw HotkeyError.alreadyRegistered
        }

        guard hasAccessibilityPermission() else {
            requestAccessibilityPermission()
            throw HotkeyError.accessibilityPermissionDenied
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                callback: hotkeyEventCallback,
                userInfo: refcon
            )
        else {
            throw HotkeyError.eventTapCreationFailed
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isRegistered = true
    }

    /// Unregisters the global hotkey and cleans up resources.
    func unregister() {
        lock.lock()
        defer { lock.unlock() }

        guard isRegistered else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        isRegistered = false
    }

    /// Returns whether the hotkey is currently registered.
    func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRegistered
    }

    // MARK: - Hotkey Handler

    /// Handles the hotkey event. Called from the CGEvent tap callback.
    fileprivate func handleHotkey() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if let handler = self.onHotkeyActivated {
                handler()
            } else {
                self.toggleAppVisibility()
            }
        }
    }

    /// Re-enables the event tap when the system disables it.
    fileprivate func reenableTapIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func toggleAppVisibility() {
        let app = NSApplication.shared

        if app.isActive {
            app.hide(nil)
        } else {
            app.activate(ignoringOtherApps: true)
            if let window = app.mainWindow {
                window.makeKeyAndOrderFront(nil)
            } else if let window = app.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// MARK: - CGEvent Tap Callback

/// The CGEvent tap callback. Must be a C-compatible function.
private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // Handle tap disabled events (system can disable taps under load).
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
            service.reenableTapIfNeeded()
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown else {
        return Unmanaged.passRetained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags

    // Key code 49 = Space bar.
    // Check for Option (Alternate) modifier, excluding other modifiers.
    let optionOnly: CGEventFlags = .maskAlternate
    let relevantModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
    let activeModifiers = flags.intersection(relevantModifiers)

    if keyCode == 49, activeModifiers == optionOnly {
        guard let userInfo else {
            return Unmanaged.passRetained(event)
        }

        let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
        service.handleHotkey()

        // Consume the event so it does not propagate.
        return nil
    }

    return Unmanaged.passRetained(event)
}
