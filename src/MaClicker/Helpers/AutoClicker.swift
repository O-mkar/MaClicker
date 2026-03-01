//
//  AutoClicker.swift
//  MaClicker
//
//  Created by Bastian Aunkofer on 13.09.24.
//  Github: https://github.com/WorldOfBasti
//

import Foundation
import AppKit
import Sauce

final class AutoClicker {
    private var activationKey: Key?        { Key(QWERTYKeyCode: UserDefaults.standard.integer(forKey: "ActivationKey")) }
    private var activationModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: "ActivationModifiers")))
    }
    private var mode: ClickerMode          { ClickerMode(rawValue: UserDefaults.standard.integer(forKey: "ModeIndex")) ?? .toggle }
    private var useClickLimit: Bool        { UserDefaults.standard.bool(forKey: "LimitEnabled") }
    private var clickLimit: Int            { UserDefaults.standard.integer(forKey: "ClickLimit") }
    private var mouseButton: CGMouseButton { UserDefaults.standard.integer(forKey: "MouseButtonIndex") == 1 ? .right : .left }
    private var cps: Int                   { UserDefaults.standard.integer(forKey: "ClicksPerSecond") }

    // Humanise settings
    private var humaniseEnabled: Bool { UserDefaults.standard.bool(forKey: "HumaniseEnabled") }
    private var fatigueEnabled:  Bool { UserDefaults.standard.bool(forKey: "FatigueEnabled") }
    private var noiseEnabled:    Bool { UserDefaults.standard.bool(forKey: "NoiseEnabled") }
    private var collapseEnabled: Bool { UserDefaults.standard.bool(forKey: "CollapseEnabled") }

    // Standard clicker state
    private var clickerTimer: Timer?
    private var clickCount = 0
    private var isLocked = false
    private var clickStartTime: TimeInterval?
    private var lastCPSUpdateTime: TimeInterval = 0

    var isActive: Bool {
        clickerTimer != nil || isLocked || humaniseWorkItem != nil
    }

    // Humanise session state
    private var sessionStart: Date?
    private var humaniseClickCount = 0
    private var humaniseWorkItem: DispatchWorkItem?
    private var fatigueEngine: HumanFatigueEngine?

    init() {
        setupListeners()
    }


    /// Listen for key pressed/released events
    private func setupListeners() {
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { (event) in
            if self.matchesActivationKey(event: event) {
                self.keyDown()
            }
        }

        NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { event in
            if self.matchesActivationKey(event: event) {
                self.keyUp()
            }
        }
    }

    /// Checks if the event matches the configured activation key and modifiers
    private func matchesActivationKey(event: NSEvent) -> Bool {
        guard Sauce.shared.key(for: Int(event.keyCode)) == activationKey else { return false }
        let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        return event.modifierFlags.intersection(relevantModifiers) == activationModifiers.intersection(relevantModifiers)
    }

    /// Handles key down event based on selected mode
    private func keyDown() {
        if mode == .toggle {
            toggleClicker()
        } else if mode == .hold {
            startClicker()
        }
    }

    /// Handles key up event based on selected mode
    private func keyUp() {
        if mode == .hold {
            stopClicker()
        } else if mode == .lock {
            toggleLock()
        }
    }

    /// Starts clicker — uses humanise variable-delay scheduling when enabled, fixed Timer otherwise
    private func startClicker() {
        if humaniseEnabled {
            startHumaniseClicker()
        } else if clickerTimer == nil {
            clickCount = 0
            clickStartTime = ProcessInfo.processInfo.systemUptime
            clickerTimer = Timer.scheduledTimer(timeInterval: 1.0 / Double(cps), target: self, selector: #selector(clickerTimerFired), userInfo: nil, repeats: true)
            notifyStatusChanged()
        }
    }

    /// Stops clicker and resets state
    private func stopClicker() {
        // Standard timer
        clickerTimer?.invalidate()
        clickerTimer = nil
        clickCount = 0
        clickStartTime = nil
        NotificationCenter.default.post(name: .cpsUpdated, object: nil, userInfo: ["cps": 0.0])

        // Humanise
        humaniseWorkItem?.cancel()
        humaniseWorkItem = nil
        sessionStart = nil
        humaniseClickCount = 0
        fatigueEngine = nil

        notifyStatusChanged()
    }

    /// Toggles clicker (when in toggle mode)
    private func toggleClicker() {
        let isRunning = clickerTimer != nil || humaniseWorkItem != nil
        if isRunning {
            stopClicker()
        } else {
            startClicker()
        }
    }

    /// Toggles mouse button lock
    private func toggleLock() {
        // Release buttons to prevent bugs after switching modes
        releaseAllButtons()

        if isLocked {
            postMouseEvent(type:  mouseButton == .right ? .rightMouseUp : .leftMouseUp)
            isLocked = false
        } else {
            postMouseEvent(type: mouseButton == .right ? .rightMouseDown : .leftMouseDown)
            isLocked = true
        }
        notifyStatusChanged()
    }


    // MARK: - Humanise Clicker

    /// Begins a humanise session and schedules the first click
    private func startHumaniseClicker() {
        guard humaniseWorkItem == nil else { return }
        sessionStart = Date()
        humaniseClickCount = 0
        fatigueEngine = HumanFatigueEngine(seed: Double.random(in: 0...100))
        scheduleNextHumaniseClick()
        notifyStatusChanged()
    }

    /// Schedules the next humanise click using a one-shot DispatchWorkItem
    private func scheduleNextHumaniseClick() {
        let elapsed = sessionStart.map { -$0.timeIntervalSinceNow } ?? 0
        let baseMs  = 1000.0 / Double(max(1, cps))

        guard let engine = fatigueEngine else { return }
        let delayMs = engine.nextDelayMs(
            baseMs:          baseMs,
            elapsed:         elapsed,
            clickCount:      humaniseClickCount,
            fatigueEnabled:  fatigueEnabled,
            noiseEnabled:    noiseEnabled,
            collapseEnabled: collapseEnabled
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.humaniseWorkItem != nil else { return }

            // Check click limit before firing
            if self.mode == .toggle && self.useClickLimit && self.humaniseClickCount >= self.clickLimit {
                DispatchQueue.main.async { self.stopClicker() }
                return
            }

            self.performHumaniseClick()
            self.humaniseClickCount += 1

            // Throttled CPS update (~10/sec)
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastCPSUpdateTime >= 0.1 {
                self.lastCPSUpdateTime = now
                let elapsed = self.sessionStart.map { -$0.timeIntervalSinceNow } ?? 0
                let measuredCPS = elapsed > 0 ? Double(self.humaniseClickCount) / elapsed : 0
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .cpsUpdated, object: nil, userInfo: ["cps": measuredCPS])
                }
            }

            // Check limit after firing
            if self.mode == .toggle && self.useClickLimit && self.humaniseClickCount >= self.clickLimit {
                DispatchQueue.main.async { self.stopClicker() }
                return
            }

            self.scheduleNextHumaniseClick()
        }

        humaniseWorkItem = workItem
        // Subtract expected hold (~25ms) + dispatch overhead (~8ms) so the
        // total inter-click interval (wait + hold) matches the intended delayMs.
        let scheduledMs = max(5.0, delayMs - 33.0)
        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + scheduledMs / 1000.0,
            execute: workItem
        )
    }

    /// Fires a single humanise click with variable hold duration
    private func performHumaniseClick() {
        releaseAllButtons()
        postMouseEvent(type: mouseButton == .right ? .rightMouseDown : .leftMouseDown)

        // Variable press duration: ~25ms ± 8ms (realistic mouse click)
        let holdMs = max(5.0, HumanFatigueEngine.gaussianRandom(mean: 25, sd: 8))
        Thread.sleep(forTimeInterval: holdMs / 1000.0)

        postMouseEvent(type: mouseButton == .right ? .rightMouseUp : .leftMouseUp)
    }


    // MARK: - Standard Timer Clicker

    /// Releases both mouse buttons
    private func releaseAllButtons() {
        postMouseEvent(type: .leftMouseUp)
        postMouseEvent(type: .rightMouseUp)
    }

    /// Clicker timer callback (used for toggle and hold option, to perform clicks at the set cps/interval)
    @objc private func clickerTimerFired(timer: Timer) {
        // Throttle CPS UI updates to ~10/sec so the main run loop stays responsive at high CPS
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCPSUpdateTime >= 0.1 {
            lastCPSUpdateTime = now
            let elapsed = now - (clickStartTime ?? now)
            let measuredCPS = elapsed > 0 ? Double(clickCount + 1) / elapsed : 0
            NotificationCenter.default.post(name: .cpsUpdated, object: nil, userInfo: ["cps": measuredCPS])
        }

        DispatchQueue.global(qos: .userInteractive).async {
            if self.mode == .toggle && self.useClickLimit && self.clickCount + 1 > self.clickLimit {
                DispatchQueue.main.async { self.stopClicker() }
                return
            }

            // Release buttons to prevent bugs after switching modes
            self.releaseAllButtons()

            self.postMouseEvent(type: self.mouseButton == .right ? .rightMouseDown : .leftMouseDown)
            self.postMouseEvent(type: self.mouseButton == .right ? .rightMouseUp : .leftMouseUp)
            self.clickCount += 1
        }
    }

    /// Sends mouse event based on type and selected mouse button
    /// - Parameters:
    ///     - type: Type of mouse event (e.g.: leftMouseDown, leftMouseUp, ...)
    private func postMouseEvent(type: CGEventType) {
        var mouseLocation = NSEvent.mouseLocation
        mouseLocation.y = NSHeight(NSScreen.screens[0].frame) - mouseLocation.y

        let point = CGPoint(x: mouseLocation.x, y: mouseLocation.y)
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton)

        event?.post(tap: .cghidEventTap)
    }

    /// Posts notification when clicker status changes
    private func notifyStatusChanged() {
        NotificationCenter.default.post(name: .clickerStatusChanged, object: nil, userInfo: ["isActive": isActive])
    }
}

extension Notification.Name {
    static let clickerStatusChanged = Notification.Name("clickerStatusChanged")
    static let cpsUpdated = Notification.Name("cpsUpdated")
}
