import CoreGraphics
import Foundation

enum CommandHoldAction: Equatable {
    case scheduleHold
    case cancelHold
    case finishHold
}

struct CommandHoldStateMachine {
    private(set) var pressedCommandKeys: Set<CGKeyCode> = []
    private(set) var isCandidate = false
    private(set) var didTrigger = false

    mutating func commandFlagsChanged(
        keyCode: CGKeyCode,
        commandModifierActive: Bool = true
    ) -> [CommandHoldAction] {
        if pressedCommandKeys.contains(keyCode) {
            pressedCommandKeys.remove(keyCode)
            guard pressedCommandKeys.isEmpty else { return [] }

            defer {
                isCandidate = false
                didTrigger = false
            }
            if didTrigger {
                return [.finishHold]
            }
            if isCandidate {
                return [.cancelHold]
            }
            return []
        }

        // A passive event tap can be installed between the physical key-down
        // and key-up events. Never interpret that orphaned key-up as a press.
        guard commandModifierActive else { return [] }

        pressedCommandKeys.insert(keyCode)
        guard pressedCommandKeys.count == 1, !isCandidate, !didTrigger else { return [] }
        isCandidate = true
        return [.scheduleHold]
    }

    mutating func otherKeyDown() -> [CommandHoldAction] {
        guard !pressedCommandKeys.isEmpty else { return [] }
        let shouldCancel = isCandidate || didTrigger
        isCandidate = false
        didTrigger = false
        return shouldCancel ? [.cancelHold] : []
    }

    mutating func holdThresholdReached() -> Bool {
        guard isCandidate, !pressedCommandKeys.isEmpty else { return false }
        isCandidate = false
        didTrigger = true
        return true
    }

    mutating func reset() {
        pressedCommandKeys.removeAll()
        isCandidate = false
        didTrigger = false
    }
}

final class CommandHoldMonitor {
    var onHoldBegan: (() -> Void)?
    var onHoldProgress: ((Double) -> Void)?
    var onLongPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPermissionChanged: ((Bool) -> Void)?

    private let holdDuration: TimeInterval
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionPollTimer: Timer?
    private var progressTimer: Timer?
    private var holdWorkItem: DispatchWorkItem?
    private var holdStartDate: Date?
    private var stateMachine = CommandHoldStateMachine()

    init(holdDuration: TimeInterval = 0.5) {
        self.holdDuration = holdDuration
    }

    func start() {
        guard eventTap == nil else { return }
        let authorized = CGPreflightListenEventAccess()
        onPermissionChanged?(authorized)
        guard authorized else {
            _ = CGRequestListenEventAccess()
            startPermissionPolling()
            return
        }
        installEventTap()
        if eventTap == nil {
            startPermissionPolling()
        }
    }

    func stop() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        stopProgressUpdates()
        holdWorkItem?.cancel()
        holdWorkItem = nil
        stateMachine.reset()

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func installEventTap() {
        guard eventTap == nil else { return }
        guard CGPreflightListenEventAccess() else {
            onPermissionChanged?(false)
            startPermissionPolling()
            return
        }
        let eventMask =
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let monitor = Unmanaged<CommandHoldMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        onPermissionChanged?(CGPreflightListenEventAccess())
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func startPermissionPolling() {
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let authorized = CGPreflightListenEventAccess()
            self.onPermissionChanged?(authorized)
            guard authorized else { return }
            self.installEventTap()
        }
    }

    func requestPermission() {
        let authorized = CGPreflightListenEventAccess()
        onPermissionChanged?(authorized)
        guard !authorized else {
            installEventTap()
            return
        }
        _ = CGRequestListenEventAccess()
        startPermissionPolling()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        switch type {
        case .flagsChanged:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == 54 || keyCode == 55 {
                let wasPressed = stateMachine.pressedCommandKeys.contains(keyCode)
                perform(
                    stateMachine.commandFlagsChanged(
                        keyCode: keyCode,
                        commandModifierActive: event.flags.contains(.maskCommand)
                    )
                )
                if !wasPressed, containsConflictingModifiers(event.flags) {
                    perform(stateMachine.otherKeyDown())
                }
            } else if !stateMachine.pressedCommandKeys.isEmpty {
                perform(stateMachine.otherKeyDown())
            }
        case .keyDown:
            perform(stateMachine.otherKeyDown())
        default:
            break
        }
    }

    private func containsConflictingModifiers(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty
    }

    private func perform(_ actions: [CommandHoldAction]) {
        for action in actions {
            switch action {
            case .scheduleHold:
                scheduleHold()
            case .cancelHold:
                holdWorkItem?.cancel()
                holdWorkItem = nil
                stopProgressUpdates()
                onCancel?()
            case .finishHold:
                holdWorkItem?.cancel()
                holdWorkItem = nil
                stopProgressUpdates()
                onRelease?()
            }
        }
    }

    private func scheduleHold() {
        holdWorkItem?.cancel()
        stopProgressUpdates()
        holdStartDate = Date()
        onHoldBegan?()
        onHoldProgress?(0)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let holdStartDate = self.holdStartDate else { return }
            let progress = min(1, Date().timeIntervalSince(holdStartDate) / self.holdDuration)
            self.onHoldProgress?(progress)
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.stateMachine.holdThresholdReached() else { return }
            self.holdWorkItem = nil
            self.onHoldProgress?(1)
            self.stopProgressUpdates()
            self.onLongPress?()
        }
        holdWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration, execute: workItem)
    }

    private func stopProgressUpdates() {
        progressTimer?.invalidate()
        progressTimer = nil
        holdStartDate = nil
    }
}
