// SPDX-License-Identifier: GPL-2.0-or-later
//
// IPTSKernelProcessor.hpp - in-kernel IPTS heatmap -> multitouch processor
//
// Part of SurfaceTouchMac. Algorithms are an integer-only reimplementation of
// the "basic" contact detector and finger tracker from linux-surface/iptsd as
// ported to macOS by Xiashangning/IPTSDaemon (both GPL-2.0-or-later).
//
// Why this exists: with stock BigSurface, multitouch only works once the
// user-space IPTSDaemon is running, so the macOS installer, Setup Assistant
// and Recovery only get single-touch. Doing the heatmap processing inside the
// kext gives multitouch everywhere the kext loads.
//
// Constraints honoured here:
//   * header-only, no STL, no exceptions, no heap allocation, no floats
//     (kext code must not rely on the FPU state being saved)
//   * every read from the device buffer is bounds-checked
//   * compiles both in the kernel and on a host for unit tests
//

#ifndef STM_IPTS_KERNEL_PROCESSOR_HPP
#define STM_IPTS_KERNEL_PROCESSOR_HPP

namespace stm {

typedef unsigned char      u8;
typedef unsigned short     u16;
typedef unsigned int       u32;
typedef unsigned long long u64;
typedef signed char        i8;
typedef short              i16;
typedef int                i32;
typedef long long          i64;

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------
static const u32 kMaxHeatmapW   = 128;
static const u32 kMaxHeatmapH   = 96;
static const u32 kMaxCells      = kMaxHeatmapW * kMaxHeatmapH;
static const u32 kMaxBlobs      = 32;      // candidate blobs per frame
static const u32 kMaxFingers    = 10;      // matches IPTS_TOUCH_SCREEN_FINGER_CNT
static const u32 kTouchMax      = 32767;   // HID logical max for finger x/y
static const u32 kStylusMaxX    = 9600;
static const u32 kStylusMaxY    = 7200;

// ---------------------------------------------------------------------------
// Output types (layout independent of the kext's HID report structs; the kext
// glue copies them into IPTSHIDReport)
// ---------------------------------------------------------------------------
struct Finger {
    bool touch;      // tip switch
    u8   id;         // stable contact id 0..9
    u16  x;          // 0..kTouchMax
    u16  y;          // 0..kTouchMax
};

struct TouchFrame {
    Finger fingers[kMaxFingers];
    u8     count;
};

struct StylusFrame {
    bool in_range;
    bool touch;
    bool button;
    bool rubber;
    u16  x;          // 0..9600
    u16  y;          // 0..7200
    u16  pressure;   // 0..4096
    u16  timestamp;
};

struct ProcessorConfig {
    // thresholds in 0..255 heatmap units above the neutral (background) level
    i32  activation;        // iptsd default 12
    i32  deactivation;      // iptsd default 8
    // physical screen size in micrometres (Surface Pro 7: 259.8 x 173.2 mm)
    i32  width_um;
    i32  height_um;
    // contact shape limits (iptsd: size 0.2..2 cm, aspect 1..2.5)
    i32  size_min_um;
    i32  size_max_um;
    i32  aspect_max_x100;
    // fingers whose edge is within this distance of a palm are dropped
    i32  palm_dist_um;
    bool palm_rejection;
    // movement smoothing (iptsd position_thresh_min = 0.2 cm)
    i32  jitter_um;
    // ignore finger touches while the pen is in range
    bool reject_touch_while_pen;
    // orientation
    bool invert_x;
    bool invert_y;
    bool swap_xy;
};

static inline ProcessorConfig defaultConfig() {
    ProcessorConfig c;
    c.activation = 12;
    c.deactivation = 8;
    c.width_um = 259800;
    c.height_um = 173200;
    c.size_min_um = 2000;
    c.size_max_um = 20000;
    c.aspect_max_x100 = 250;
    c.palm_dist_um = 10000;
    c.palm_rejection = true;
    c.jitter_um = 2000;
    c.reject_touch_while_pen = true;
    c.invert_x = false;
    c.invert_y = false;
    c.swap_xy = false;
    return c;
}

// ---------------------------------------------------------------------------
// Small integer helpers
// ---------------------------------------------------------------------------
static inline u64 isqrt64(u64 v) {
    if (v == 0) return 0;
    u64 r = 0;
    u64 bit = 1ULL << 62;
    while (bit > v) bit >>= 2;
    while (bit) {
        if (v >= r + bit) {
            v -= r + bit;
            r = (r >> 1) + bit;
        } else {
            r >>= 1;
        }
        bit >>= 2;
    }
    return r;
}

static inline i64 iabs64(i64 v) { return v < 0 ? -v : v; }
static inline i32 clampi(i32 v, i32 lo, i32 hi) { return v < lo ? lo : (v > hi ? hi : v); }

// Bounds-checked little-endian reader over a device buffer.
class Reader {
public:
    Reader(const u8 *data, u32 size) : p(data), n(size), off(0), ok(true) {}

    bool good() const { return ok; }
    u32  remaining() const { return ok ? n - off : 0; }

    bool skip(u32 len) {
        if (!ok || len > n - off) { ok = false; return false; }
        off += len;
        return true;
    }
    u8 u8v() {
        if (!ok || n - off < 1) { ok = false; return 0; }
        return p[off++];
    }
    u16 u16v() {
        if (!ok || n - off < 2) { ok = false; return 0; }
        u16 v = (u16)(p[off] | (p[off + 1] << 8));
        off += 2;
        return v;
    }
    u32 u32v() {
        if (!ok || n - off < 4) { ok = false; return 0; }
        u32 v = (u32)p[off] | ((u32)p[off + 1] << 8) | ((u32)p[off + 2] << 16) | ((u32)p[off + 3] << 24);
        off += 4;
        return v;
    }
    // Returns a sub-reader over the next len bytes and advances past them.
    Reader sub(u32 len) {
        if (!ok || len > n - off) { ok = false; return Reader(nullptr, 0, false); }
        Reader r(p + off, len);
        off += len;
        return r;
    }
    const u8 *cur() const { return p + off; }

private:
    Reader(const u8 *data, u32 size, bool good) : p(data), n(size), off(0), ok(good) {}
    const u8 *p;
    u32 n;
    u32 off;
    bool ok;
};

// ---------------------------------------------------------------------------
// Heatmap -> contacts
// ---------------------------------------------------------------------------
class HeatmapProcessor {
public:
    struct Blob {
        // position in 1/256 cell units (centre of cell = +128)
        i32 x_fp, y_fp;
        // ellipse radii (sqrt eigenvalues) in 1/256 cell units
        i32 r_major_fp, r_minor_fp;
        bool valid;    // finger-shaped (not palm)
    };

    struct Contact {
        bool active;
        u8   id;
        i32  x_um, y_um;    // physical position
        i32  major_um;
    };

    HeatmapProcessor() { setConfig(defaultConfig()); reset(); }

    void setConfig(const ProcessorConfig &c) { cfg = c; }
    const ProcessorConfig &config() const { return cfg; }

    void reset() {
        prev_count = 0;
        for (u32 i = 0; i < kMaxFingers; i++) prev[i].active = false;
        stamp = 0;
        for (u32 i = 0; i < kMaxCells; i++) visited[i] = 0;
    }

    // Process one heatmap. data is width*height bytes, row-major
    // (data[y * width + x]); touches lower the raw value.
    // Returns false (and leaves out untouched) for malformed input.
    bool process(const u8 *data, u32 len, u32 width, u32 height, u8 z_min, u8 z_max,
                 bool pen_in_range, TouchFrame &out) {
        if (!data || width == 0 || height == 0 || width > kMaxHeatmapW || height > kMaxHeatmapH)
            return false;
        if (len < width * height)
            return false;
        if (z_max == 0) z_max = 255;               // iptsd: newer devices report 0
        if (z_max <= z_min) return false;

        w = width; h = height;
        normalize(data, z_min, z_max);
        const i32 neutral = neutralMode();
        const i32 athresh = neutral + cfg.activation;
        const i32 dthresh = neutral + cfg.deactivation;

        u32 nblobs = findBlobs(athresh, dthresh);
        Contact cur[kMaxFingers];
        u32 ncur = blobsToContacts(nblobs, cur);

        if (pen_in_range && cfg.reject_touch_while_pen)
            ncur = 0;

        track(cur, ncur);
        emit(cur, ncur, out);
        return true;
    }

    // Exposed for tests
    u32 lastBlobCount() const { return last_blob_count; }
    const Blob &blob(u32 i) const { return blobs[i]; }

private:
    ProcessorConfig cfg;
    u32 w = 0, h = 0;
    u8  img[kMaxCells];          // inverted + normalised heatmap, touch = high
    u16 visited[kMaxCells];      // per-cluster visit stamp
    u16 stamp = 0;
    Blob blobs[kMaxBlobs];
    u32 last_blob_count = 0;

    Contact prev[kMaxFingers];
    u32 prev_count = 0;

    struct StackItem { i16 x, y; };
    StackItem stack[kMaxCells];

    void normalize(const u8 *data, u8 z_min, u8 z_max) {
        const i32 range = (i32)z_max - (i32)z_min;
        const u32 n = w * h;
        for (u32 i = 0; i < n; i++) {
            i32 v = clampi((i32)data[i], z_min, z_max);
            // iptsd: val = 1 - (v - zmin) / (zmax - zmin)
            img[i] = (u8)(((i32)z_max - v) * 255 / range);
        }
    }

    // iptsd neutral_mode(): most common value + 1
    i32 neutralMode() const {
        u32 hist[256];
        for (u32 i = 0; i < 256; i++) hist[i] = 0;
        const u32 n = w * h;
        for (u32 i = 0; i < n; i++) hist[img[i]]++;
        u32 best = 0;
        for (u32 i = 1; i < 256; i++)
            if (hist[i] > hist[best]) best = i;
        return (i32)best + 1;
    }

    inline i32 at(i32 x, i32 y) const { return img[(u32)y * w + (u32)x]; }

    bool isLocalMax(i32 x, i32 y, i32 thresh) const {
        const i32 v = at(x, y);
        if (v <= thresh) return false;
        const bool up = y > 0, down = y < (i32)h - 1, left = x > 0, right = x < (i32)w - 1;
        // Same asymmetric kernel as iptsd so plateaus yield exactly one maximum:
        //   [< ] [< ] [< ]
        //   [< ] [  ] [<=]
        //   [<=] [<=] [<=]
        if (left  && !(at(x - 1, y) <  v)) return false;
        if (right && !(at(x + 1, y) <= v)) return false;
        if (up) {
            if (!(at(x, y - 1) < v)) return false;
            if (left  && !(at(x - 1, y - 1) < v)) return false;
            if (right && !(at(x + 1, y - 1) < v)) return false;
        }
        if (down) {
            if (!(at(x, y + 1) <= v)) return false;
            if (left  && !(at(x - 1, y + 1) <= v)) return false;
            if (right && !(at(x + 1, y + 1) <= v)) return false;
        }
        return true;
    }

    u16 nextStamp() {
        stamp++;
        if (stamp == 0) {   // wrapped: clear
            for (u32 i = 0; i < kMaxCells; i++) visited[i] = 0;
            stamp = 1;
        }
        return stamp;
    }

    // Iterative version of iptsd span_cluster(): grow while value > dthresh;
    // once below the activation threshold the value may not increase again.
    // Cells are marked when pushed, so each cell enters the stack at most once
    // and the fixed-size stack (kMaxCells entries) can never overflow.
    bool canEnter(i32 x, i32 y, i32 from, i32 athresh, i32 dthresh, u16 s) const {
        if (x < 0 || y < 0 || x >= (i32)w || y >= (i32)h) return false;
        const u32 idx = (u32)y * w + (u32)x;
        const i32 v = img[idx];
        if (v <= dthresh) return false;
        if (from <= athresh && v > from) return false;
        return visited[idx] != s;
    }

    bool spanCluster(i32 sx, i32 sy, i32 athresh, i32 dthresh, Blob &out) {
        const u16 s = nextStamp();
        u32 sp = 0;
        i64 W = 0, Sx = 0, Sy = 0, Sxx = 0, Syy = 0, Sxy = 0;

        if (!canEnter(sx, sy, 0x7fff, athresh, dthresh, s)) return false;
        visited[(u32)sy * w + (u32)sx] = s;
        stack[sp++] = StackItem{(i16)sx, (i16)sy};
        while (sp > 0) {
            const StackItem it = stack[--sp];
            const i32 x = it.x, y = it.y;
            const i32 v = at(x, y);

            W   += v;
            Sx  += (i64)v * x;
            Sy  += (i64)v * y;
            Sxx += (i64)v * x * x;
            Syy += (i64)v * y * y;
            Sxy += (i64)v * x * y;

            static const i8 dx[4] = {1, 0, -1, 0};
            static const i8 dy[4] = {0, 1, 0, -1};
            for (u32 k = 0; k < 4; k++) {
                const i32 nx = x + dx[k], ny = y + dy[k];
                if (!canEnter(nx, ny, v, athresh, dthresh, s)) continue;
                visited[(u32)ny * w + (u32)nx] = s;
                stack[sp++] = StackItem{(i16)nx, (i16)ny};
            }
        }
        if (W <= 0) return false;

        // Mean and covariance in fixed point (1/256 cell).
        const i64 mx = Sx * 256 / W;
        const i64 my = Sy * 256 / W;
        const i64 a = Sxx * 65536 / W - mx * mx;   // var x  (1/65536 cell^2)
        const i64 c = Syy * 65536 / W - my * my;   // var y
        const i64 b = Sxy * 65536 / W - mx * my;   // cov xy

        // Eigenvalues of [[a b][b c]]: (a+c)/2 +- sqrt(((a-c)/2)^2 + b^2)
        const i64 half_tr = (a + c) / 2;
        const i64 half_df = (a - c) / 2;
        const i64 d = (i64)isqrt64((u64)(half_df * half_df + b * b));
        const i64 l1 = half_tr + d;
        const i64 l2 = half_tr - d;
        if (l1 <= 0 || l2 <= 0) return false;    // iptsd discards degenerate blobs

        out.x_fp = (i32)(mx + 128);              // + 0.5 cell like iptsd
        out.y_fp = (i32)(my + 128);
        out.r_major_fp = (i32)isqrt64((u64)l1);  // sqrt(1/65536) = 1/256
        out.r_minor_fp = (i32)isqrt64((u64)l2);
        out.valid = true;
        return true;
    }

    u32 findBlobs(i32 athresh, i32 dthresh) {
        u32 n = 0;
        for (i32 x = 0; x < (i32)w && n < kMaxBlobs; x++) {
            for (i32 y = 0; y < (i32)h && n < kMaxBlobs; y++) {
                if (!isLocalMax(x, y, athresh)) continue;
                Blob b;
                if (spanCluster(x, y, athresh, dthresh, b))
                    blobs[n++] = b;
            }
        }
        last_blob_count = n;
        return n;
    }

    i32 fpToUmX(i64 fp) const { return (i32)(fp * cfg.width_um / ((i64)w * 256)); }
    i32 fpToUmY(i64 fp) const { return (i32)(fp * cfg.height_um / ((i64)h * 256)); }

    // iptsd: major = 2 * sqrt(eig) / data_diag * phys_diag
    i32 radiusToUm(i32 r_fp) const {
        const u64 data_diag_fp = isqrt64((u64)w * w * 65536 + (u64)h * h * 65536);   // 1/256 cells
        const u64 phys_diag = isqrt64((u64)cfg.width_um * cfg.width_um + (u64)cfg.height_um * cfg.height_um);
        if (data_diag_fp == 0) return 0;
        return (i32)(2 * (u64)r_fp * phys_diag / data_diag_fp);
    }

    u32 blobsToContacts(u32 nblobs, Contact *cur) {
        // classify
        Contact palms[kMaxBlobs];
        u32 npalm = 0, ncur = 0;
        for (u32 i = 0; i < nblobs; i++) {
            Blob &b = blobs[i];
            const i32 major_um = radiusToUm(b.r_major_fp);
            const i32 aspect_x100 = b.r_minor_fp > 0 ? (i32)((i64)b.r_major_fp * 100 / b.r_minor_fp) : 100000;
            b.valid = aspect_x100 >= 100 && aspect_x100 <= cfg.aspect_max_x100 &&
                      major_um >= cfg.size_min_um && major_um <= cfg.size_max_um;
            Contact c;
            c.active = true;
            c.id = 0;
            c.x_um = fpToUmX(b.x_fp);
            c.y_um = fpToUmY(b.y_fp);
            c.major_um = major_um;
            if (b.valid) {
                if (ncur < kMaxFingers) cur[ncur++] = c;
            } else {
                palms[npalm++] = c;
            }
        }
        if (!cfg.palm_rejection || npalm == 0) return ncur;

        // Drop fingers whose edge is within palm_dist of a palm edge
        // (iptsd check_dist(): circles of diameter = major axis).
        u32 kept = 0;
        for (u32 i = 0; i < ncur; i++) {
            bool near_palm = false;
            for (u32 j = 0; j < npalm && !near_palm; j++) {
                const i64 dx = cur[i].x_um - palms[j].x_um;
                const i64 dy = cur[i].y_um - palms[j].y_um;
                i64 dist = (i64)isqrt64((u64)(dx * dx + dy * dy));
                dist -= cur[i].major_um / 2;
                dist -= palms[j].major_um / 2;
                if (dist <= cfg.palm_dist_um) near_palm = true;
            }
            if (!near_palm) cur[kept++] = cur[i];
        }
        return kept;
    }

    // Greedy nearest-neighbour matching to keep contact ids stable
    // (same strategy as iptsd ContactFinder::track()).
    void track(Contact *cur, u32 ncur) {
        bool cur_used[kMaxFingers] = {false};
        bool prev_used[kMaxFingers] = {false};
        u32 ids_taken = 0;

        for (;;) {
            i64 best = -1;
            u32 bi = 0, bj = 0;
            for (u32 i = 0; i < ncur; i++) {
                if (cur_used[i]) continue;
                for (u32 j = 0; j < prev_count; j++) {
                    if (prev_used[j] || !prev[j].active) continue;
                    const i64 dx = cur[i].x_um - prev[j].x_um;
                    const i64 dy = cur[i].y_um - prev[j].y_um;
                    const i64 d2 = dx * dx + dy * dy;
                    if (best < 0 || d2 < best) { best = d2; bi = i; bj = j; }
                }
            }
            if (best < 0) break;
            cur_used[bi] = true;
            prev_used[bj] = true;
            Contact &c = cur[bi];
            const Contact &p = prev[bj];
            c.id = p.id;
            ids_taken |= 1u << p.id;

            // jitter suppression / movement stabilisation
            const i64 dist = (i64)isqrt64((u64)best);
            if (dist < cfg.jitter_um) {
                c.x_um = p.x_um;
                c.y_um = p.y_um;
            } else if (dist > 0) {
                const i64 dx = c.x_um - p.x_um;
                const i64 dy = c.y_um - p.y_um;
                c.x_um -= (i32)(cfg.jitter_um * dx / dist);
                c.y_um -= (i32)(cfg.jitter_um * dy / dist);
            }
        }
        // new fingers get the lowest free id
        for (u32 i = 0; i < ncur; i++) {
            if (cur_used[i]) continue;
            u8 id = 0;
            while (id < kMaxFingers && (ids_taken & (1u << id))) id++;
            if (id >= kMaxFingers) { cur[i].active = false; continue; }
            cur[i].id = id;
            ids_taken |= 1u << id;
        }
        // remember lifted contacts for one "touch up" report
        lifted_count = 0;
        for (u32 j = 0; j < prev_count; j++) {
            if (!prev_used[j] && prev[j].active && !(ids_taken & (1u << prev[j].id)))
                lifted[lifted_count++] = prev[j];
        }
        // store current as previous
        prev_count = 0;
        for (u32 i = 0; i < ncur; i++)
            if (cur[i].active) prev[prev_count++] = cur[i];
    }

    Contact lifted[kMaxFingers];
    u32 lifted_count = 0;

    void toLogical(const Contact &c, u16 &lx, u16 &ly) const {
        i64 x = (i64)c.x_um * kTouchMax / cfg.width_um;
        i64 y = (i64)c.y_um * kTouchMax / cfg.height_um;
        x = x < 0 ? 0 : (x > kTouchMax ? kTouchMax : x);
        y = y < 0 ? 0 : (y > kTouchMax ? kTouchMax : y);
        if (cfg.invert_x) x = kTouchMax - x;
        if (cfg.invert_y) y = kTouchMax - y;
        if (cfg.swap_xy) { i64 t = x; x = y; y = t; }
        lx = (u16)x;
        ly = (u16)y;
    }

    void emit(const Contact *cur, u32 ncur, TouchFrame &out) {
        __builtin_memset(&out, 0, sizeof(out));
        u32 k = 0;
        for (u32 i = 0; i < ncur && k < kMaxFingers; i++) {
            if (!cur[i].active) continue;
            Finger &f = out.fingers[k++];
            f.touch = true;
            f.id = cur[i].id;
            toLogical(cur[i], f.x, f.y);
        }
        for (u32 i = 0; i < lifted_count && k < kMaxFingers; i++) {
            Finger &f = out.fingers[k++];
            f.touch = false;
            f.id = lifted[i].id;
            toLogical(lifted[i], f.x, f.y);
        }
        out.count = (u8)k;
    }
};

// ---------------------------------------------------------------------------
// IPTS frame parser (port of iptsd ipts::Parser, minus DFT pen processing)
// ---------------------------------------------------------------------------
class FrameParser {
public:
    // protocol constants (iptsd protocol.hpp)
    enum : u8 {
        RAW_FRAME_TYPE_STYLUS  = 0x6,
        RAW_FRAME_TYPE_HEATMAP = 0x8,
        HID_FRAME_TYPE_HID     = 0x0,
        HID_FRAME_TYPE_HEATMAP = 0x1,
        HID_FRAME_TYPE_RAW     = 0xEE,
        HID_FRAME_TYPE_REPORTS = 0xFF,
        REPORT_TIMESTAMP  = 0x00,
        REPORT_DIMENSIONS = 0x03,
        REPORT_STYLUS_V1  = 0x10,
        REPORT_HEATMAP    = 0x25,
        REPORT_STYLUS_V2  = 0x60,
        REPORT_PEN_DFT_WINDOW = 0x5c,
    };

    struct Sink {
        virtual void onTouch(const TouchFrame &f) = 0;
        virtual void onStylus(const StylusFrame &s) = 0;
        virtual ~Sink() {}
    };

    explicit FrameParser(HeatmapProcessor &proc) : processor(proc) {
        dim_w = dim_h = 0; z_min = 0; z_max = 255;
        pen_in_range = false;
        heatmaps = errors = dft_windows = 0;
    }

    // buf points at a HID-style report: 1 byte report id + 2 byte timestamp,
    // followed by an ipts_hid_frame (same layout IPTSDaemon receives).
    bool parse(const u8 *buf, u32 len, Sink &sink) {
        Reader r(buf, len);
        if (!r.skip(3)) return fail();
        return parseFrame(r, sink) || fail();
    }

    // raw (GuC/"frame" type) data as delivered by IPTSDataTypeFrame
    bool parseRawPayload(const u8 *buf, u32 len, Sink &sink) {
        Reader r(buf, len);
        return parseRaw(r, sink) || fail();
    }

    bool penInRange() const { return pen_in_range; }
    u32 heatmapCount() const { return heatmaps; }
    u32 errorCount() const { return errors; }
    u32 dftWindowCount() const { return dft_windows; }

private:
    HeatmapProcessor &processor;
    u8 dim_w, dim_h, z_min, z_max;
    bool pen_in_range;
    u32 heatmaps, errors, dft_windows;

    bool fail() { errors++; return false; }

    bool parseFrame(Reader &r, Sink &sink) {
        const u32 size = r.u32v();
        r.u8v();
        const u8 type = r.u8v();
        r.u8v();
        if (!r.good() || size < 7) return false;
        Reader sub = r.sub(size - 7);
        if (!r.good()) return false;
        switch (type) {
            case HID_FRAME_TYPE_RAW: return parseRaw(sub, sink);
            case HID_FRAME_TYPE_HID: return parseHid(sub, sink);
            default: return true;
        }
    }

    bool parseRaw(Reader &r, Sink &sink) {
        r.u32v();                       // counter
        const u32 frames = r.u32v();
        r.skip(4);
        if (!r.good()) return false;
        for (u32 i = 0; i < frames && r.remaining() > 0; i++) {
            r.u16v();                   // index
            const u16 type = r.u16v();
            const u32 size = r.u32v();
            r.skip(8);
            Reader sub = r.sub(size);
            if (!r.good()) return false;
            if (type == RAW_FRAME_TYPE_STYLUS || type == RAW_FRAME_TYPE_HEATMAP)
                if (!parseReports(sub, sink)) return false;
        }
        return true;
    }

    bool parseHid(Reader &r, Sink &sink) {
        while (r.remaining() > 0) {
            const u32 size = r.u32v();
            r.u8v();
            const u8 type = r.u8v();
            r.u8v();
            if (!r.good() || size < 7) return false;
            Reader sub = r.sub(size - 7);
            if (!r.good()) return false;
            if (type == HID_FRAME_TYPE_HEATMAP) {
                // ipts_heatmap_header: 5 reserved bytes + u32 size
                sub.skip(5);
                const u32 hsize = sub.u32v();
                Reader data = sub.sub(hsize);
                if (!sub.good()) return false;
                if (!handleHeatmap(data, sink)) return false;
            } else if (type == HID_FRAME_TYPE_REPORTS) {
                // iptsd: SP7 sends a malformed 4-byte packet ~1/s; ignore it
                if (r.remaining() == 4) return true;
                if (!parseReports(sub, sink)) return false;
            }
        }
        return true;
    }

    bool parseReports(Reader &r, Sink &sink) {
        while (r.remaining() > 0) {
            const u8 type = r.u8v();
            r.u8v();                    // flags
            const u16 size = r.u16v();
            Reader sub = r.sub(size);
            if (!r.good()) return false;
            switch (type) {
                case REPORT_DIMENSIONS: {
                    const u8 height = sub.u8v();
                    const u8 width = sub.u8v();
                    sub.skip(4);        // y_min y_max x_min x_max
                    const u8 zmin = sub.u8v();
                    const u8 zmax = sub.u8v();
                    if (!sub.good()) return false;
                    dim_h = height; dim_w = width; z_min = zmin;
                    z_max = zmax ? zmax : 255;
                    break;
                }
                case REPORT_HEATMAP:
                    if (!handleHeatmap(sub, sink)) return false;
                    break;
                case REPORT_STYLUS_V1:
                    if (!parseStylus(sub, sink, false)) return false;
                    break;
                case REPORT_STYLUS_V2:
                    if (!parseStylus(sub, sink, true)) return false;
                    break;
                case REPORT_PEN_DFT_WINDOW:
                    // DFT pen processing stays in user space (IPTSDaemon).
                    dft_windows++;
                    break;
                default:
                    break;
            }
        }
        return true;
    }

    bool handleHeatmap(Reader &data, Sink &sink) {
        const u32 cells = (u32)dim_w * dim_h;
        if (cells == 0 || data.remaining() < cells) return false;
        TouchFrame f;
        if (!processor.process(data.cur(), data.remaining(), dim_w, dim_h, z_min, z_max, pen_in_range, f))
            return false;
        heatmaps++;
        sink.onTouch(f);
        return true;
    }

    bool parseStylus(Reader &r, Sink &sink, bool v2) {
        const u8 elements = r.u8v();
        r.skip(3);
        r.u32v();                       // serial
        if (!r.good()) return false;
        for (u8 i = 0; i < elements; i++) {
            StylusFrame s;
            u16 mode;
            if (v2) {
                s.timestamp = r.u16v();
                mode = r.u16v();
                s.x = r.u16v();
                s.y = r.u16v();
                s.pressure = r.u16v();
                r.u16v();               // altitude
                r.u16v();               // azimuth
                r.skip(2);
            } else {
                r.skip(4);
                mode = r.u8v();
                s.x = r.u16v();
                s.y = r.u16v();
                s.pressure = (u16)(r.u16v() * 4);
                r.skip(1);
                s.timestamp = 0;
            }
            if (!r.good()) return false;
            s.in_range = mode & 0x1;
            s.touch    = (mode >> 1) & 0x1;
            s.button   = (mode >> 2) & 0x1;
            s.rubber   = (mode >> 3) & 0x1;
            if (s.x > kStylusMaxX) s.x = kStylusMaxX;
            if (s.y > kStylusMaxY) s.y = kStylusMaxY;
            pen_in_range = s.in_range;
            sink.onStylus(s);
        }
        return true;
    }
};

} // namespace stm

#endif // STM_IPTS_KERNEL_PROCESSOR_HPP
