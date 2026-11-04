// SPDX-License-Identifier: GPL-2.0-or-later
// Host tests for TouchGesture.hpp (iPad-style single-finger touch).
#include "../TouchGesture.hpp"

#include <cstdio>
#include <string>
#include <vector>

using namespace stm;
using A = GestureAction;

static int failures = 0, checks = 0;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; \
    std::printf("FAIL %s:%d: %s -- ", __FILE__, __LINE__, #cond); std::printf(__VA_ARGS__); std::printf("\n"); } } while (0)

static const unsigned long long MS = 1000000ULL;
// 1 mm in logical units
static int mmx(double mm) { return (int)(mm * 65535 / 259.8); }
static int mmy(double mm) { return (int)(mm * 65535 / 173.2); }

struct Rec {
    TouchGesture g;
    std::vector<GestureEvent> ev;
    void at(unsigned long long ms, bool t, int x, int y) {
        GestureEvent out[TouchGesture::kMaxOut];
        unsigned n = g.update(ms * MS, t, x, y, out);
        for (unsigned i = 0; i < n; i++) ev.push_back(out[i]);
    }
    std::vector<A> actions() const { std::vector<A> a; for (auto &e : ev) a.push_back(e.action); return a; }
    int count(A a) const { int c = 0; for (auto &e : ev) c += e.action == a; return c; }
};

static void test_tap_clicks_once() {
    Rec r;
    r.at(0, true, 30000, 20000);
    r.at(16, true, 30010, 20005);   // tiny jitter
    r.at(80, false, 30010, 20005);
    CHECK((r.actions() == std::vector<A>{A::Move, A::LeftDown, A::LeftUp}), "actions wrong (%zu)", r.ev.size());
    CHECK(r.count(A::Scroll) == 0 && r.count(A::ScrollBegin) == 0, "tap scrolled");
    CHECK(r.ev[1].x == 30000 && r.ev[1].y == 20000, "click not at touch-down point");
    CHECK(r.g.state() == TouchGesture::State::Idle, "not idle");
}

static void test_very_quick_tap_still_clicks() {
    // the bug being fixed: a tap shorter than one report used to be lost
    Rec r;
    r.at(0, true, 1000, 60000);     // e.g. a Dock icon
    r.at(5, false, 1000, 60000);
    CHECK(r.count(A::LeftDown) == 1 && r.count(A::LeftUp) == 1, "quick tap lost");
}

static void test_no_hover_or_press_while_sliding() {
    // sliding along the Dock must scroll, never press or drag icons
    Rec r;
    int y = 60000;
    r.at(0, true, 10000, y);
    for (int i = 1; i <= 20; i++) r.at(i * 16, true, 10000 + i * mmx(2), y);
    r.at(400, false, 10000 + 20 * mmx(2), y);
    CHECK(r.count(A::LeftDown) == 0 && r.count(A::RightDown) == 0, "slide pressed a button");
    CHECK(r.count(A::ScrollBegin) == 1 && r.count(A::ScrollEnd) == 1, "scroll phases wrong");
    int total = 0; for (auto &e : r.ev) if (e.action == A::Scroll || e.action == A::ScrollBegin) total += e.dx;
    // 40 mm at ~5.26 pt/mm = ~210 points, content follows the finger (positive)
    CHECK(total > 190 && total < 230, "scroll distance %d", total);
}

static void test_scroll_vertical_follows_finger() {
    Rec r;
    r.at(0, true, 30000, 30000);
    for (int i = 1; i <= 10; i++) r.at(i * 16, true, 30000, 30000 - i * mmy(3));
    r.at(200, false, 30000, 30000 - 10 * mmy(3));
    int dy = 0; for (auto &e : r.ev) dy += e.dy;
    CHECK(dy < -140 && dy > -175, "vertical scroll %d (finger moved up 30 mm)", dy);
}

static void test_hold_then_move_drags() {
    Rec r;
    r.at(0, true, 20000, 20000);
    r.at(200, true, 20005, 20000);
    r.at(400, true, 20005, 20000);             // held still > 350 ms
    r.at(420, true, 20000 + mmx(10), 20000);   // now move
    r.at(440, true, 20000 + mmx(20), 20000);
    r.at(460, false, 20000 + mmx(20), 20000);
    CHECK(r.count(A::LeftDown) == 1 && r.count(A::LeftUp) == 1, "drag press/release");
    CHECK(r.count(A::DragMove) >= 2, "no drag moves");
    CHECK(r.count(A::Scroll) == 0, "drag scrolled");
    // press happens where the finger first touched
    for (auto &e : r.ev) if (e.action == A::LeftDown) CHECK(e.x == 20000, "drag started elsewhere");
}

static void test_long_hold_right_clicks() {
    Rec r;
    r.at(0, true, 20000, 20000);
    for (int t = 100; t <= 1000; t += 100) r.at(t, true, 20003, 20002);
    r.at(1100, false, 20003, 20002);
    CHECK((r.actions() == std::vector<A>{A::Move, A::RightDown, A::RightUp}), "right click sequence (%zu events)", r.ev.size());
    CHECK(r.count(A::LeftDown) == 0, "long press also left-clicked");
}

static void test_hold_between_350_and_650_is_click() {
    Rec r;
    r.at(0, true, 20000, 20000);
    r.at(300, true, 20000, 20000);
    r.at(600, true, 20000, 20000);
    r.at(650, false, 20000, 20000);
    CHECK(r.count(A::LeftDown) == 1 && r.count(A::LeftUp) == 1 && r.count(A::RightDown) == 0, "slow tap");
}

static void test_double_tap_snaps_to_first() {
    Rec r;
    r.at(0, true, 30000, 30000);   r.at(60, false, 30000, 30000);
    r.at(200, true, 30000 + mmx(3), 30000 + mmy(2));   // 2nd tap 3.6 mm away
    r.at(260, false, 30000 + mmx(3), 30000 + mmy(2));
    int downs = 0;
    for (auto &e : r.ev) if (e.action == A::LeftDown) { downs++; CHECK(e.x == 30000 && e.y == 30000, "2nd tap not snapped"); }
    CHECK(downs == 2, "downs=%d", downs);
}

static void test_far_or_late_second_tap_not_snapped() {
    Rec r;
    r.at(0, true, 30000, 30000);   r.at(60, false, 30000, 30000);
    r.at(900, true, 30000 + mmx(3), 30000);  r.at(950, false, 30000 + mmx(3), 30000);   // too late
    r.at(1100, true, 30000 + mmx(20), 30000); r.at(1150, false, 30000 + mmx(20), 30000); // too far
    int snapped = 0; for (auto &e : r.ev) if (e.action == A::LeftDown && e.x == 30000) snapped++;
    CHECK(snapped == 1, "unexpected snapping (%d)", snapped);
}

static void test_cancel_releases_without_click() {
    Rec r;
    r.at(0, true, 20000, 20000);
    r.at(400, true, 20000, 20000);
    r.at(420, true, 20000 + mmx(10), 20000);   // dragging
    GestureEvent out[TouchGesture::kMaxOut];
    unsigned n = r.g.cancel(out);
    CHECK(n == 1 && out[0].action == A::LeftUp, "cancel while dragging");
    TouchGesture idle;
    CHECK(idle.cancel(out) == 0, "cancel idle emitted");
    // cancel during a pending touch emits nothing (no accidental click)
    TouchGesture p; GestureEvent o2[4];
    p.update(0, true, 1, 1, o2);
    CHECK(p.cancel(o2) == 0, "cancel pending clicked");
}

static void test_scroll_sign_and_clamp() {
    GestureConfig c; c.scroll_sign = -1;
    Rec r; r.g.setConfig(c);
    r.at(0, true, 30000, 30000);
    for (int i = 1; i <= 5; i++) r.at(i * 16, true, 30000 + i * mmx(4), 30000);
    int dx = 0; for (auto &e : r.ev) dx += e.dx;
    CHECK(dx < 0, "inverted scroll not negative (%d)", dx);
    Rec q; q.at(0, true, -500, 70000); q.at(10, false, -500, 70000);
    CHECK(q.ev[0].x == 0 && q.ev[0].y == 65535, "coordinates not clamped");
}

static void test_random_sequences_never_leave_button_down() {
    unsigned seed = 7;
    auto rnd = [&]() { seed = seed * 1103515245 + 12345; return (seed >> 8) & 0xffff; };
    for (int run = 0; run < 2000; run++) {
        Rec r;
        unsigned long long t = 0;
        bool touching = false;
        for (int i = 0; i < 60; i++) {
            t += 5 + rnd() % 120;
            if (rnd() % 7 == 0) touching = !touching;
            r.at(t, touching, (int)(rnd() % 70000) - 2000, (int)(rnd() % 70000) - 2000);
        }
        r.at(t + 10, false, 100, 100);
        int ld = r.count(A::LeftDown) - r.count(A::LeftUp);
        int rd = r.count(A::RightDown) - r.count(A::RightUp);
        int sc = r.count(A::ScrollBegin) - r.count(A::ScrollEnd);
        if (ld || rd || sc) { CHECK(false, "run %d unbalanced L%d R%d S%d", run, ld, rd, sc); break; }
    }
    CHECK(true, "fuzz");
}

static const int DOCK_Y = 64000;   // inside the bottom 7% band

static void test_dock_slide_hovers_and_magnifies() {
    Rec r;
    r.at(0, true, 20000, DOCK_Y);
    for (int i = 1; i <= 20; i++) r.at(i * 16, true, 20000 + i * mmx(3), DOCK_Y);
    r.at(400, false, 20000 + 20 * mmx(3), DOCK_Y);
    CHECK(r.count(A::LeftDown) == 0 && r.count(A::RightDown) == 0, "dock slide clicked");
    CHECK(r.count(A::ScrollBegin) == 0, "dock slide scrolled");
    CHECK(r.count(A::Move) >= 15, "pointer did not follow finger (%d moves)", r.count(A::Move));
}

static void test_dock_single_tap_does_not_open() {
    Rec r;
    r.at(0, true, 30000, DOCK_Y);
    r.at(60, false, 30000, DOCK_Y);
    CHECK(r.count(A::LeftDown) == 0, "single dock tap opened the app");
    CHECK(r.count(A::Move) == 1, "no magnify move");
}

static void test_dock_double_tap_opens_once() {
    Rec r;
    r.at(0, true, 30000, DOCK_Y);   r.at(60, false, 30000, DOCK_Y);
    r.at(250, true, 30000 + mmx(2), DOCK_Y); r.at(310, false, 30000 + mmx(2), DOCK_Y);
    CHECK(r.count(A::LeftDown) == 1 && r.count(A::LeftUp) == 1, "double tap clicks=%d", r.count(A::LeftDown));
    // a third tap right after starts a new pair (does not open again)
    r.at(450, true, 30000, DOCK_Y); r.at(500, false, 30000, DOCK_Y);
    CHECK(r.count(A::LeftDown) == 1, "third tap opened again");
}

static void test_dock_taps_on_different_icons_dont_open() {
    Rec r;
    r.at(0, true, 20000, DOCK_Y);   r.at(60, false, 20000, DOCK_Y);
    r.at(250, true, 20000 + mmx(40), DOCK_Y); r.at(310, false, 20000 + mmx(40), DOCK_Y);
    CHECK(r.count(A::LeftDown) == 0, "taps on two icons opened one");
}

static void test_dock_slide_then_tap_needs_double() {
    Rec r;
    r.at(0, true, 20000, DOCK_Y);
    for (int i = 1; i <= 5; i++) r.at(i * 16, true, 20000 + i * mmx(3), DOCK_Y);
    r.at(100, false, 20000 + 5 * mmx(3), DOCK_Y);
    r.at(200, true, 20000 + 5 * mmx(3), DOCK_Y); r.at(260, false, 20000 + 5 * mmx(3), DOCK_Y);
    CHECK(r.count(A::LeftDown) == 0, "slide + one tap opened");
    r.at(400, true, 20000 + 5 * mmx(3), DOCK_Y); r.at(460, false, 20000 + 5 * mmx(3), DOCK_Y);
    CHECK(r.count(A::LeftDown) == 1, "double tap after slide did not open");
}

static void test_dock_swipe_up_is_edge_swipe() {
    Rec r;
    r.at(0, true, 30000, 65000);
    for (int i = 1; i <= 8; i++) r.at(i * 16, true, 30000, 65000 - i * mmy(4));
    r.at(200, false, 30000, 65000 - 8 * mmy(4));
    CHECK(r.count(A::ScrollBegin) == 1 && r.count(A::ScrollEnd) == 1, "no edge swipe");
    CHECK(r.count(A::LeftDown) == 0, "edge swipe clicked");
}

static void test_dock_long_press_menu() {
    Rec r;
    r.at(0, true, 30000, DOCK_Y);
    for (int t = 100; t <= 800; t += 100) r.at(t, true, 30002, DOCK_Y);
    r.at(900, false, 30002, DOCK_Y);
    CHECK(r.count(A::RightDown) == 1 && r.count(A::RightUp) == 1 && r.count(A::LeftDown) == 0, "dock menu");
}

static void test_dock_off_means_normal_tap() {
    GestureConfig c; c.dock_edge = 3;
    Rec r; r.g.setConfig(c);
    r.at(0, true, 30000, DOCK_Y); r.at(60, false, 30000, DOCK_Y);
    CHECK(r.count(A::LeftDown) == 1, "dock off: tap should click");
}

int main() {
    test_dock_slide_hovers_and_magnifies();
    test_dock_single_tap_does_not_open();
    test_dock_double_tap_opens_once();
    test_dock_taps_on_different_icons_dont_open();
    test_dock_slide_then_tap_needs_double();
    test_dock_swipe_up_is_edge_swipe();
    test_dock_long_press_menu();
    test_dock_off_means_normal_tap();
    test_tap_clicks_once();
    test_very_quick_tap_still_clicks();
    test_no_hover_or_press_while_sliding();
    test_scroll_vertical_follows_finger();
    test_hold_then_move_drags();
    test_long_hold_right_clicks();
    test_hold_between_350_and_650_is_click();
    test_double_tap_snaps_to_first();
    test_far_or_late_second_tap_not_snapped();
    test_cancel_releases_without_click();
    test_scroll_sign_and_clamp();
    test_random_sequences_never_leave_button_down();
    std::printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
