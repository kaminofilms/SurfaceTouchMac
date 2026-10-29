// SPDX-License-Identifier: GPL-2.0-or-later
// Host-side tests for IPTSKernelProcessor.hpp (built with ASan/UBSan).
// These test the algorithm on synthetic heatmaps; they are NOT a substitute
// for testing on a real Surface Pro 7 digitizer.

#include "../IPTSKernelProcessor.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

using namespace stm;

static int failures = 0;
static int checks = 0;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; \
    std::printf("FAIL %s:%d: %s -- ", __FILE__, __LINE__, #cond); std::printf(__VA_ARGS__); std::printf("\n"); } } while (0)

// Surface Pro 7 like geometry for tests (real dims come from the device).
static const u32 W = 64, H = 44;
static const u8 ZMIN = 0, ZMAX = 255;
static const u8 BG = 200;   // raw idle level (touch lowers the raw value)

struct Spot { double x, y, sigma, depth; };   // x,y in cells

static std::vector<u8> heatmap(const std::vector<Spot> &spots, unsigned noise_seed = 0, int noise = 0) {
    std::vector<double> drop(W * H, 0.0);
    for (auto &s : spots)
        for (u32 y = 0; y < H; y++)
            for (u32 x = 0; x < W; x++) {
                double dx = (x + 0.5) - s.x, dy = (y + 0.5) - s.y;
                drop[y * W + x] += s.depth * std::exp(-(dx * dx + dy * dy) / (2 * s.sigma * s.sigma));
            }
    std::mt19937 rng(noise_seed);
    std::uniform_int_distribution<int> nd(-noise, noise);
    std::vector<u8> out(W * H);
    for (u32 i = 0; i < W * H; i++) {
        int v = (int)std::lround(BG - drop[i]) + (noise ? nd(rng) : 0);
        if (noise && drop[i] < 1.0) v = BG + (nd(rng) == noise ? 1 : 0);   // mostly flat background
        out[i] = (u8)std::max(0, std::min(255, v));
    }
    return out;
}

static TouchFrame run(HeatmapProcessor &p, const std::vector<Spot> &spots, bool pen = false) {
    auto hm = heatmap(spots);
    TouchFrame f;
    bool ok = p.process(hm.data(), (u32)hm.size(), W, H, ZMIN, ZMAX, pen, f);
    CHECK(ok, "process() returned false");
    return f;
}

static int touching(const TouchFrame &f) {
    int n = 0;
    for (int i = 0; i < f.count; i++) n += f.fingers[i].touch;
    return n;
}

static const Finger *byId(const TouchFrame &f, int id) {
    for (int i = 0; i < f.count; i++) if (f.fingers[i].id == id) return &f.fingers[i];
    return nullptr;
}

static double cellToLogicalX(double cx) { return cx / W * kTouchMax; }
static double cellToLogicalY(double cy) { return cy / H * kTouchMax; }

// Finger: ~1 cm contact. Pitch ~4 mm/cell so sigma ~1.1 cells.
static Spot finger(double x, double y) { return {x, y, 1.1, 90}; }
static Spot palm(double x, double y)   { return {x, y, 4.5, 80}; }

static void test_empty() {
    HeatmapProcessor p;
    auto f = run(p, {});
    CHECK(f.count == 0, "count=%d", f.count);
}

static void test_single_finger_position() {
    HeatmapProcessor p;
    auto f = run(p, {finger(20.3, 15.7)});
    CHECK(f.count == 1 && touching(f) == 1, "count=%d", f.count);
    if (f.count == 1) {
        double ex = cellToLogicalX(20.3), ey = cellToLogicalY(15.7);
        // tolerance: 1.5 mm  (32767 / 259.8 mm ~ 126 units per mm)
        CHECK(std::fabs(f.fingers[0].x - ex) < 190, "x=%d expected %.0f", f.fingers[0].x, ex);
        CHECK(std::fabs(f.fingers[0].y - ey) < 285, "y=%d expected %.0f", f.fingers[0].y, ey);
        CHECK(f.fingers[0].id == 0, "id=%d", f.fingers[0].id);
    }
}

static void test_two_finger_tracking_and_pinch() {
    HeatmapProcessor p;
    // Start with two fingers, spread them apart over 10 frames (pinch-out).
    int idA = -1, idB = -1;
    double lastDist = 0;
    for (int i = 0; i <= 10; i++) {
        double off = 6 + i * 1.2;
        auto f = run(p, {finger(32 - off, 22), finger(32 + off, 22)});
        CHECK(touching(f) == 2, "frame %d touching=%d", i, touching(f));
        if (f.count != 2) continue;
        const Finger *L = f.fingers[0].x < f.fingers[1].x ? &f.fingers[0] : &f.fingers[1];
        const Finger *R = L == &f.fingers[0] ? &f.fingers[1] : &f.fingers[0];
        if (i == 0) { idA = L->id; idB = R->id; CHECK(idA != idB, "ids equal"); }
        else {
            CHECK(L->id == idA && R->id == idB, "ids changed at frame %d (%d,%d)", i, L->id, R->id);
            double d = R->x - L->x;
            CHECK(d > lastDist, "distance not increasing at frame %d", i);
        }
        lastDist = R->x - L->x;
    }
}

static void test_lift_reports_touch_up_once() {
    HeatmapProcessor p;
    run(p, {finger(10, 10), finger(40, 30)});
    auto f = run(p, {finger(10, 10)});   // second finger lifted
    CHECK(f.count == 2, "count=%d (expect 1 down + 1 up)", f.count);
    CHECK(touching(f) == 1, "touching=%d", touching(f));
    int ups = 0;
    for (int i = 0; i < f.count; i++) if (!f.fingers[i].touch) ups++;
    CHECK(ups == 1, "ups=%d", ups);
    auto g = run(p, {finger(10, 10)});
    CHECK(g.count == 1 && touching(g) == 1, "after lift count=%d", g.count);
    auto e = run(p, {});
    CHECK(e.count == 1 && touching(e) == 0, "final lift count=%d touching=%d", e.count, touching(e));
    auto z = run(p, {});
    CHECK(z.count == 0, "idle count=%d", z.count);
}

static void test_ten_fingers() {
    HeatmapProcessor p;
    std::vector<Spot> s;
    for (int i = 0; i < 10; i++) s.push_back(finger(5 + i * 5.8, i % 2 ? 12 : 30));
    auto f = run(p, s);
    CHECK(touching(f) == 10, "touching=%d", touching(f));
    bool seen[10] = {};
    for (int i = 0; i < f.count; i++) { CHECK(f.fingers[i].id < 10, "id"); seen[f.fingers[i].id] = true; }
    for (int i = 0; i < 10; i++) CHECK(seen[i], "id %d missing", i);
}

static void test_palm_rejection() {
    HeatmapProcessor p;
    auto f = run(p, {palm(15, 25)});
    CHECK(touching(f) == 0, "palm produced %d touches", touching(f));
    HeatmapProcessor p2;
    auto g = run(p2, {palm(15, 25), finger(19, 25), finger(55, 10)});
    // finger next to the palm dropped, far finger kept
    CHECK(touching(g) == 1, "touching=%d", touching(g));
    if (g.count >= 1) CHECK(g.fingers[0].x > cellToLogicalX(45), "kept wrong finger x=%d", g.fingers[0].x);

    ProcessorConfig c = defaultConfig();
    c.palm_rejection = false;
    HeatmapProcessor p3; p3.setConfig(c);
    auto h = run(p3, {palm(15, 25), finger(30, 25), finger(55, 10)});
    CHECK(touching(h) == 2, "palm rejection off: touching=%d", touching(h));
}

static void test_pen_suppresses_touch() {
    HeatmapProcessor p;
    run(p, {finger(30, 20)});
    auto f = run(p, {finger(30, 20)}, true);
    CHECK(touching(f) == 0, "touching while pen=%d", touching(f));
}

static void test_jitter_suppressed() {
    HeatmapProcessor p;
    auto a = run(p, {finger(30, 20)});
    auto b = run(p, {finger(30.1, 20.05)});   // ~0.4 mm move
    CHECK(a.count == 1 && b.count == 1, "counts");
    if (a.count == 1 && b.count == 1)
        CHECK(a.fingers[0].x == b.fingers[0].x && a.fingers[0].y == b.fingers[0].y, "jitter moved finger");
    auto c = run(p, {finger(36, 20)});         // ~24 mm move: must follow
    if (c.count >= 1) CHECK(c.fingers[0].x > a.fingers[0].x + 2000, "did not follow drag x=%d", c.fingers[0].x);
}

static void test_orientation() {
    ProcessorConfig c = defaultConfig();
    c.invert_x = true;
    HeatmapProcessor p; p.setConfig(c);
    auto f = run(p, {finger(10, 10)});
    if (f.count == 1) CHECK(f.fingers[0].x > kTouchMax / 2, "invert_x x=%d", f.fingers[0].x);
}

static void test_noise_no_ghosts() {
    HeatmapProcessor p;
    int ghosts = 0;
    for (unsigned seed = 1; seed <= 200; seed++) {
        auto hm = heatmap({}, seed, 3);
        TouchFrame f;
        p.process(hm.data(), (u32)hm.size(), W, H, ZMIN, ZMAX, false, f);
        ghosts += touching(f);
    }
    CHECK(ghosts == 0, "ghost touches from noise: %d", ghosts);
}

static void test_bad_input() {
    HeatmapProcessor p;
    TouchFrame f;
    std::vector<u8> small(10, 200);
    CHECK(!p.process(small.data(), 10, W, H, 0, 255, false, f), "short buffer accepted");
    CHECK(!p.process(small.data(), 10, 0, 0, 0, 255, false, f), "zero dims accepted");
    std::vector<u8> big(300 * 300, 200);
    CHECK(!p.process(big.data(), (u32)big.size(), 300, 300, 0, 255, false, f), "oversize accepted");
    CHECK(!p.process(small.data(), 10, 2, 2, 50, 40, false, f), "zmax<zmin accepted");
    CHECK(!p.process(nullptr, 0, 2, 2, 0, 255, false, f), "null accepted");
}

// ---------------------------------------------------------------- parser --

struct CollectSink : FrameParser::Sink {
    std::vector<TouchFrame> touches;
    std::vector<StylusFrame> styli;
    void onTouch(const TouchFrame &f) override { touches.push_back(f); }
    void onStylus(const StylusFrame &s) override { styli.push_back(s); }
};

static void put8(std::vector<u8> &b, u8 v) { b.push_back(v); }
static void put16(std::vector<u8> &b, u16 v) { b.push_back(v & 0xff); b.push_back(v >> 8); }
static void put32(std::vector<u8> &b, u32 v) { for (int i = 0; i < 4; i++) b.push_back((v >> (8 * i)) & 0xff); }

static std::vector<u8> report(u8 type, const std::vector<u8> &payload) {
    std::vector<u8> r; put8(r, type); put8(r, 0); put16(r, (u16)payload.size());
    r.insert(r.end(), payload.begin(), payload.end());
    return r;
}

static std::vector<u8> hidFrame(u8 type, const std::vector<u8> &payload) {
    std::vector<u8> f; put32(f, (u32)(payload.size() + 7)); put8(f, 0); put8(f, type); put8(f, 0);
    f.insert(f.end(), payload.begin(), payload.end());
    return f;
}

static std::vector<u8> dims(u8 w, u8 h) {
    std::vector<u8> d = {h, w, 0, (u8)(h - 1), 0, (u8)(w - 1), ZMIN, ZMAX};
    return report(FrameParser::REPORT_DIMENSIONS, d);
}

static void test_parser_reports_path() {
    HeatmapProcessor p; FrameParser parser(p); CollectSink sink;
    auto hm = heatmap({finger(20, 20), finger(40, 20)});
    std::vector<u8> reports = dims(W, H);
    auto hr = report(FrameParser::REPORT_HEATMAP, hm);
    reports.insert(reports.end(), hr.begin(), hr.end());
    // HID container: report id 0x0B + timestamp, then a HID frame of type HID
    // containing a REPORTS frame.
    auto inner = hidFrame(FrameParser::HID_FRAME_TYPE_REPORTS, reports);
    auto outer = hidFrame(FrameParser::HID_FRAME_TYPE_HID, inner);
    std::vector<u8> buf = {0x0B, 0, 0};
    buf.insert(buf.end(), outer.begin(), outer.end());
    CHECK(parser.parse(buf.data(), (u32)buf.size(), sink), "parse failed");
    CHECK(sink.touches.size() == 1, "touch frames=%zu", sink.touches.size());
    if (sink.touches.size() == 1) CHECK(touching(sink.touches[0]) == 2, "touching=%d", touching(sink.touches[0]));
}

static void test_parser_heatmap_frame_and_stylus() {
    HeatmapProcessor p; FrameParser parser(p); CollectSink sink;
    // dimensions first (reports frame), then a heatmap frame
    auto rep = hidFrame(FrameParser::HID_FRAME_TYPE_REPORTS, dims(W, H));
    auto hm = heatmap({finger(30, 22)});
    std::vector<u8> hh = {0, 0, 0, 0, 0}; put32(hh, (u32)hm.size()); hh.insert(hh.end(), hm.begin(), hm.end());
    auto hmf = hidFrame(FrameParser::HID_FRAME_TYPE_HEATMAP, hh);
    // stylus v2 report, pen in range + touching
    std::vector<u8> st = {1, 0, 0, 0}; put32(st, 0x1234);
    put16(st, 77); put16(st, 0x3); put16(st, 4800); put16(st, 3600); put16(st, 2048); put16(st, 0); put16(st, 0); put16(st, 0);
    auto stf = hidFrame(FrameParser::HID_FRAME_TYPE_REPORTS, report(FrameParser::REPORT_STYLUS_V2, st));

    std::vector<u8> body = rep; body.insert(body.end(), hmf.begin(), hmf.end()); body.insert(body.end(), stf.begin(), stf.end());
    auto outer = hidFrame(FrameParser::HID_FRAME_TYPE_HID, body);
    std::vector<u8> buf = {0x0B, 0, 0}; buf.insert(buf.end(), outer.begin(), outer.end());
    CHECK(parser.parse(buf.data(), (u32)buf.size(), sink), "parse failed");
    CHECK(sink.touches.size() == 1, "touch frames=%zu", sink.touches.size());
    CHECK(sink.styli.size() == 1, "stylus frames=%zu", sink.styli.size());
    if (!sink.styli.empty()) {
        auto &s = sink.styli[0];
        CHECK(s.in_range && s.touch && !s.button && s.x == 4800 && s.y == 3600 && s.pressure == 2048, "stylus fields");
    }
    CHECK(parser.penInRange(), "pen state");
}

static void test_parser_raw_path() {
    HeatmapProcessor p; FrameParser parser(p); CollectSink sink;
    auto hm = heatmap({finger(12, 30)});
    std::vector<u8> reports = dims(W, H);
    auto hr = report(FrameParser::REPORT_HEATMAP, hm);
    reports.insert(reports.end(), hr.begin(), hr.end());
    std::vector<u8> raw; put32(raw, 1); put32(raw, 1); put32(raw, 0);
    put16(raw, 0); put16(raw, FrameParser::RAW_FRAME_TYPE_HEATMAP); put32(raw, (u32)reports.size());
    for (int i = 0; i < 8; i++) put8(raw, 0);
    raw.insert(raw.end(), reports.begin(), reports.end());
    CHECK(parser.parseRawPayload(raw.data(), (u32)raw.size(), sink), "raw parse failed");
    CHECK(sink.touches.size() == 1 && touching(sink.touches[0]) == 1, "raw touch");
}

static void test_parser_fuzz() {
    // Random and truncated input must never crash or read out of bounds
    // (ASan/UBSan enforce this when built with `make test`).
    HeatmapProcessor p; FrameParser parser(p); CollectSink sink;
    std::mt19937 rng(42);
    std::uniform_int_distribution<int> byte(0, 255);
    for (int iter = 0; iter < 20000; iter++) {
        std::vector<u8> b(rng() % 600);
        for (auto &x : b) x = (u8)byte(rng);
        parser.parse(b.data(), (u32)b.size(), sink);
        parser.parseRawPayload(b.data(), (u32)b.size(), sink);
    }
    // truncations of a valid buffer
    auto hm = heatmap({finger(20, 20)});
    std::vector<u8> reports = dims(W, H);
    auto hr = report(FrameParser::REPORT_HEATMAP, hm);
    reports.insert(reports.end(), hr.begin(), hr.end());
    auto outer = hidFrame(FrameParser::HID_FRAME_TYPE_HID, hidFrame(FrameParser::HID_FRAME_TYPE_REPORTS, reports));
    std::vector<u8> buf = {0x0B, 0, 0}; buf.insert(buf.end(), outer.begin(), outer.end());
    for (size_t n = 0; n < buf.size(); n += 7) {
        std::vector<u8> t(buf.begin(), buf.begin() + n);
        parser.parse(t.data(), (u32)t.size(), sink);
    }
    CHECK(true, "fuzz survived");
}

int main() {
    test_empty();
    test_single_finger_position();
    test_two_finger_tracking_and_pinch();
    test_lift_reports_touch_up_once();
    test_ten_fingers();
    test_palm_rejection();
    test_pen_suppresses_touch();
    test_jitter_suppressed();
    test_orientation();
    test_noise_no_ghosts();
    test_bad_input();
    test_parser_reports_path();
    test_parser_heatmap_frame_and_stylus();
    test_parser_raw_path();
    test_parser_fuzz();
    std::printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
