// SPDX-License-Identifier: MIT
// Automated checks for CI runners (keyboard/ci/keyboard-ci.sh drives this).
//
//   --ci-selftest                 structural checks only (no permissions needed)
//   --ci-selftest --interactive   also: detect TextEdit's focused text area,
//                                 tap keys with synthetic mouse events, verify
//                                 TextEdit stays frontmost (needs Accessibility)
//
// Results are printed as "CHECK <name> PASS|FAIL|SKIP <detail>" lines.

import AppKit
import ApplicationServices
import TouchKeyboardCore

enum CISelfTest {
    static var failures = 0

    static func report(_ name: String, _ ok: Bool?, _ detail: String = "") {
        let s = ok == nil ? "SKIP" : (ok! ? "PASS" : "FAIL")
        if ok == false { failures += 1 }
        print("CHECK \(name) \(s) \(detail)")
        fflush(stdout)
    }

    /// Runs the AppKit event loop for `seconds` so synthetic clicks are
    /// actually dispatched to our windows (RunLoop.run alone does not).
    static func pump(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let ev = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
                NSApp.sendEvent(ev)
            }
        }
    }

    static func run(arguments: [String]) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let interactive = arguments.contains("--interactive")

        let kb = KeyboardController()
        report("panel_nonactivating", kb.panel.styleMask.contains(.nonactivatingPanel))
        report("panel_never_key", !kb.panel.canBecomeKey && !kb.panel.canBecomeMain)

        guard let screen = NSScreen.main else {
            report("screen_available", false, "no NSScreen")
            return false
        }
        kb.show(on: screen, field: nil)
        let vf = screen.visibleFrame
        report("fits_screen", vf.contains(kb.panel.frame), "panel=\(kb.panel.frame) visible=\(vf)")
        let keys = allKeyViews(kb)
        let minH = keys.map { $0.frame.height }.min() ?? 0
        let minW = keys.map { $0.frame.width }.min() ?? 0
        report("touch_sized_keys", minH >= 44 && minW >= 44, "min=\(Int(minW))x\(Int(minH))pt keys=\(keys.count)")

        // Surface Pro 7 display (2736x1824 @2x = 1368x912 pt) sizing, computed offline
        let m = KeyboardGeometry.metrics(visibleWidth: 1368, visibleHeight: 912 - 25,
                                         maxUnits: Layouts.maxUnits(for: .letters), rows: 5)
        report("surface_pro7_metrics", m.width <= 1368 && m.height <= 0.45 * 887 && m.keyHeight >= 44,
               "unit=\(Int(m.unit)) keyH=\(Int(m.keyHeight)) size=\(Int(m.width))x\(Int(m.height))")

        // floating / resizable / transparent
        kb.toggleMode()
        let fl = kb.panel.frame
        let fkeys = allKeyViews(kb)
        report("floating_mode", kb.settings.mode == .floating && vf.contains(fl),
               "frame=\(fl) width=\(Int(kb.settings.floatWidth))")
        report("floating_keys_usable", (fkeys.map { $0.frame.height }.min() ?? 0) >= 26, "keys=\(fkeys.count)")
        kb.dragMoved(to: NSPoint(x: vf.minX - 500, y: vf.maxY + 500))
        report("drag_clamped_on_screen", vf.contains(kb.panel.frame), "frame=\(kb.panel.frame)")
        kb.resizeBegan(); kb.resizeMoved(dx: -2000); kb.resizeEnded()
        report("resize_min_width", abs(Double(kb.panel.frame.width) - KeyboardSettings.minWidth) < 2,
               "width=\(Int(kb.panel.frame.width))")
        kb.cycleOpacity()
        report("opacity_applies", abs(kb.panel.alphaValue - 0.85) < 0.01, "alpha=\(kb.panel.alphaValue)")
        for _ in 0..<3 { kb.cycleOpacity() }          // back to 100%
        kb.toggleMode()                               // back to docked (saved for the next run)
        report("docked_restored", kb.settings.mode == .docked && abs(kb.panel.alphaValue - 1) < 0.01)

        // accent pop-up on long press
        if let e = allKeyViews(kb).first(where: { $0.key.label == "e" }) {
            report("accent_popup", kb.longPress(on: e), "long press on e")
            kb.closeAccents()
        }
        if let k = allKeyViews(kb).first(where: { $0.key.label == "k" }) {
            report("no_accents_for_k", !kb.longPress(on: k))
        }

        if !interactive {
            kb.hide()
            return failures == 0
        }

        // ---- interactive: requires Accessibility for this binary ----
        guard AXIsProcessTrusted() else {
            report("accessibility_trusted", nil, "runner did not grant Accessibility; interactive checks skipped")
            return failures == 0
        }
        report("accessibility_trusted", true)

        let deadline = Date().addingTimeInterval(20)
        var textEdit: NSRunningApplication?
        while Date() < deadline {
            textEdit = NSWorkspace.shared.frontmostApplication
            if textEdit?.bundleIdentifier == "com.apple.TextEdit" { break }
            pump(0.25)
        }
        guard let te = textEdit, te.bundleIdentifier == "com.apple.TextEdit" else {
            report("textedit_frontmost", false, "frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
            return false
        }
        report("textedit_frontmost", true)

        // Focus detection (same code path the app uses)
        let watcher = FocusWatcher(keyboard: kb)
        kb.hide()
        pump(0.5)
        watcher.start()
        var shown = false
        let showDeadline = Date().addingTimeInterval(5)
        while Date() < showDeadline && !shown {
            pump(0.2)
            shown = kb.isVisible
        }
        report("auto_show_on_text_focus", shown)

        // Tap "h", "i" with synthetic mouse clicks on the key views
        for label in ["h", "i"] {
            guard let kv = allKeyViews(kb).first(where: { $0.key.label == label }) else {
                report("tap_\(label)", false, "key not found"); continue
            }
            let p = screenCenter(of: kv)
            click(at: p)
            pump(0.4)
        }
        pump(0.6)
        report("taps_reached_keys", EventPoster.emitted == 2, "key outputs emitted by taps: \(EventPoster.emitted)")
        // Post one character directly too, to tell "tap not delivered" apart
        // from "event posting blocked" if the typed_text check fails.
        EventPoster.type("!")
        pump(0.6)
        report("post_event_access", CGPreflightPostEventAccess(), "CGPreflightPostEventAccess")
        // CI-only diagnostic on the throwaway TextEdit document: length of the
        // focused element's text (never its content).
        var len = -1
        let sys = AXUIElementCreateSystemWide()
        var f: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f,
           CFGetTypeID(f) == AXUIElementGetTypeID() {
            var n: CFTypeRef?
            if AXUIElementCopyAttributeValue(f as! AXUIElement, kAXNumberOfCharactersAttribute as CFString, &n) == .success {
                len = (n as? Int) ?? -1
            }
        }
        report("focused_text_length", len == 3, "characters in TextEdit document: \(len) (expected 3)")
        // auto-capital at the start of the empty document. CI-only: reads the
        // throwaway TextEdit document to verify (the app never reads text).
        var docText = ""
        let sysEl = AXUIElementCreateSystemWide()
        var fe: CFTypeRef?
        if AXUIElementCopyAttributeValue(sysEl, kAXFocusedUIElementAttribute as CFString, &fe) == .success, let fe,
           CFGetTypeID(fe) == AXUIElementGetTypeID() {
            docText = MenuReader.attr(fe as! AXUIElement, kAXValueAttribute) as? String ?? ""
        }
        report("auto_capital_start", docText.hasPrefix("H"), "document starts with '\(docText.prefix(3))'")

        // big touch menu built from TextEdit's real Edit menu
        let teApp = AXUIElementCreateApplication(te.processIdentifier)
        var menuRows: [MenuRow] = []
        if let bar = MenuReader.attr(teApp, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID(),
           let items = MenuReader.attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
           let edit = items.first(where: { (MenuReader.attr($0, kAXTitleAttribute) as? String) == "Edit" }),
           let menu = (MenuReader.attr(edit, kAXChildrenAttribute) as? [AXUIElement])?.first {
            menuRows = MenuReader.rows(of: menu)
        }
        report("touch_menu_reads_items", menuRows.filter { !$0.isSeparator }.count >= 5, "rows=\(menuRows.count)")
        let tm = TouchMenuController()
        if tm.present(rows: menuRows, title: "Edit", at: NSPoint(x: 200, y: screen.visibleFrame.maxY)) {
            let rowViews = tm.panel.contentView.map { v -> [RowView] in
                func walk(_ x: NSView) -> [RowView] {
                    if let r = x as? RowView { return [r] }
                    return x.subviews.flatMap(walk)
                }
                return walk(v)
            } ?? []
            let minH = rowViews.filter { !$0.row.isSeparator }.map { $0.frame.height }.min() ?? 0
            report("touch_menu_rows_finger_sized", minH >= 44 && tm.isVisible, "rows=\(rowViews.count) minHeight=\(Int(minH))")
            tm.close()
        } else {
            report("touch_menu_rows_finger_sized", false, "overlay not shown")
        }

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        report("target_app_keeps_focus", front == "com.apple.TextEdit", "frontmost=\(front ?? "nil")")
        print("TYPED_EXPECTED hi!")
        return failures == 0
    }

    static func allKeyViews(_ kb: KeyboardController) -> [KeyView] {
        func walk(_ v: NSView) -> [KeyView] {
            var out: [KeyView] = []
            if let k = v as? KeyView { out.append(k) }
            for s in v.subviews { out += walk(s) }
            return out
        }
        guard let root = kb.panel.contentView else { return [] }
        return walk(root)
    }

    static func screenCenter(of v: NSView) -> CGPoint {
        let inWindow = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        let onScreen = v.window!.convertPoint(toScreen: inWindow)
        // CGEvent uses top-left origin of the primary display
        let primaryH = NSScreen.screens.first!.frame.height
        return CGPoint(x: onScreen.x, y: primaryH - onScreen.y)
    }

    static func click(at p: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(30_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
