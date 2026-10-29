// SPDX-License-Identifier: MIT
// One physical touch = exactly one key press.
//
// The BigSurface touchscreen driver turns a long press (about 1 s) into a
// right-click: the left button is released and a right button press follows.
// Without this filter a long press on a key would type it twice, and holding
// Backspace would stop repeating after one second.

public final class TouchSequencer {
    public enum Event: Equatable { case down, up }

    /// Gap that still counts as the same touch (left-up -> right-down handover).
    public let handoverWindow: Double
    private var isDown = false
    private var lastUpTime: Double = -1_000
    private var pendingRelease = false

    public init(handoverWindow: Double = 0.12) {
        self.handoverWindow = handoverWindow
    }

    /// Feed a button event at time `t` (seconds).
    /// Returns `.began` when a new touch starts (fire the key / start repeat),
    /// `.continued` for the driver's long-press handover, `.ended` when the
    /// touch is really over (stop repeat) and `.ignored` otherwise.
    public enum Result: Equatable { case began, continued, ended, ignored }

    public func handle(_ e: Event, at t: Double) -> Result {
        switch e {
        case .down:
            if isDown { return .ignored }
            isDown = true
            if pendingRelease && t - lastUpTime <= handoverWindow {
                pendingRelease = false
                return .continued
            }
            pendingRelease = false
            return .began
        case .up:
            if !isDown { return .ignored }
            isDown = false
            lastUpTime = t
            pendingRelease = true
            return .ignored     // decided by `flush` once the handover window passes
        }
    }

    /// Call after the handover window has passed since the last `.up`.
    public func flush(at t: Double) -> Result {
        if pendingRelease && !isDown && t - lastUpTime > handoverWindow {
            pendingRelease = false
            return .ended
        }
        return .ignored
    }
}

/// Hold-to-repeat timing (macOS-like defaults).
public struct RepeatPolicy: Sendable {
    public var initialDelay: Double = 0.45
    public var interval: Double = 0.07
    public init() {}

    /// Number of repeats that should have fired `held` seconds after press.
    public func repeats(after held: Double) -> Int {
        guard held >= initialDelay else { return 0 }
        return 1 + Int((held - initialDelay) / interval)
    }
}
