// SPDX-License-Identifier: MIT
// SurfaceTouchKeys — automatic on-screen keyboard for macOS touchscreens.
//
// Based on TouchKeys from TouchDeck (MIT, (c) 2024 Sebastian Hueber,
// (c) 2026 White Oak Media). Changes for SurfaceTouchMac:
//   * event-driven focus detection (AXObserver) with a slow polling fallback
//   * Unicode typing (works with any input layout), Caps Lock, Tab, arrows
//   * hold-to-repeat that survives the touch driver's long-press right-click
//   * keys sized from the actual screen (Surface Pro 7: 12.3", 2736x1824)
//   * moves above the field instead of covering it, floating show/hide button
//
// Privacy: this app never reads the value of any text element, never logs
// keystrokes and makes no network connections. It only reads an element's
// role/subrole/attribute names and frame to decide whether to show itself.

import AppKit
import ApplicationServices
import TouchKeyboardCore

// MARK: - Event posting

enum EventPoster {
    static let source = CGEventSource(stateID: .combinedSessionState)   // as TouchKeys

    static func type(_ text: String) {
        let utf16 = Array(text.utf16)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            e.flags = []
            e.post(tap: .cgSessionEventTap)
        }
    }

    static func special(_ key: SpecialKey) {
        var flags: CGEventFlags = []
        if key.isArrow { flags.insert(.maskSecondaryFn); flags.insert(.maskNumericPad) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cgSessionEventTap)
        }
    }

    /// Number of outputs emitted (used only by the CI self-test; no content is kept).
    static var emitted = 0

    static func emit(_ output: Output) {
        if output != .none { emitted += 1 }
        switch output {
        case .text(let s): type(s)
        case .special(let k): special(k)
        case .none: break
        }
    }
}

func now() -> Double { ProcessInfo.processInfo.systemUptime }

// MARK: - Key view

final class KeyView: NSView {
    let key: Key
    var title: String { didSet { label.stringValue = title } }
    var latched = false { didSet { needsDisplay = true } }
    private var highlighted = false { didSet { needsDisplay = true } }
    private let label = NSTextField(labelWithString: "")
    weak var controller: KeyboardController?

    init(key: Key, title: String, fontSize: CGFloat) {
        self.key = key
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = title
        label.alignment = .center
        label.font = .systemFont(ofSize: fontSize, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(key.label)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // Never take focus away from the app being typed into.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 9, yRadius: 9)
        if highlighted { NSColor.controlAccentColor.setFill() }
        else if latched { NSColor.controlAccentColor.withAlphaComponent(0.45).setFill() }
        else { NSColor.controlColor.withAlphaComponent(0.95).setFill() }
        r.fill()
    }

    override func mouseDown(with event: NSEvent) { controller?.touch(.down, on: self) }
    override func mouseUp(with event: NSEvent) { controller?.touch(.up, on: self) }
    override func rightMouseDown(with event: NSEvent) { controller?.touch(.down, on: self) }
    override func rightMouseUp(with event: NSEvent) { controller?.touch(.up, on: self) }

    func setPressed(_ p: Bool) { highlighted = p }
}

// MARK: - Panel that can never become key (keeps the target app focused)

final class KeyboardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Toolbar: drag bar, opacity, dock/float, resize grip

/// Small button that works on the first touch without activating the panel.
final class BarButton: NSButton {
    var onTap: (() -> Void)?
    convenience init(_ title: String, label: String, onTap: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.onTap = onTap
        target = self
        action = #selector(fire)
        isBordered = false
        font = .systemFont(ofSize: 17, weight: .semibold)
        contentTintColor = .labelColor
        setAccessibilityLabel(label)
    }
    @objc private func fire() { onTap?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Drag anywhere on the bar to move the keyboard (undocks it if docked).
final class DragBar: NSView {
    weak var controller: KeyboardController?
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // grab handle in the middle, like iPad's floating keyboard
        let w: CGFloat = 54, h: CGFloat = 5
        let r = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        NSColor.secondaryLabelColor.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
    }
    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        controller?.dragBegan()
        startOrigin = window?.frame.origin ?? startOrigin
    }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        controller?.dragMoved(to: NSPoint(x: startOrigin.x + p.x - startMouse.x, y: startOrigin.y + p.y - startMouse.y))
    }
    override func mouseUp(with event: NSEvent) { controller?.dragEnded() }
}

/// Drag left/right to resize; the keyboard's top-left corner stays put.
final class ResizeGrip: NSView {
    weak var controller: KeyboardController?
    private var startMouseX: CGFloat = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        for i in 0..<3 {
            let o = CGFloat(6 + i * 6)
            path.move(to: NSPoint(x: bounds.maxX - 6, y: bounds.minY + o))
            path.line(to: NSPoint(x: bounds.maxX - o, y: bounds.minY + 6))
        }
        NSColor.secondaryLabelColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        startMouseX = NSEvent.mouseLocation.x
        controller?.resizeBegan()
    }
    override func mouseDragged(with event: NSEvent) {
        controller?.resizeMoved(dx: Double(NSEvent.mouseLocation.x - startMouseX))
    }
    override func mouseUp(with event: NSEvent) { controller?.resizeEnded() }
}

// MARK: - Keyboard controller

final class KeyboardController {
    let panel: KeyboardPanel
    private(set) var state = KeyboardState()
    private var keyViews: [KeyView] = []
    private let sequencer = TouchSequencer()
    private var activeKey: KeyView?
    private var pressStart = 0.0
    private var repeatsFired = 0
    private var repeatTimer: Timer?
    private var flushTimer: Timer?
    private let repeatPolicy = RepeatPolicy()
    private(set) var lastKeyPress = -1_000.0
    var manuallyHidden = false   // user tapped "hide": stay hidden until focus leaves & returns
    var pinned = false           // shown with the floating button: no auto-hide
    private var currentScreen: NSScreen?
    private var lastField: Rect?
    private(set) var settings: KeyboardSettings = {
        let d = UserDefaults.standard.dictionary(forKey: "keyboardSettings") as? [String: String] ?? [:]
        return KeyboardSettings.decode(d)
    }()
    private var resizeStart: (width: Double, top: Double, x: Double)?
    private var opacityButton: BarButton?

    private func saveSettings() {
        UserDefaults.standard.set(settings.encode(), forKey: "keyboardSettings")
    }

    private func visibleRect(_ screen: NSScreen) -> Rect {
        let vf = screen.visibleFrame
        return Rect(x: Double(vf.minX), y: Double(vf.minY), width: Double(vf.width), height: Double(vf.height))
    }

    init() {
        panel = KeyboardPanel(contentRect: .zero,
                              styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.setAccessibilityLabel("SurfaceTouchKeys keyboard")
    }

    var isVisible: Bool { panel.isVisible }

    private func rebuild(on screen: NSScreen) {
        let rows = Layouts.rows(for: state.layer)
        let units = Layouts.maxUnits(for: state.layer)
        let visible = visibleRect(screen)
        let bar = KeyboardSettings.toolbarHeight
        let m: KeyboardMetrics
        let totalHeight: Double
        if settings.mode == .floating {
            settings.floatWidth = FloatingGeometry.clampWidth(settings.floatWidth, visible: visible)
            m = FloatingGeometry.metrics(width: settings.floatWidth, maxUnits: units, rows: rows.count)
            totalHeight = m.height
        } else {
            m = KeyboardGeometry.metrics(visibleWidth: visible.width, visibleHeight: visible.height - bar,
                                         maxUnits: units, rows: rows.count)
            totalHeight = m.height + bar
        }
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: m.width, height: totalHeight))
        root.material = .hudWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 14

        // toolbar
        let barY = totalHeight - bar
        let drag = DragBar(frame: NSRect(x: 0, y: barY, width: m.width, height: bar))
        drag.controller = self
        drag.setAccessibilityLabel("Move keyboard")
        root.addSubview(drag)
        let opacity = BarButton("◐ \(Int(settings.opacity * 100))%", label: "Keyboard transparency") { [weak self] in self?.cycleOpacity() }
        opacity.frame = NSRect(x: 8, y: barY, width: 86, height: bar)
        root.addSubview(opacity)
        opacityButton = opacity
        let modeTitle = settings.mode == .floating ? "⤓ Dock" : "⧉ Float"
        let mode = BarButton(modeTitle, label: settings.mode == .floating ? "Dock keyboard" : "Float keyboard") { [weak self] in self?.toggleMode() }
        mode.frame = NSRect(x: 98, y: barY, width: 86, height: bar)
        root.addSubview(mode)
        if settings.mode == .floating {
            let grip = ResizeGrip(frame: NSRect(x: m.width - bar - 4, y: barY, width: bar, height: bar))
            grip.controller = self
            grip.setAccessibilityLabel("Resize keyboard")
            root.addSubview(grip)
        }

        // keys
        keyViews = []
        let fontSize = CGFloat(min(max(m.keyHeight * 0.36, 12), 28))
        for (r, row) in rows.enumerated() {
            let rowUnits = row.reduce(0) { $0 + $1.width }
            var x = (m.width - rowUnits * m.unit) / 2
            let y = barY - m.padding - Double(r + 1) * m.keyHeight
            for key in row {
                let kv = KeyView(key: key, title: state.displayLabel(for: key), fontSize: fontSize)
                kv.controller = self
                kv.frame = NSRect(x: x, y: y, width: key.width * m.unit, height: m.keyHeight)
                if key.action == .shift { kv.latched = state.shift }
                if key.action == .capsLock { kv.latched = state.capsLock }
                root.addSubview(kv)
                keyViews.append(kv)
                x += key.width * m.unit
            }
        }
        // keep the top edge where it was when the size changes
        let oldTop = panel.frame.maxY
        let wasPlaced = panel.frame.width > 0
        panel.contentView = root
        panel.setContentSize(NSSize(width: m.width, height: totalHeight))
        if wasPlaced && settings.mode == .floating {
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: oldTop - CGFloat(totalHeight)))
        }
    }

    // MARK: floating / transparency

    func cycleOpacity() {
        settings.cycleOpacity()
        panel.alphaValue = CGFloat(settings.opacity)
        opacityButton?.title = "◐ \(Int(settings.opacity * 100))%"
        saveSettings()
    }

    func toggleMode() {
        guard let screen = currentScreen ?? NSScreen.main else { return }
        settings.mode = settings.mode == .floating ? .docked : .floating
        rebuild(on: screen)
        place(on: screen, field: lastField)
        saveSettings()
    }

    func dragBegan() {
        guard settings.mode == .docked, let screen = currentScreen ?? NSScreen.main else { return }
        // dragging the docked keyboard undocks it, keeping the bar under the finger
        let top = panel.frame.maxY, left = panel.frame.minX
        settings.mode = .floating
        settings.floatWidth = min(settings.floatWidth, Double(panel.frame.width))
        rebuild(on: screen)
        panel.setFrameOrigin(NSPoint(x: left, y: top - panel.frame.height))
    }

    func dragMoved(to origin: NSPoint) {
        guard let screen = currentScreen ?? NSScreen.main else { return }
        let (x, y) = FloatingGeometry.clampOrigin(x: Double(origin.x), y: Double(origin.y),
                                                  size: (Double(panel.frame.width), Double(panel.frame.height)),
                                                  visible: visibleRect(screen))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func dragEnded() {
        settings.floatX = Double(panel.frame.minX)
        settings.floatY = Double(panel.frame.minY)
        saveSettings()
    }

    func resizeBegan() {
        resizeStart = (Double(panel.frame.width), Double(panel.frame.maxY), Double(panel.frame.minX))
    }

    func resizeMoved(dx: Double) {
        guard let st = resizeStart, let screen = currentScreen ?? NSScreen.main else { return }
        let r = FloatingGeometry.resize(startWidth: st.width, startTop: st.top, startX: st.x, dx: dx,
                                        maxUnits: Layouts.maxUnits(for: state.layer),
                                        rows: Layouts.rows(for: state.layer).count, visible: visibleRect(screen))
        if abs(r.width - Double(panel.frame.width)) < 4 { return }   // avoid rebuilding for tiny moves
        settings.floatWidth = r.width
        rebuild(on: screen)
        panel.setFrameOrigin(NSPoint(x: r.x, y: r.y))
    }

    func resizeEnded() {
        resizeStart = nil
        dragEnded()
    }

    private func refreshLabels() {
        for kv in keyViews {
            kv.title = state.displayLabel(for: kv.key)
            if kv.key.action == .shift { kv.latched = state.shift }
            if kv.key.action == .capsLock { kv.latched = state.capsLock }
        }
    }

    // MARK: touch handling

    func touch(_ e: TouchSequencer.Event, on view: KeyView) {
        let t = now()
        switch sequencer.handle(e, at: t) {
        case .began:
            activeKey = view
            view.setPressed(true)
            pressStart = t
            repeatsFired = 0
            fire(view.key)
            if view.key.repeats { startRepeat() }
        case .continued, .ignored, .ended:
            break
        }
        if e == .up {
            flushTimer?.invalidate()
            flushTimer = Timer.scheduledTimer(withTimeInterval: sequencer.handoverWindow + 0.02, repeats: false) { [weak self] _ in
                self?.flushTouch()
            }
        }
    }

    private func flushTouch() {
        if sequencer.flush(at: now()) == .ended {
            repeatTimer?.invalidate()
            repeatTimer = nil
            activeKey?.setPressed(false)
            activeKey = nil
        }
    }

    private func startRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self, let key = self.activeKey?.key else { return }
            let due = self.repeatPolicy.repeats(after: now() - self.pressStart)
            while self.repeatsFired < due {
                self.repeatsFired += 1
                self.fire(key)
            }
        }
    }

    private func fire(_ key: Key) {
        lastKeyPress = now()
        let wasLayer = state.layer
        let (output, redraw) = state.press(key)
        EventPoster.emit(output)
        if state.hideRequested {
            manuallyHidden = true
            pinned = false
            hide()
            return
        }
        if redraw {
            if wasLayer != state.layer, let s = currentScreen {
                rebuild(on: s)
                place(on: s, field: lastField)
            } else {
                refreshLabels()
            }
        }
    }

    // MARK: show / hide

    private func place(on screen: NSScreen, field: Rect?) {
        let visible = visibleRect(screen)
        let size = (Double(panel.frame.width), Double(panel.frame.height))
        if settings.mode == .floating {
            // floating keyboards stay exactly where the user put them
            let (dx, dy) = FloatingGeometry.defaultOrigin(size: size, visible: visible)
            let (x, y) = FloatingGeometry.clampOrigin(x: settings.floatX ?? dx, y: settings.floatY ?? dy,
                                                      size: size, visible: visible)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        let (x, y) = KeyboardGeometry.placement(visible: visible,
                                                size: (Double(panel.frame.width), Double(panel.frame.height)),
                                                field: field)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show(on screen: NSScreen, field: Rect?) {
        lastField = field
        if currentScreen != screen || keyViews.isEmpty {
            currentScreen = screen
            rebuild(on: screen)
        }
        place(on: screen, field: field)
        if panel.isVisible { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = CGFloat(settings.opacity)
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        state.resetTransient()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            if let s = self?.currentScreen { self?.rebuild(on: s) }
        })
    }

    func screenParametersChanged() {
        guard let s = currentScreen.flatMap({ cur in NSScreen.screens.first { $0 == cur } }) ?? NSScreen.main else { return }
        currentScreen = s
        rebuild(on: s)
        if panel.isVisible { place(on: s, field: lastField) }
    }
}

// MARK: - Floating show/hide button

final class ToggleButtonController {
    let panel: KeyboardPanel
    var onTap: (() -> Void)?

    init() {
        panel = KeyboardPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
                              styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        let button = NSButton(title: "⌨", target: nil, action: nil)
        button.font = .systemFont(ofSize: 28)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 30
        button.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        button.frame = NSRect(x: 0, y: 0, width: 60, height: 60)
        button.target = self
        button.action = #selector(tapped)
        button.setAccessibilityLabel("Show or hide the on-screen keyboard")
        panel.contentView = button
    }

    @objc private func tapped() { onTap?() }

    func show() {
        guard let s = NSScreen.main else { return }
        let vf = s.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.maxX - 72, y: vf.minY + 12))
        panel.orderFrontRegardless()
    }
}

// MARK: - Focus watcher (event driven, with polling fallback)

final class FocusWatcher {
    let keyboard: KeyboardController
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var debouncer = HideDebouncer()
    private var pollTimer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(keyboard: KeyboardController) { self.keyboard = keyboard }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.attachToFrontmost()
            self?.evaluate()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.observedPID = 0
            self?.attachToFrontmost()
            self?.evaluate()
        }
        attachToFrontmost()
        // Fallback for apps that do not deliver focus notifications reliably.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.attachToFrontmost()
            self?.evaluate()
        }
        evaluate()
    }

    private func attachToFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        if pid == observedPID || pid == ownPID { return }
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
            observer = nil
        }
        observedPID = pid
        let appEl = AXUIElementCreateApplication(pid)
        // Chromium/Electron only build their accessibility tree once an
        // assistive client announces itself.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { me.evaluate() }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString, ref)
        AXObserverAddNotification(obs, appEl, kAXFocusedWindowChangedNotification as CFString, ref)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    func evaluate() {
        if keyboard.pinned {
            if !keyboard.isVisible, let s = NSScreen.main { keyboard.show(on: s, field: nil) }
            return
        }
        let (info, frame) = focusedElement()
        switch FocusClassifier.classify(info) {
        case .ownPanel:
            return
        case .text:
            debouncer.text()
            if !keyboard.manuallyHidden {
                let (screen, field) = screenAndField(for: frame)
                keyboard.show(on: screen, field: field)
            }
        case .notText:
            if debouncer.notText(now: now(), lastKeyPress: keyboard.lastKeyPress) {
                keyboard.manuallyHidden = false
                keyboard.hide()
            }
        }
    }

    private func copyAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private func focusedElement() -> (FocusInfo, CGRect?) {
        let sys = AXUIElementCreateSystemWide()
        var focused = copyAttr(sys, kAXFocusedUIElementAttribute)
        if focused == nil, observedPID > 0 {
            focused = copyAttr(AXUIElementCreateApplication(observedPID), kAXFocusedUIElementAttribute)
        }
        guard let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else {
            return (FocusInfo(role: nil), nil)
        }
        let el = f as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        if pid == ownPID { return (FocusInfo(role: nil, isOwnProcess: true), nil) }

        var names: CFArray?
        _ = AXUIElementCopyAttributeNames(el, &names)
        let info = FocusInfo(role: copyAttr(el, kAXRoleAttribute) as? String,
                             subrole: copyAttr(el, kAXSubroleAttribute) as? String,
                             attributeNames: (names as? [String]) ?? [],
                             isEditableFlag: copyAttr(el, "AXEditable") as? Bool)
        var frame: CGRect?
        if let p = copyAttr(el, kAXPositionAttribute), let s = copyAttr(el, kAXSizeAttribute),
           CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() {
            var pt = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &pt)
            AXValueGetValue(s as! AXValue, .cgSize, &sz)
            frame = CGRect(origin: pt, size: sz)
        }
        return (info, frame)
    }

    private func screenAndField(for frame: CGRect?) -> (NSScreen, Rect?) {
        let fallback = NSScreen.main ?? NSScreen.screens[0]
        guard let f = frame else { return (fallback, nil) }
        let primaryH = Double(NSScreen.screens.first?.frame.height ?? fallback.frame.height)
        let field = KeyboardGeometry.axToAppKit(Rect(x: Double(f.minX), y: Double(f.minY),
                                                     width: Double(f.width), height: Double(f.height)),
                                                primaryScreenHeight: primaryH)
        let mid = NSPoint(x: field.x + field.width / 2, y: field.y + field.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(mid) } ?? fallback
        return (screen, field)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var keyboard: KeyboardController!
    var watcher: FocusWatcher!
    var toggle: ToggleButtonController!
    var statusItem: NSStatusItem!
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyboard = KeyboardController()
        watcher = FocusWatcher(keyboard: keyboard)
        toggle = ToggleButtonController()
        toggle.onTap = { [weak self] in self?.toggleKeyboard() }
        toggle.show()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "⌨"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Keyboard", action: #selector(showKb), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide Keyboard (automatic mode)", action: #selector(hideKb), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SurfaceTouchKeys", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.keyboard.screenParametersChanged()
            self?.toggle.show()
        }

        // Accessibility approval is a one-time user action (macOS requires it;
        // we never modify the TCC database). Until approved, the manual button
        // still works for showing the keyboard, but automatic opening and typing
        // need the approval.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            watcher.start()
        } else {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() {
                    t.invalidate()
                    self?.watcher.start()
                }
            }
        }
    }

    func toggleKeyboard() {
        if keyboard.isVisible {
            hideKb()
        } else {
            showKb()
        }
    }

    @objc func showKb() {
        keyboard.manuallyHidden = false
        keyboard.pinned = true
        if let s = NSScreen.main { keyboard.show(on: s, field: nil) }
    }

    @objc func hideKb() {
        keyboard.manuallyHidden = true
        keyboard.pinned = false
        keyboard.hide()
    }
}

// MARK: - Entry point

let args = CommandLine.arguments
if args.contains("--version") {
    print("SurfaceTouchKeys \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
    exit(0)
}
if let i = args.firstIndex(of: "--ci-selftest") {
    // Non-interactive checks used by CI (see keyboard/ci/keyboard-ci.sh).
    _ = i
    exit(CISelfTest.run(arguments: args) ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
