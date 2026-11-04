// SPDX-License-Identifier: GPL-2.0-or-later
//
// TouchGesture.hpp - iPad-style single-finger touch for macOS (SurfaceTouchMac)
//
// Replaces BigSurface's "hover first, then press" single-finger handling,
// which made a finger behave like a mouse: sliding over the Dock magnified it
// and quick taps were often lost.
//
//   tap                      -> left click at the finger (immediately on lift)
//   slide                    -> scroll the content under the finger
//   touch, hold still, move  -> press and drag (move windows, select text)
//   hold still longer        -> right click (context menu)
//   two taps                 -> double click (2nd tap snapped onto the 1st)
//
// Integer-only, no allocation, no libc: used inside the kext and compiled on a
// host for unit tests. Coordinates are 0..65535 across the screen.
//

#ifndef STM_TOUCH_GESTURE_HPP
#define STM_TOUCH_GESTURE_HPP

namespace stm {

typedef unsigned char      g_u8;
typedef unsigned int       g_u32;
typedef int                g_i32;
typedef long long          g_i64;
typedef unsigned long long g_u64;

struct GestureConfig {
    // physical screen size (Surface Pro 7: 259.8 x 173.2 mm)
    g_i32 width_um  = 259800;
    g_i32 height_um = 173200;
    g_i32 slop_um          = 3000;      // movement that turns a touch into a slide
    g_u64 hold_ns          = 350000000; // still this long -> press (drag mode)
    g_u64 right_ns         = 900000000; // still this long -> right click
    g_u64 double_tap_ns    = 450000000; // 2nd tap within this time...
    g_i32 double_tap_um    = 7000;      // ...and this distance is snapped onto the 1st
    g_i32 scroll_um_per_pt = 190;       // ~5.3 points per mm on the Surface Pro 7 at 200%
    g_i32 scroll_sign      = 1;         // -1 inverts (boot-arg stmscrollinv=1)
};

enum class GestureAction : g_u8 {
    None,
    Move,         // pointer to (x,y), no button
    LeftDown,
    LeftUp,
    RightDown,
    RightUp,
    DragMove,     // pointer to (x,y) with left button held
    ScrollBegin,  // dx/dy in points (content follows the finger)
    Scroll,
    ScrollEnd,
};

struct GestureEvent {
    GestureAction action = GestureAction::None;
    g_i32 x = 0, y = 0;      // 0..65535
    g_i32 dx = 0, dy = 0;    // scroll, points
};

class TouchGesture {
public:
    static const g_u32 kMaxOut = 4;

    enum class State : g_u8 { Idle, Pending, Scrolling, Dragging, RightHeld };

    explicit TouchGesture(const GestureConfig &c = GestureConfig()) : cfg(c) {}

    void setConfig(const GestureConfig &c) { cfg = c; }
    State state() const { return st; }

    // Feed one sample. `touching` false = finger lifted.
    // Returns number of events written to `out` (<= kMaxOut).
    g_u32 update(g_u64 t_ns, bool touching, g_i32 x, g_i32 y, GestureEvent *out) {
        n = 0; o = out;
        x = clamp(x); y = clamp(y);
        switch (st) {
        case State::Idle:
            if (!touching) break;
            st = State::Pending;
            t0 = t_ns; sx = x; sy = y; lx = x; ly = y;
            // snap a second tap onto the first one so macOS sees a double click
            if (t_ns - last_tap_t <= cfg.double_tap_ns && dist_um(x, y, tapx, tapy) <= cfg.double_tap_um) {
                sx = tapx; sy = tapy;
            }
            emit(GestureAction::Move, sx, sy);
            break;

        case State::Pending:
            if (!touching) {                     // quick tap
                emit(GestureAction::LeftDown, sx, sy);
                emit(GestureAction::LeftUp, sx, sy);
                last_tap_t = t_ns; tapx = sx; tapy = sy;
                st = State::Idle;
                break;
            }
            if (dist_um(x, y, sx, sy) > cfg.slop_um) {
                if (t_ns - t0 >= cfg.hold_ns) {  // held still first: drag
                    emit(GestureAction::LeftDown, sx, sy);
                    emit(GestureAction::DragMove, x, y);
                    st = State::Dragging;
                } else {                         // moved right away: scroll
                    st = State::Scrolling;
                    rem_x = rem_y = 0;
                    scroll(GestureAction::ScrollBegin, x, y);
                }
                lx = x; ly = y;
                break;
            }
            if (t_ns - t0 >= cfg.right_ns) {     // long still press: right click
                emit(GestureAction::RightDown, sx, sy);
                st = State::RightHeld;
            }
            break;

        case State::Scrolling:
            if (!touching) {
                emit(GestureAction::ScrollEnd, lx, ly);
                st = State::Idle;
                last_tap_t = 0;
                break;
            }
            scroll(GestureAction::Scroll, x, y);
            break;

        case State::Dragging:
            if (!touching) {
                emit(GestureAction::LeftUp, lx, ly);
                st = State::Idle;
                last_tap_t = 0;
                break;
            }
            if (x != lx || y != ly) { emit(GestureAction::DragMove, x, y); lx = x; ly = y; }
            break;

        case State::RightHeld:
            if (!touching) {
                emit(GestureAction::RightUp, sx, sy);
                st = State::Idle;
                last_tap_t = 0;
            }
            break;
        }
        return n;
    }

    // Call when the touch is taken over by something else (pen, 2+ fingers):
    // releases whatever is held without clicking.
    g_u32 cancel(GestureEvent *out) {
        n = 0; o = out;
        switch (st) {
        case State::Scrolling: emit(GestureAction::ScrollEnd, lx, ly); break;
        case State::Dragging:  emit(GestureAction::LeftUp, lx, ly); break;
        case State::RightHeld: emit(GestureAction::RightUp, sx, sy); break;
        default: break;
        }
        st = State::Idle;
        last_tap_t = 0;
        return n;
    }

private:
    GestureConfig cfg;
    State st = State::Idle;
    g_u64 t0 = 0, last_tap_t = 0;
    g_i32 sx = 0, sy = 0, lx = 0, ly = 0, tapx = 0, tapy = 0;
    g_i64 rem_x = 0, rem_y = 0;   // sub-point remainder, in um
    g_u32 n = 0;
    GestureEvent *o = nullptr;

    static g_i32 clamp(g_i32 v) { return v < 0 ? 0 : (v > 65535 ? 65535 : v); }

    g_i64 um_x(g_i32 d) const { return (g_i64)d * cfg.width_um / 65535; }
    g_i64 um_y(g_i32 d) const { return (g_i64)d * cfg.height_um / 65535; }

    g_i64 dist_um(g_i32 x1, g_i32 y1, g_i32 x2, g_i32 y2) const {
        g_i64 dx = um_x(x1 - x2), dy = um_y(y1 - y2);
        // integer sqrt
        g_u64 v = (g_u64)(dx * dx + dy * dy), r = 0, bit = 1ULL << 62;
        while (bit > v) bit >>= 2;
        while (bit) {
            if (v >= r + bit) { v -= r + bit; r = (r >> 1) + bit; } else r >>= 1;
            bit >>= 2;
        }
        return (g_i64)r;
    }

    void emit(GestureAction a, g_i32 x, g_i32 y, g_i32 dx = 0, g_i32 dy = 0) {
        if (n >= kMaxOut) return;
        o[n].action = a; o[n].x = x; o[n].y = y; o[n].dx = dx; o[n].dy = dy;
        n++;
    }

    void scroll(GestureAction a, g_i32 x, g_i32 y) {
        rem_x += um_x(x - lx);
        rem_y += um_y(y - ly);
        g_i32 px = (g_i32)(rem_x / cfg.scroll_um_per_pt);
        g_i32 py = (g_i32)(rem_y / cfg.scroll_um_per_pt);
        rem_x -= (g_i64)px * cfg.scroll_um_per_pt;
        rem_y -= (g_i64)py * cfg.scroll_um_per_pt;
        lx = x; ly = y;
        if (a == GestureAction::ScrollBegin || px != 0 || py != 0)
            emit(a, x, y, px * cfg.scroll_sign, py * cfg.scroll_sign);
    }
};

} // namespace stm

#endif // STM_TOUCH_GESTURE_HPP
