//
//  HotkeyMonitor.swift
//  Zot Sidekick
//
//  Monitors for long-press of the Right Option key (approx 0.4s hold)
//  to toggle the floating panel from anywhere. Uses a CGEvent tap for
//  flagsChanged events; falls back to NSEvent monitors when the tap
//  cannot be created (no Accessibility permission yet).
//

import AppKit
import CoreGraphics

final class HotkeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightOptionDownTime: Date?
    private var otherKeyPressed = false
    private let holdDuration: TimeInterval = 0.4
    private let onActivate: () -> Void

    private var hasFired = false
    private var tapInstalled = false
    private var trustTimer: Timer?

    init(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
    }

    private var wasTrusted = false

    func start() {
        wasTrusted = AXIsProcessTrusted()
        installTap()
        startFallbackMonitor()
        // A tap created while untrusted is inert (receives no events). Poll
        // for the trust state; when it flips, rebuild the tap so it actually
        // delivers events without requiring a relaunch.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != self.wasTrusted {
                self.wasTrusted = trusted
                self.teardownTap()
                self.installTap()
            }
        }
    }

    private func teardownTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        tapInstalled = false
    }

    private func installTap() {
        guard !tapInstalled else { return }

        let eventMask = (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.keyDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: hotkeyCallback,
            userInfo: refcon
        ) else {
            print("[hotkey] Event tap not created yet (Accessibility not granted).")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapInstalled = true
        print("[hotkey] Event tap installed. Long-press Right Option to toggle the panel.")
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private func startFallbackMonitor() {
        print("[hotkey] Using fallback NSEvent monitor")

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.otherKeyPressed = true
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags

        if event.keyCode == 61 {
            if flags.contains(.option) {
                rightOptionDownTime = Date()
                otherKeyPressed = false
                hasFired = false

                DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) { [weak self] in
                    self?.checkAndFire()
                }
            } else {
                rightOptionDownTime = nil
            }
        } else {
            if rightOptionDownTime != nil {
                otherKeyPressed = true
            }
        }
    }

    func handleEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        // The system disables a tap that is slow or after input; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        if type == .keyDown {
            otherKeyPressed = true
            return
        }

        guard type == .flagsChanged else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = CGEventFlags(rawValue: event.flags.rawValue)

        if keyCode == 61 {
            if flags.contains(.maskAlternate) {
                rightOptionDownTime = Date()
                otherKeyPressed = false
                hasFired = false

                DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) { [weak self] in
                    self?.checkAndFire()
                }
            } else {
                rightOptionDownTime = nil
            }
        } else {
            if rightOptionDownTime != nil {
                otherKeyPressed = true
            }
        }
    }

    private func checkAndFire() {
        guard let downTime = rightOptionDownTime,
              !otherKeyPressed,
              !hasFired,
              Date().timeIntervalSince(downTime) >= holdDuration else {
            return
        }

        hasFired = true
        onActivate()
    }

    func stop() {
        trustTimer?.invalidate()
        trustTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        tapInstalled = false

        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.handleEvent(proxy, type: type, event: event)
    return Unmanaged.passUnretained(event)
}
