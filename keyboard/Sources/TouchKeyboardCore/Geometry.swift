// SPDX-License-Identifier: MIT
// Keyboard sizing and placement (pure math, unit-tested).

public struct Rect: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public func intersects(_ o: Rect) -> Bool {
        x < o.maxX && o.x < maxX && y < o.maxY && o.y < maxY
    }
}

public struct KeyboardMetrics: Equatable, Sendable {
    public var unit: Double        // width of a 1.0 key, points
    public var keyHeight: Double
    public var padding: Double
    public var width: Double
    public var height: Double
}

public enum KeyboardGeometry {
    /// Minimum comfortable touch target (Apple HIG: 44 pt; we aim higher).
    public static let minKey = 48.0
    public static let maxKey = 96.0

    /// Sizes the keyboard to ~96% of the visible screen width, keeping keys
    /// touch-sized and the keyboard under ~45% of the screen height.
    public static func metrics(visibleWidth: Double, visibleHeight: Double,
                               maxUnits: Double, rows: Int) -> KeyboardMetrics {
        let padding = 8.0
        var unit = (visibleWidth * 0.96 - 2 * padding) / maxUnits
        unit = min(max(unit, minKey), maxKey)
        var keyHeight = min(unit * 0.85, 72)
        let maxHeight = visibleHeight * 0.45
        if Double(rows) * keyHeight + 2 * padding > maxHeight {
            keyHeight = max((maxHeight - 2 * padding) / Double(rows), 44)
        }
        let width = unit * maxUnits + 2 * padding
        let height = Double(rows) * keyHeight + 2 * padding
        return KeyboardMetrics(unit: unit, keyHeight: keyHeight, padding: padding,
                               width: width, height: height)
    }

    /// Bottom-centred placement in AppKit coordinates (origin bottom-left);
    /// moves to the top of the screen if it would cover the focused field.
    /// `field` must already be converted to AppKit coordinates.
    public static func placement(visible: Rect, size: (Double, Double), field: Rect?) -> (Double, Double) {
        let (w, h) = size
        let x = visible.x + (visible.width - w) / 2
        let bottom = Rect(x: x, y: visible.y + 8, width: w, height: h)
        if let f = field, bottom.intersects(f) {
            return (x, visible.maxY - h - 8)
        }
        return (bottom.x, bottom.y)
    }

    /// Accessibility frames use a top-left origin relative to the primary
    /// screen; AppKit uses bottom-left.
    public static func axToAppKit(_ r: Rect, primaryScreenHeight: Double) -> Rect {
        Rect(x: r.x, y: primaryScreenHeight - r.y - r.height, width: r.width, height: r.height)
    }
}
