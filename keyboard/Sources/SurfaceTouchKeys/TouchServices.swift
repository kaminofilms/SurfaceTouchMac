// SPDX-License-Identifier: MIT
// SurfaceTouchMac touch services (run inside SurfaceTouchKeys):
//   * hide the mouse pointer while the touchscreen is used, show it again for
//     the Type Cover trackpad or a mouse
//   * edge swipes: top -> Notification Center, bottom -> Mission Control,
//     left/right -> previous/next desktop
//   * big touch menus: a menu-bar menu opened by touch is shown as a large,
//     finger-friendly list; tapping a row performs the real menu item
//
// Uses one event tap (needs the Accessibility permission the keyboard already
// has). No events are logged or stored; menu titles are read only to draw the
// big menu.

import AppKit
import ApplicationServices
import os
import TouchKeyboardCore

/// Diagnostics only: which input was detected and what the pointer did.
/// Never logs typed text, keys or what is on screen.
/// Read with: log show --last 5m --predicate 'subsystem == "com.kaminofilms.surfacetouchkeys"'
let touchLog = Logger(subsystem: "com.kaminofilms.surfacetouchkeys", category: "touch")

// MARK: - Settings (menu-bar toggles)

enum TouchPrefs {
    static let d = UserDefaults.standard
    static var hidePointer: Bool { get { d.object(forKey: "hidePointer") as? Bool ?? true } set { d.set(newValue, forKey: "hidePointer") } }
    static var edgeSwipes: Bool { get { d.object(forKey: "edgeSwipes") as? Bool ?? true } set { d.set(newValue, forKey: "edgeSwipes") } }
    static var bigMenus: Bool { get { d.object(forKey: "bigMenus") as? Bool ?? true } set { d.set(newValue, forKey: "bigMenus") } }
    static var typingAssist: Bool { get { d.object(forKey: "typingAssist") as? Bool ?? true } set { d.set(newValue, forKey: "typingAssist") } }
}

// MARK: - Pointer hiding (works while another app is frontmost)

enum PointerVisibility {
    private typealias DefaultConn = @convention(c) () -> Int32
    private typealias SetProp = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static var hideCount = 0
    private static var prepared = false
    private(set) static var wantHidden = false

    /// Lets a background app hide the cursor (private CoreGraphics property,
    /// looked up at run time; if unavailable, hiding is simply skipped).
    private static func prepare() -> Bool {
        if prepared { return true }
        guard let h = dlopen(nil, RTLD_NOW),
              let c = dlsym(h, "_CGSDefaultConnection"),
              let s = dlsym(h, "CGSSetConnectionProperty") else {
            touchLog.notice("pointer: hiding not available (CoreGraphics symbols missing)")
            return false
        }
        let conn = unsafeBitCast(c, to: DefaultConn.self)()
        let rc = unsafeBitCast(s, to: SetProp.self)(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        touchLog.notice("pointer: background hiding enabled (rc=\(rc, privacy: .public))")
        prepared = true
        return true
    }

    static func set(hidden h: Bool) {
        if h == wantHidden { if h { reassert() }; return }
        wantHidden = h
        touchLog.notice("pointer: \(h ? "hide" : "show", privacy: .public)")
        if h {
            reassert()
        } else {
            while hideCount > 0 { CGDisplayShowCursor(CGMainDisplayID()); hideCount -= 1 }
        }
    }

    /// macOS shows the pointer again when it moves, and every finger tap
    /// moves it: hide it again (net hide count stays at 1).
    static func reassert() {
        guard wantHidden, prepare() else { return }
        if hideCount > 0 { CGDisplayShowCursor(CGMainDisplayID()); hideCount -= 1 }
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
    }
}

// MARK: - Actions

enum SystemActions {
    static func perform(_ edge: ScreenEdge) {
        switch edge {
        case .top: openNotificationCenter()
        case .bottom: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        case .left: postKey(123, flags: .maskControl)      // previous desktop
        case .right: postKey(124, flags: .maskControl)     // next desktop
        }
    }

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = (123...126).contains(code) ? flags.union([.maskSecondaryFn, .maskNumericPad]) : flags
            e.post(tap: .cghidEventTap)
        }
    }

    /// Notification Center opens from the clock in the menu bar (Control Center process).
    static func openNotificationCenter() {
        guard let cc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else { return }
        let app = AXUIElementCreateApplication(cc.processIdentifier)
        var bars: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bars) == .success,
              let bar = bars, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return }
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
        for item in (kids as? [AXUIElement]) ?? [] {
            var ident: CFTypeRef?
            AXUIElementCopyAttributeValue(item, "AXIdentifier" as CFString, &ident)
            if (ident as? String) == "com.apple.menuextra.clock" {
                AXUIElementPerformAction(item, kAXPressAction as CFString)
                return
            }
        }
    }
}

// MARK: - Big touch menus

struct MenuRow {
    let element: AXUIElement
    let title: String
    let enabled: Bool
    let checked: Bool
    let submenu: AXUIElement?
    var isSeparator: Bool { title.isEmpty && submenu == nil }
}

enum MenuReader {
    static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func rows(of menu: AXUIElement) -> [MenuRow] {
        guard let kids = attr(menu, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        var out: [MenuRow] = []
        for item in kids {
            guard (attr(item, kAXRoleAttribute) as? String) == "AXMenuItem" else { continue }
            let title = attr(item, kAXTitleAttribute) as? String ?? ""
            // hidden Option/Shift alternates ("Restart" next to "Restart…")
            // (an alternate points at a different item as its primary; ordinary items
            // report themselves or nothing)
            if let pr = attr(item, "AXMenuItemPrimaryUIElement"), CFGetTypeID(pr) == AXUIElementGetTypeID(),
               !CFEqual(pr, item) { continue }
            if MenuAlternates.repeatsPrevious(title, previous: out.last?.title) { continue }
            let enabled = attr(item, kAXEnabledAttribute) as? Bool ?? true
            let mark = attr(item, "AXMenuItemMarkChar") as? String ?? ""
            let sub = (attr(item, kAXChildrenAttribute) as? [AXUIElement])?.first {
                (attr($0, kAXRoleAttribute) as? String) == "AXMenu"
            }
            out.append(MenuRow(element: item, title: title, enabled: enabled, checked: !mark.isEmpty, submenu: sub))
        }
        // drop leading/trailing/double separators
        var cleaned: [MenuRow] = []
        for r in out where !(r.isSeparator && (cleaned.isEmpty || cleaned.last!.isSeparator)) { cleaned.append(r) }
        while cleaned.last?.isSeparator == true { cleaned.removeLast() }
        return cleaned
    }

    /// The menu-bar item that owns an opened menu, or nil for other menus.
    static func menuBarItem(of menu: AXUIElement) -> AXUIElement? {
        guard let p = attr(menu, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
        let parent = p as! AXUIElement
        return (attr(parent, kAXRoleAttribute) as? String) == "AXMenuBarItem" ? parent : nil
    }
}

final class RowView: NSView {
    let row: MenuRow
    var onTap: ((MenuRow) -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }
    static let height: CGFloat = 46

    init(row: MenuRow, width: CGFloat) {
        self.row = row
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: row.isSeparator ? 13 : Self.height))
        if !row.isSeparator {
            let label = NSTextField(labelWithString: (row.checked ? "✓  " : "") + row.title + (row.submenu != nil ? "  ›" : ""))
            label.font = .systemFont(ofSize: 19)
            label.textColor = row.enabled ? .labelColor : .tertiaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 18, y: (Self.height - 24) / 2, width: width - 36, height: 24)
            addSubview(label)
            setAccessibilityRole(.menuItem)
            setAccessibilityLabel(row.title)
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        if row.isSeparator {
            NSColor.separatorColor.setFill()
            NSRect(x: 12, y: bounds.midY, width: bounds.width - 24, height: 1).fill()
        } else if pressed {
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if row.enabled && !row.isSeparator { pressed = true } }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        onTap?(row)
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class TouchMenuController {
    let panel: KeyboardPanel
    private var stack: [(title: String, rows: [MenuRow])] = []
    private var anchor = NSPoint.zero

    init() {
        panel = KeyboardPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.setAccessibilityLabel("Touch menu")
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows a menu-bar menu as a big touch list. `menu` is the opened AXMenu.
    func present(rows: [MenuRow], title: String, at topLeft: NSPoint) -> Bool {
        guard !rows.isEmpty else { return false }
        anchor = topLeft
        stack = [(title, rows)]
        render()
        return true
    }

    func close() {
        stack = []
        panel.orderOut(nil)
    }

    func contains(screenPoint p: NSPoint) -> Bool { panel.isVisible && panel.frame.contains(p) }

    private func render() {
        guard let page = stack.last, let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main else { return }
        let width: CGFloat = 340
        var views: [NSView] = []
        if stack.count > 1 {
            let back = RowView(row: MenuRow(element: AXUIElementCreateSystemWide(), title: "‹  " + stack[stack.count - 2].title,
                                            enabled: true, checked: false, submenu: nil), width: width)
            back.onTap = { [weak self] _ in self?.stack.removeLast(); self?.render() }
            views.append(back)
        }
        for r in page.rows {
            let v = RowView(row: r, width: width)
            v.onTap = { [weak self] row in self?.tapped(row) }
            views.append(v)
        }
        let contentH = views.reduce(0) { $0 + $1.frame.height } + 12
        let maxH = screen.visibleFrame.height - 20
        let h = min(contentH, maxH)

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        root.material = .menu
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: contentH))
        var y: CGFloat = 6
        for v in views { v.frame.origin = NSPoint(x: 0, y: y); doc.addSubview(v); y += v.frame.height }
        let scroll = NSScrollView(frame: root.bounds)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = contentH > h
        scroll.documentView = doc
        root.addSubview(scroll)
        panel.contentView = root
        panel.setContentSize(NSSize(width: width, height: h))
        let vf = screen.visibleFrame
        let x = min(max(anchor.x, vf.minX), vf.maxX - width)
        let top = min(anchor.y, vf.maxY)
        panel.setFrameOrigin(NSPoint(x: x, y: max(top - h, vf.minY)))
        panel.orderFrontRegardless()
    }

    private func tapped(_ row: MenuRow) {
        if let sub = row.submenu {
            stack.append((row.title, MenuReader.rows(of: sub)))
            render()
            return
        }
        close()
        AXUIElementPerformAction(row.element, kAXPressAction as CFString)
    }
}

// MARK: - Coordinator: event tap + menu observer

final class TouchServices {
    static var shared: TouchServices?

    private var tap: CFMachPort?
    private var tracker = PointerSourceTracker()
    private var edge = EdgeSwipeDetector()
    private var swallowingScroll = false
    private var lastLocation: CGPoint?
    private(set) var lastTouchAt = -1000.0
    let menus = TouchMenuController()
    private var menuObserver: AXObserver?
    private var observedPID: pid_t = 0
    /// Called on any click outside our own windows (resets typing context).
    var onOutsideClick: (() -> Void)?

    var isTouchActive: Bool { tracker.source == .touch }

    func start() {
        var mask: CGEventMask = [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .scrollWheel]
            .reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
        mask |= 1 << 29          // NSEventTypeGesture: fingers on the trackpad (not the touchscreen)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<TouchServices>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        touchLog.notice("touch services: event tap \(self.tap != nil ? "running" : "NOT created (no Accessibility permission?)", privacy: .public)")
        if let tap {
            let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.observeMenus() }
        observeMenus()
    }

    private var reassertPending = false
    /// Hide the pointer again just after this event has moved it.
    private func scheduleReassert() {
        guard TouchPrefs.hidePointer, !reassertPending else { return }
        reassertPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.reassertPending = false
            PointerVisibility.reassert()
        }
    }

    private func primaryHeight() -> CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type.rawValue == 29 {          // trackpad gesture: show the pointer
            if let s = tracker.trackpadActivity(now: ProcessInfo.processInfo.systemUptime) {
                touchLog.notice("input: trackpad")
                if TouchPrefs.hidePointer { PointerVisibility.set(hidden: s == .touch) }
            }
            return Unmanaged.passUnretained(event)
        }
        let loc = event.location
        switch type {
        case .mouseMoved, .leftMouseDown, .leftMouseDragged, .rightMouseDown:
            let prev = lastLocation ?? loc
            lastLocation = loc
            let tablet = event.getIntegerValueField(.mouseEventSubtype) == Int64(CGEventMouseSubtype.tabletPoint.rawValue)
            let button = type != .mouseMoved
            let dockBand = Double(primaryHeight() - loc.y) <= Double(primaryHeight()) * 0.07
            if let s = tracker.moved(dx: Double(loc.x - prev.x), dy: Double(loc.y - prev.y), buttonDown: button, tablet: tablet,
                                     now: ProcessInfo.processInfo.systemUptime, inDockBand: dockBand) {
                touchLog.notice("input: \(s == .touch ? "touchscreen" : "mouse/trackpad", privacy: .public) (subtype tablet=\(tablet, privacy: .public))")
                if TouchPrefs.hidePointer { PointerVisibility.set(hidden: s == .touch) }
            }
            if tracker.source == .touch {
                lastTouchAt = ProcessInfo.processInfo.systemUptime
                scheduleReassert()
            }
            if type == .leftMouseDown || type == .rightMouseDown {
                let p = NSPoint(x: loc.x, y: primaryHeight() - loc.y)
                if menus.isVisible && !menus.contains(screenPoint: p) {
                    DispatchQueue.main.async { self.menus.close() }
                }
                if !(NSApp.windows.contains { $0.isVisible && $0.frame.contains(p) }) {
                    DispatchQueue.main.async { self.onOutsideClick?() }
                }
            }
        case .leftMouseUp:
            if tracker.source == .touch { scheduleReassert() }
        case .scrollWheel:
            return handleScroll(event)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)   // 1 began, 2 changed, 4 ended, 8 cancelled
        if phase == 1 {
            swallowingScroll = false
            if TouchPrefs.edgeSwipes && tracker.source == .touch,
               let screen = NSScreen.screens.first {
                let loc = event.location
                let p = (Double(loc.x), Double(primaryHeight() - loc.y))
                let f = screen.frame
                let menuBar = Double(f.maxY - screen.visibleFrame.maxY)
                let r = Rect(x: Double(f.minX), y: Double(f.minY), width: Double(f.width), height: Double(f.height))
                swallowingScroll = edge.begin(at: p, screen: r, menuBarHeight: min(menuBar, 40))
            }
        }
        guard swallowingScroll else { return Unmanaged.passUnretained(event) }
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        if let e = edge.add(dx: dx, dy: dy) {
            DispatchQueue.main.async { SystemActions.perform(e) }
        }
        if phase == 4 || phase == 8 {
            edge.end()
            swallowingScroll = false
        }
        return nil      // the content under an edge swipe must not scroll
    }

    // MARK: menus

    private func observeMenus() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        if pid == observedPID || pid == ProcessInfo.processInfo.processIdentifier { return }
        if let old = menuObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
            menuObserver = nil
        }
        observedPID = pid
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<TouchServices>.fromOpaque(refcon).takeUnretainedValue()
            me.menuOpened(element)
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        AXObserverAddNotification(obs, AXUIElementCreateApplication(pid), kAXMenuOpenedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        menuObserver = obs
    }

    private func menuOpened(_ menu: AXUIElement) {
        guard TouchPrefs.bigMenus,
              ProcessInfo.processInfo.systemUptime - lastTouchAt < 1.5,
              let barItem = MenuReader.menuBarItem(of: menu) else { return }
        let title = MenuReader.attr(barItem, kAXTitleAttribute) as? String ?? ""
        var anchor = NSPoint(x: 100, y: (NSScreen.main?.visibleFrame.maxY ?? 800))
        if let pv = MenuReader.attr(barItem, kAXPositionAttribute), CFGetTypeID(pv) == AXValueGetTypeID() {
            var pt = CGPoint.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
            anchor = NSPoint(x: pt.x, y: primaryHeight() - pt.y - 26)
        }
        // read the items while the menu is open, then close the tiny system
        // menu and show the big one instead
        let rows = MenuReader.rows(of: menu)
        guard !rows.isEmpty else { return }
        SystemActions.postKey(53, flags: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            _ = self?.menus.present(rows: rows, title: title, at: anchor)
        }
    }
}
