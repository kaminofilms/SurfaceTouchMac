// SPDX-License-Identifier: MIT
// Floating / resizable / transparent keyboard: settings and geometry.
// Pure logic (no AppKit) so it is unit-tested.

public enum KeyboardMode: String, Sendable { case docked, floating }

public struct KeyboardSettings: Equatable, Sendable {
    public static let opacitySteps: [Double] = [1.0, 0.85, 0.65, 0.45]
    public static let minWidth = 420.0          // smallest floating keyboard (points)
    public static let toolbarHeight = 30.0      // drag bar on top of the keys

    public var mode: KeyboardMode = .docked
    public var opacity: Double = 1.0
    /// Floating frame in AppKit screen coordinates (bottom-left origin); nil = not placed yet.
    public var floatX: Double?
    public var floatY: Double?
    public var floatWidth: Double = 760

    public init() {}

    public mutating func cycleOpacity() {
        let steps = Self.opacitySteps
        let i = steps.firstIndex { abs($0 - opacity) < 0.01 } ?? 0
        opacity = steps[(i + 1) % steps.count]
    }

    // MARK: persistence (string dictionary, stored in UserDefaults by the app)

    public func encode() -> [String: String] {
        var d = ["mode": mode.rawValue, "opacity": String(opacity), "floatWidth": String(floatWidth)]
        if let x = floatX { d["floatX"] = String(x) }
        if let y = floatY { d["floatY"] = String(y) }
        return d
    }

    public static func decode(_ d: [String: String]) -> KeyboardSettings {
        var s = KeyboardSettings()
        if let m = d["mode"].flatMap(KeyboardMode.init(rawValue:)) { s.mode = m }
        if let o = d["opacity"].flatMap(Double.init) { s.opacity = min(max(o, 0.3), 1.0) }
        if let w = d["floatWidth"].flatMap(Double.init), w.isFinite { s.floatWidth = w }
        s.floatX = d["floatX"].flatMap(Double.init)
        s.floatY = d["floatY"].flatMap(Double.init)
        return s
    }
}

public enum FloatingGeometry {
    /// Key metrics for a keyboard of a given total width (floating mode).
    public static func metrics(width: Double, maxUnits: Double, rows: Int) -> KeyboardMetrics {
        let padding = 6.0
        let unit = max((width - 2 * padding) / maxUnits, 1)
        let keyHeight = min(max(unit * 0.85, 26), 72)
        let height = Double(rows) * keyHeight + 2 * padding + KeyboardSettings.toolbarHeight
        return KeyboardMetrics(unit: unit, keyHeight: keyHeight, padding: padding,
                               width: unit * maxUnits + 2 * padding, height: height)
    }

    /// Width limits for the visible screen.
    public static func clampWidth(_ w: Double, visible: Rect) -> Double {
        min(max(w, KeyboardSettings.minWidth), visible.width)
    }

    /// Keeps the keyboard fully on screen (at least the drag bar must stay reachable).
    public static func clampOrigin(x: Double, y: Double, size: (Double, Double), visible: Rect) -> (Double, Double) {
        let (w, h) = size
        let cx = min(max(x, visible.x), visible.maxX - w)
        let cy = min(max(y, visible.y), visible.maxY - h)
        return (cx, cy)
    }

    /// Default floating position: centred, a little above the bottom.
    public static func defaultOrigin(size: (Double, Double), visible: Rect) -> (Double, Double) {
        (visible.x + (visible.width - size.0) / 2, visible.y + 60)
    }

    /// Resize from the bottom-right grip: the top-left corner stays put.
    /// `dx` is the horizontal finger movement since the drag started.
    public static func resize(startWidth: Double, startTop: Double, startX: Double, dx: Double,
                              maxUnits: Double, rows: Int, visible: Rect) -> (x: Double, y: Double, width: Double) {
        let w = clampWidth(startWidth + dx, visible: Rect(x: visible.x, y: visible.y,
                                                          width: visible.maxX - startX, height: visible.height))
        let h = metrics(width: w, maxUnits: maxUnits, rows: rows).height
        let (x, y) = clampOrigin(x: startX, y: startTop - h, size: (w, h), visible: visible)
        return (x, y, w)
    }
}
