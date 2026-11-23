import AppKit
import GameController

/// What a controller asks the launcher to do. ControllerInput turns device
/// input into these; ControllerNavigator holds every rule about them.
enum ControllerAction {
    case up, down, left, right, activate, cancel, play
}

/// The pad as the launcher reads it. x and y combine the d-pad and the left
/// stick, -1...1, right and up positive. `other` is any other button held.
struct PadState: Equatable {
    var x: Float = 0
    var y: Float = 0
    var cross = false
    var circle = false
    var options = false
    var other = false
}

/// Controller navigation policy: which window it drives and in what order,
/// when input counts, the stick threshold and auto-repeat. It moves focus
/// with makeFirstResponder, so the keyboard and VoiceOver follow it, and it
/// leaves the key-view loop and key equivalents alone.
final class ControllerNavigator {
    struct Screen {
        let window: NSWindow
        /// The controller's focus order.
        let controls: [NSControl]
        var initial: NSControl?
        var cancel: (() -> Void)?
        var play: NSButton?
    }

    /// A direction engages at `press` and lets go below `release`.
    static let press: Float = 0.5
    static let release: Float = 0.3
    static let repeatDelay: TimeInterval = 0.4
    static let repeatInterval: TimeInterval = 0.12

    var screen: () -> Screen? = { nil }
    var isActive: () -> Bool = { NSApp.isActive }
    var isBusy: () -> Bool = { false }
    var readPad: () -> PadState = { PadState() }
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Input counts only after the pad has been seen fully released while the
    /// launcher could accept it, so a button held from the game does nothing.
    private(set) var armed = false
    private var last = PadState()
    private var updating = false
    private var held: ControllerAction?
    /// When the held direction repeats; ControllerInput schedules tick(at:).
    private(set) var nextRepeat: TimeInterval?

    var accepting: Bool { isActive() && !isBusy() }

    /// Re-reads the pad; called when activation or the child process changes.
    func refresh() { update(readPad(), at: clock()) }

    func update(_ pad: PadState, at time: TimeInterval) {
        // An action can start the game, whose button update refreshes again.
        guard !updating else { return }
        updating = true
        let previous = last
        last = pad
        defer {
            updating = false
            if !accepting { disarm() }
        }
        guard accepting else { return }
        guard armed else {
            armed = Self.isReleased(pad)
            return
        }
        if pad.cross && !previous.cross { perform(.activate) }
        if pad.circle && !previous.circle { perform(.cancel) }
        if pad.options && !previous.options { perform(.play) }
        let direction = Self.direction(pad, held: held)
        guard direction != held else { return }
        held = direction
        nextRepeat = nil
        if let direction, perform(direction) { nextRepeat = time + Self.repeatDelay }
    }

    func tick(at time: TimeInterval) {
        guard accepting else { return disarm() }
        guard armed, let held, let next = nextRepeat, time >= next else { return }
        nextRepeat = perform(held) ? max(next + Self.repeatInterval, time) : nil
    }

    private func disarm() {
        armed = false
        held = nil
        nextRepeat = nil
    }

    static func isReleased(_ pad: PadState) -> Bool {
        !pad.cross && !pad.circle && !pad.options && !pad.other && abs(pad.x) < release && abs(pad.y) < release
    }

    private static func along(_ pad: PadState, _ direction: ControllerAction) -> Float {
        switch direction {
        case .up: return pad.y
        case .down: return -pad.y
        case .right: return pad.x
        case .left: return -pad.x
        default: return 0
        }
    }

    /// The held direction stays until it falls below `release` or another
    /// direction is pushed harder past `press`.
    private static func direction(_ pad: PadState, held: ControllerAction?) -> ControllerAction? {
        var strongest: ControllerAction?
        if max(abs(pad.x), abs(pad.y)) >= press {
            strongest = abs(pad.y) >= abs(pad.x) ? (pad.y > 0 ? .up : .down) : (pad.x > 0 ? .right : .left)
        }
        if let held, along(pad, held) >= release {
            if let strongest, strongest != held, along(pad, strongest) > along(pad, held) { return strongest }
            return held
        }
        return strongest
    }

    /// One action, or false when it did nothing.
    @discardableResult
    func perform(_ action: ControllerAction) -> Bool {
        guard accepting, let screen = screen() else { return false }
        let controls = screen.controls.filter { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor }
        let current = controls.firstIndex { $0 === screen.window.firstResponder }
        var handled = false
        switch action {
        case .up, .down, .left, .right:
            guard let current else {
                handled = focusInitial(screen, controls)
                break
            }
            if action == .left || action == .right, let popUp = controls[current] as? NSPopUpButton {
                handled = step(popUp, by: action == .right ? 1 : -1)
            } else {
                let next = current + (action == .up || action == .left ? -1 : 1)
                handled = controls.indices.contains(next) && screen.window.makeFirstResponder(controls[next])
            }
        case .activate:
            guard let current else {
                handled = focusInitial(screen, controls)
                break
            }
            // A pop-up's menu would block controller input while it tracks;
            // Left and Right change it instead.
            if let button = controls[current] as? NSButton, !(button is NSPopUpButton) {
                button.performClick(nil)
                handled = true
            }
        case .cancel:
            if let cancel = screen.cancel {
                cancel()
                handled = true
            }
        case .play:
            if let play = screen.play, play.isEnabled {
                play.performClick(nil)
                handled = true
            }
        }
        if handled { showFocus() }
        return handled
    }

    private func focusInitial(_ screen: Screen, _ controls: [NSControl]) -> Bool {
        let target = controls.first { $0 === screen.initial } ?? controls.first
        return target.map { screen.window.makeFirstResponder($0) } ?? false
    }

    /// Changes the selection as a mouse choice does: the item, then the action.
    private func step(_ popUp: NSPopUpButton, by offset: Int) -> Bool {
        let index = popUp.indexOfSelectedItem + offset
        guard index >= 0, index < popUp.numberOfItems else { return false }
        popUp.selectItem(at: index)
        if let action = popUp.action { NSApp.sendAction(action, to: popUp.target, from: popUp) }
        NSAccessibility.post(element: popUp, notification: .valueChanged)
        return true
    }

    /// Rings the focused control of whatever screen the action left showing.
    private func showFocus() {
        guard let screen = screen(), let control = screen.window.firstResponder as? NSControl,
              screen.controls.contains(where: { $0 === control }) else { return }
        FocusRingView.show(on: control)
    }
}

/// The controller's focus ring, in a view above the window's content that
/// takes no clicks and is hidden from accessibility. AppKit draws no focus
/// ring on buttons, checkboxes or pop-ups when the Mac's Keyboard navigation
/// setting is off, even for the first responder. It rings the control only
/// while that control is still the first responder.
final class FocusRingView: NSView {
    static let width: CGFloat = 3
    private weak var target: NSView?
    private var observation: NSKeyValueObservation?

    static func show(on control: NSView) {
        guard let content = control.window?.contentView else { return }
        let ring = content.subviews.lazy.compactMap { $0 as? FocusRingView }.first ?? FocusRingView()
        if content.subviews.last !== ring {
            content.addSubview(ring, positioned: .above, relativeTo: nil)
            ring.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                ring.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                ring.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                ring.topAnchor.constraint(equalTo: content.topAnchor),
                ring.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        ring.target = control
        ring.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = window?.observe(\.firstResponder) { [weak self] _, _ in self?.needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let target, let window, window.firstResponder === target, target.window === window,
              !target.isHiddenOrHasHiddenAncestor, let superview = target.superview else { return }
        let bounds = convert(target.alignmentRect(forFrame: target.frame), from: superview)
            .insetBy(dx: -(2 + Self.width / 2), dy: -(2 + Self.width / 2))
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        path.lineWidth = Self.width
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

/// The GameController glue: reads every connected pad into a PadState for the
/// navigator and reports the current controller's name and battery. Input
/// reaches the launcher only while it is the active app.
final class ControllerInput: NSObject {
    private let navigator: ControllerNavigator
    private let status: ((text: String, label: String)?) -> Void
    private var repeatTimer: Timer?
    private var batteryTimer: Timer?

    init(navigator: ControllerNavigator, status: @escaping ((text: String, label: String)?) -> Void) {
        self.navigator = navigator
        self.status = status
        super.init()
        navigator.readPad = { [weak self] in self?.read() ?? PadState() }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(connected(_:)), name: .GCControllerDidConnect, object: nil)
        center.addObserver(self, selector: #selector(changed), name: .GCControllerDidDisconnect, object: nil)
        center.addObserver(self, selector: #selector(changed), name: .GCControllerDidBecomeCurrent, object: nil)
        center.addObserver(self, selector: #selector(changed), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(changed), name: NSApplication.didResignActiveNotification, object: nil)
        for controller in GCController.controllers() { attach(controller) }
        changed()
    }

    private func attach(_ controller: GCController) {
        controller.handlerQueue = .main
        controller.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in self?.input() }
    }

    @objc private func connected(_ note: Notification) {
        if let controller = note.object as? GCController { attach(controller) }
        changed()
    }

    @objc private func changed() {
        input()
        let controller = GCController.current ?? GCController.controllers().first
        status(controller.map { Self.describe(name: $0.vendorName, battery: $0.battery) })
        batteryTimer?.invalidate()
        batteryTimer = nil
        if controller?.battery != nil {
            batteryTimer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(changed),
                                                userInfo: nil, repeats: false)
        }
    }

    private func input() {
        navigator.refresh()
        repeatTimer?.invalidate()
        repeatTimer = nil
        if let next = navigator.nextRepeat {
            repeatTimer = Timer.scheduledTimer(timeInterval: max(0, next - navigator.clock()), target: self,
                                               selector: #selector(tick), userInfo: nil, repeats: false)
        }
    }

    @objc private func tick() {
        navigator.tick(at: navigator.clock())
        repeatTimer = nil
        if let next = navigator.nextRepeat {
            repeatTimer = Timer.scheduledTimer(timeInterval: max(0, next - navigator.clock()), target: self,
                                               selector: #selector(tick), userInfo: nil, repeats: false)
        }
    }

    /// Every connected pad at once: Cross is button A, Circle B, Options Menu.
    private func read() -> PadState {
        var pad = PadState()
        func stronger(_ a: Float, _ b: Float) -> Float { abs(b) > abs(a) ? b : a }
        for controller in GCController.controllers() {
            guard let gamepad = controller.extendedGamepad else { continue }
            pad.x = stronger(stronger(pad.x, gamepad.dpad.xAxis.value), gamepad.leftThumbstick.xAxis.value)
            pad.y = stronger(stronger(pad.y, gamepad.dpad.yAxis.value), gamepad.leftThumbstick.yAxis.value)
            pad.cross = pad.cross || gamepad.buttonA.isPressed
            pad.circle = pad.circle || gamepad.buttonB.isPressed
            pad.options = pad.options || gamepad.buttonMenu.isPressed
            pad.other = pad.other || gamepad.allButtons.contains {
                $0.isPressed && $0 !== gamepad.buttonA && $0 !== gamepad.buttonB && $0 !== gamepad.buttonMenu
            }
        }
        return pad
    }

    /// The status line: the controller's name, then its battery when known.
    static func describe(name: String?, battery: GCDeviceBattery?) -> (text: String, label: String) {
        describe(name: name, level: battery?.batteryLevel, state: battery?.batteryState ?? .unknown)
    }

    static func describe(name: String?, level: Float?, state: GCDeviceBattery.State) -> (text: String, label: String) {
        let name = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Controller"
        let percent = level.map { "\(Int(($0 * 100).rounded()))%" }
        let battery: String?
        switch state {
        case .full: battery = "battery full"
        case .charging: battery = percent.map { "\($0) battery, charging" } ?? "charging"
        case .discharging: battery = percent.map { "\($0) battery" }
        case .unknown: battery = nil
        @unknown default: battery = nil
        }
        let text = [name, battery].compactMap { $0 }.joined(separator: " · ")
        return (text, "Controller connected: " + [name, battery].compactMap { $0 }.joined(separator: ", "))
    }
}
