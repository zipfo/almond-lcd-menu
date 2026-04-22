#!/usr/bin/ucode
//
// lcd_ui.uc V260401 by Sublimity
//
// Архитектура: uloop (event loop) + ubus (system data) + uci (config)
// Данные: /tmp/lcd_data.json (от data_collector)
// Рендер: JSON через persistent unix socket → lcd_server / lcd_render
// Тач: ioctl /dev/lcd (kernel lcd_drv touch thread)
//
// Build: scp lcd_ui.uc root@192.168.11.1:/usr/bin/lcd_ui.uc
// Run:   ucode /usr/bin/lcd_ui.uc &
//

'use strict';

import { AF_UNIX, SOCK_STREAM, create as create_socket } from 'socket';
let fs = require("fs");

// No PID lock needed — procd manages single instance (no auto-restart loop below)

// Optional modules — graceful degrade
let ubus_mod, uci_mod, uloop_mod;
try { ubus_mod = require("ubus"); } catch(e) {}
try { uci_mod = require("uci"); } catch(e) {}
try { uloop_mod = require("uloop"); } catch(e) {}

// --- Constants ---
let LCD_W = 320, LCD_H = 240;
let SOCK_PATH = "/tmp/lcd.sock";
let DATA_PATH = "/tmp/lcd_data.json";
let TOUCH_PATH = "/tmp/.lcd_touch";
let SCRIPTS = "/etc/lcd/scripts";  // shell scripts directory

// Colors (lcd_render accepts: #RRGGBB, #XXXX raw RGB565, named)
let C = {
    bg:      "#0D1117", // GitHub Dark Canvas
    hdr:     "#161B22", // GitHub Dark Overlay
    white:   "#C9D1D9", // GH Text Primary
    green:   "#3FB950", // GH Success
    red:     "#F85149", // GH Danger
    yellow:  "#D29922", // GH Warning
    cyan:    "#58A6FF", // GH Accent Blue
    gray:    "#8B949E", // GH Text Secondary
    btn:     "#21262D", // GH Sub-panel
    back:    "#A40E26", // Subdued red for back bar
    accent:  "#58A6FF", // Same as cyan
    dim:     "#484F58", // GH Border/Dim
    widget:  "#161B22", // GitHub Dark Overlay
    border:  "#30363D", // GH Border
    transparent: "#000000" // the logo overlay uses black as transparent
};

// Timing (seconds)
let T = {
    data:   2,     // data refresh
    burnin: 30,    // anti-burn-in shift
    saver:  240,   // idle → screensaver (4 min)
    off:    300,   // idle → backlight off (5 min)
};

// Layout
let HDR_H   = 22;
let COLS    = 2;
let BTN_PAD = 4;
let BTN_W   = ((LCD_W - (BTN_PAD * 3)) / 2); // 154
let BTN_H   = 68;
let START_Y = HDR_H + BTN_PAD;
let BACK_Y  = LCD_H - 32;

// Touch: lcd_drv returns pixel coordinates directly (0-319, 0-239)
// No ADC mapping needed

// --- State ---
let st = {
    page:   "dashboard",
    mpg:    1,         // menu page (1 or 2)
    screen: "active",
    data:   {},        // sensor data from data_collector
    ltch:   time(),    // last touch time
    ldraw:  0,         // last draw time
    frame:  0,
    ox: 0, oy: 0,     // burn-in pixel offset
    tp:     false,     // touch was pressed (edge detection)
    saver_frame: 0,    // screensaver animation
};

// --- Connections ---
let uconn = null;
if (ubus_mod) {
    uconn = ubus_mod.connect();
    if (!uconn) warn("lcd_ui: ubus connect failed\n");
}

let ucur = null;
if (uci_mod) ucur = uci_mod.cursor();


// =============================================
//  LCD RENDER COMMUNICATION
// =============================================

let cmds = [];

function Q(j) {
    push(cmds, j);
}

function lcd_clear(c) {
    Q(sprintf('{"cmd":"clear","color":"%s"}', c ?? C.bg));
}

function lcd_rect(x, y, w, h, c) {
    Q(sprintf('{"cmd":"rect","x":%d,"y":%d,"w":%d,"h":%d,"color":"%s"}', x, y, w, h, c));
}

function lcd_text(x, y, text, color, bg, sz) {
    // Escape quotes and backslashes for JSON
    text = replace(replace(text ?? "", '\\', '\\\\'), '"', '\\"');
    Q(sprintf('{"cmd":"text","x":%d,"y":%d,"text":"%s","color":"%s","bg":"%s","size":%d}',
        x, y, text, color ?? C.white, bg ?? C.bg, sz ?? 2));
}

// Native socket — connect/send/close per flush (fast, no deadlock)
function lcd_flush() {
    if (!length(cmds)) return;
    push(cmds, '{"cmd":"flush"}');
    let payload = join("\n", cmds) + "\n";
    cmds = [];

    let s;
    try {
        s = create_socket(AF_UNIX, SOCK_STREAM, 0);
        s.connect(SOCK_PATH);
        s.send(payload);
        s.close();
    } catch(e) {
        try { s.close(); } catch(e2) {}
    }
}


// =============================================
//  HISTORY + TRAFFIC
// =============================================

let HIST_LEN = 60;

let hist = {
    rsrp:  [],   // LTE RSRP (dBm)
    rsrq:  [],   // LTE RSRQ (dB)
    ping:  [],   // Google ping ms
    rx:    [],   // wwan0 RX bytes/sec
    tx:    [],   // wwan0 TX bytes/sec
    wan_rx: [],  // wan RX bytes/sec
    wan_tx: [],  // wan TX bytes/sec
};

let last_net = null;

function hist_push(arr, val) {
    push(arr, val);
    if (length(arr) > HIST_LEN)
        splice(arr, 0, 1);
}

function collect_traffic() {
    let raw = fs.readfile("/proc/net/dev");
    if (!raw) return;
    let period = T.data > 0 ? T.data : 1;
    let now_net = {};
    for (let line in split(raw, "\n")) {
        let m = match(line, /^\s*(\S+):\s*(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)/);
        if (m)
            now_net[m[1]] = { rx: +m[2], tx: +m[3] };
    }
    if (last_net) {
        let delta = (iface, key) => {
            let cur = now_net[iface]?.[key] ?? 0;
            let prev = last_net[iface]?.[key] ?? 0;
            let d = cur - prev;
            return d >= 0 ? int(d / period) : 0;
        };
        hist_push(hist.rx, delta("wwan0", "rx"));
        hist_push(hist.tx, delta("wwan0", "tx"));
        hist_push(hist.wan_rx, delta("wan", "rx"));
        hist_push(hist.wan_tx, delta("wan", "tx"));
    }
    last_net = now_net;
}

function update_history() {
    let d = st.data;
    hist_push(hist.rsrp, int(+(d?.uqmi?.rsrp ?? 0)));
    hist_push(hist.rsrq, int(+(d?.uqmi?.rsrq ?? 0)));
    hist_push(hist.ping, int(+(d?.ping?.google_ms ?? 0)));
    collect_traffic();
}

// Line graph with scale, thresholds, and labels
// thresholds: [{val, color, label}, ...] — horizontal reference lines
function draw_graph(x, y, w, h, data, color, mn, mx, thresholds) {
    let n = length(data);
    if (n < 2) return;
    if (mx <= mn) mx = mn + 1;
    let range = mx - mn;

    // Background
    lcd_rect(x, y, w, h, "#0841");

    // Threshold lines (dashed — draw every 4px)
    if (thresholds) {
        for (let t in thresholds) {
            let ty2 = y + h - int((t.val - mn) / range * h);
            if (ty2 > y && ty2 < y + h) {
                for (let dx = 0; dx < w; dx += 8)
                    lcd_rect(x + dx, ty2, 4, 1, t.color ?? C.gray);
                // Label on right
                lcd_text(x + w - 30, ty2 - 4, t.label ?? "", t.color ?? C.gray, "#0841", 1);
            }
        }
    }

    // Scale labels (left: max, bottom: min)
    lcd_text(x + 1, y + 1, sprintf("%d", mx), C.gray, "#0841", 1);
    lcd_text(x + 1, y + h - 9, sprintf("%d", mn), C.gray, "#0841", 1);

    // Plot line: connect points
    let pts = n > HIST_LEN ? HIST_LEN : n;
    let start = n - pts;
    let step_x = (w - 2) / (pts - 1);

    let prev_px = -1, prev_py = -1;
    for (let i = 0; i < pts; i++) {
        let val = data[start + i];
        let px = x + 1 + int(i * step_x);
        let py = y + h - 1 - int((val - mn) / range * (h - 2));
        if (py < y) py = y;
        if (py >= y + h) py = y + h - 1;

        // Draw dot
        lcd_rect(px, py, 2, 2, color);

        // Connect to previous with vertical line segments
        if (prev_px >= 0) {
            let dy = py - prev_py;
            let steps = (dy > 0 ? dy : -dy);
            if (steps > 0) {
                let y_start = dy > 0 ? prev_py : py;
                lcd_rect(px, y_start, 1, steps, color);
            }
        }
        prev_px = px;
        prev_py = py;
    }

    // Current value — bright dot
    if (pts > 0) {
        let last_val = data[n - 1];
        let last_py = y + h - 1 - int((last_val - mn) / range * (h - 2));
        let last_px = x + w - 3;
        lcd_rect(last_px - 1, last_py - 1, 4, 4, C.white);
    }
}

function draw_graph_compact(x, y, w, h, data, color, mn, mx) {
    lcd_rect(x, y, w, h, "#0B1220");
    let n = length(data);
    if (n < 2) return;
    if (mx <= mn) mx = mn + 1;
    let range = mx - mn;
    let pts = n > HIST_LEN ? HIST_LEN : n;
    let start = n - pts;
    let step_x = (w - 2) / (pts - 1);
    let prev_px = -1, prev_py = -1;

    for (let i = 0; i < pts; i++) {
        let val = data[start + i];
        let px = x + 1 + int(i * step_x);
        let py = y + h - 1 - int((val - mn) / range * (h - 2));
        if (py < y) py = y;
        if (py >= y + h) py = y + h - 1;
        lcd_rect(px, py, 2, 2, color);
        if (prev_px >= 0) {
            let dy = py - prev_py;
            let ys = dy > 0 ? prev_py : py;
            lcd_rect(px, ys, 1, dy > 0 ? dy : -dy, color);
        }
        prev_px = px;
        prev_py = py;
    }
}

function arr_minmax(arr) {
    if (length(arr) == 0) return { min: 0, max: 1 };
    let mn = 999999, mx = -999999;
    for (let v in arr) {
        if (v < mn) mn = v;
        if (v > mx) mx = v;
    }
    return { min: mn, max: mx };
}


// =============================================
//  DATA COLLECTION
// =============================================

function refresh_data() {
    // Primary: data_collector JSON
    let raw = fs.readfile(DATA_PATH);
    let d = raw ? json(raw) : {};

    // EC21: uqmi script JSON
    let uqmi_raw = fs.readfile("/tmp/lte_uqmi.json");
    if (uqmi_raw) {
        d.uqmi = json(uqmi_raw);
    }

    // Supplement: ubus system info (more accurate uptime/mem/load)
    if (uconn) {
        let si = uconn.call("system", "info", {});
        if (si) {
            if (si.uptime) d.uptime = si.uptime;
            let mem = si.memory;
            if (mem) d.mem_free_mb = int((mem.available ?? mem.free ?? 0) / 1048576);
            if (si.load) d.cpu_load_raw = si.load[0];
        }
        
        let wan_st = uconn.call("network.interface.wan", "status", {});
        if (wan_st && wan_st["ipv4-address"] && length(wan_st["ipv4-address"]) > 0) {
            d.wan_ip = wan_st["ipv4-address"][0].address;
        } else {
            d.wan_ip = null;
        }
    }

    st.data = d;
    update_history();
}


// =============================================
//  TOUCH INPUT
// =============================================

// Touch: read directly from /dev/lcd via ioctl 1
// Returns {x, y} on press, null if not pressed
// Uses tiny C helper or direct /dev/lcd read
let touch_fd = null;
let touch_was_pressed = false;

function read_touch() {
    // Method 1: read touch file if touch_poll is running (legacy)
    let raw = fs.readfile(TOUCH_PATH);
    if (raw) {
        fs.unlink(TOUCH_PATH);
        let m = match(trim(raw), /^(\d+)\s+(\d+)/);
        if (m) return { x: +m[1], y: +m[2] };
    }
    // Poll /dev/lcd via the C touch helper
    let p = fs.popen("/tmp/touch_read 2>/dev/null", "r");
    if (p) {
        let line = p.read("line");
        p.close();
        if (line) {
            let m = match(trim(line), /^(\d+)\s+(\d+)\s+(\d+)/);
            if (m && +m[3] > 0) {
                if (!touch_was_pressed) {
                    touch_was_pressed = true;
                    return { x: +m[1], y: +m[2] };
                }
            } else {
                touch_was_pressed = false;
            }
        }
    }
    return null;
}


// =============================================
//  HELPERS
// =============================================

function lte_quality(rsrp) {
    if (rsrp < 0 && rsrp > -90)  return { label: "Excellent", bars: 5, color: C.green };
    if (rsrp <= -90 && rsrp > -100) return { label: "Good",      bars: 4, color: C.green };
    if (rsrp <= -100 && rsrp > -110) return { label: "OK",        bars: 3, color: C.yellow };
    if (rsrp <= -110 && rsrp > -120) return { label: "Weak",      bars: 2, color: C.yellow };
    if (rsrp <= -120 && rsrp < 0)    return { label: "Bad",       bars: 1, color: C.red };
    return { label: "No signal", bars: 0, color: C.red };
}

function get_plmn_name(mcc, mnc) {
    if (mcc == 250) {
        if (mnc == 1)  return "MTS";
        if (mnc == 2)  return "MegaFon";
        if (mnc == 11) return "Yota";
        if (mnc == 20) return "Tele2";
        if (mnc == 99) return "Beeline";
    }
    return null;
}

// Draw signal bars centered: n = bars (0-5), color, big = large bars
function draw_signal_bars(n, color, bg) {
    // Large centered bars: 5 bars, each 20px wide, 8px gap, centered on 320px screen
    // Total width: 5*20 + 4*8 = 132px, start x = (320-132)/2 = 94
    let base_x = 94, base_y = 190;  // bottom of bars area
    for (let i = 0; i < 5; i++) {
        let bh = 20 + i * 10;  // bar height: 20,30,40,50,60
        let bx = base_x + i * 28;
        let by = base_y - bh;
        let bc = (i < n) ? color : "#222222";
        lcd_rect(bx, by, 20, bh, bc);
    }
    // Label below bars
    let lq = lte_quality(0);  // dummy, caller should pass label
    lcd_text(base_x, base_y + 4, sprintf("%d/5", n), color, bg, 2);
}

function fmt_bytes(b) {
    b = +(b ?? 0);
    if (b >= 1073741824) return sprintf("%.1fG", b / 1073741824);
    if (b >= 1048576) return sprintf("%.1fM", b / 1048576);
    if (b >= 1024) return sprintf("%.0fK", b / 1024);
    return sprintf("%d", b);
}

function fmt_uptime(s) {
    s = int(+(s ?? 0));
    let d = int(s / 86400);
    let h = int((s % 86400) / 3600);
    let m = int((s % 3600) / 60);
    if (d > 0) return sprintf("%dd%dh%dm", d, h, m);
    if (h > 0) return sprintf("%dh%dm", h, m);
    return sprintf("%dm", m);
}

function clock_str() {
    let t = localtime();
    return t ? sprintf("%02d:%02d", t.hour, t.min) : "--:--";
}

function date_str() {
    let t = localtime();
    return t ? sprintf("%02d-%02d-%02d", t.mday, t.mon, t.year % 100) : "--:--:--";
}

function saver_timeout() {
    return st.page == "dashboard" ? 10 : 30;
}

function btn_pos(idx) {
    let col = (idx - 1) % COLS;
    let row = int((idx - 1) / COLS);
    return {
        x: BTN_PAD + col * (BTN_W + BTN_PAD),
        y: START_Y + row * (BTN_H + BTN_PAD),
        w: BTN_W,
        h: BTN_H,
    };
}

function in_rect(tx, ty, bx, by, bw, bh) {
    return tx >= bx && tx <= bx + bw && ty >= by && ty <= by + bh;
}

function wifi_is_disabled(radio_section, default_section) {
    let radio_dis = ucur ? ucur.get("wireless", radio_section, "disabled") : null;
    let default_dis = ucur ? ucur.get("wireless", default_section, "disabled") : null;
    return radio_dis == "1" || default_dis == "1";
}


// =============================================
//  DRAWING: COMMON
// =============================================

function draw_header(title, bg_c) {
    bg_c ??= C.hdr;
    lcd_rect(0, 0, LCD_W, HDR_H, bg_c);
    lcd_rect(0, HDR_H, LCD_W, 1, C.border); // header bottom line

    let d = st.data;
    let u = d?.uqmi;
    let rsrp = int(+(u?.rsrp ?? 0));
    let lq = lte_quality(rsrp);

    // Left Group: MNCMCC + signal bricks
    let x = 4;
    let mcc = int(+(u?.mcc ?? 0));
    let mnc = int(+(u?.mnc ?? 0));
    
    let plmn_str = "";
    if (mcc > 0) {
        plmn_str = sprintf("%03d%02d", mcc, mnc);
    } else {
        plmn_str = "N/A";
    }
    // Limit string to prevent overlap (max 10 chars is ~120px)
    if (length(plmn_str) > 10) plmn_str = substr(plmn_str, 0, 10);
    
    lcd_text(x, 4, plmn_str, C.white, bg_c, 2);
    x += length(plmn_str) * 12 + 8; // add spacer

    // Signal bar
    for (let i = 0; i < 5; i++) {
        let bc = (i < lq.bars) ? lq.color : C.dim;
        lcd_rect(x + i * 7, 4, 5, 14, bc);
    }
    
    // Right Group (render right-to-left starting from 320)
    let cx = LCD_W;

    // Clock
    let tstr = clock_str();
    cx -= (length(tstr) * 12 + 4);
    lcd_text(cx, 4, tstr, C.cyan, bg_c, 2);

    // Vertical spacer
    cx -= 6;
    lcd_rect(cx, 4, 2, 14, C.dim);
    let sep_x = cx;

    // Battery percent
    let bat = d?.battery;
    let bchg = bat?.charging && !bat?.no_battery;
    let bpct = int(+(bat?.percent ?? 0));
    let bstr = sprintf("%d", bpct);
    if (bat?.no_battery) bstr = "--";
    let btxt_w = length(bstr) * 12;
    let b_w = 32;
    let b_h = 16;
    let b_y = 3;
    cx -= (btxt_w + 6 + (bchg ? 10 : 0));
    lcd_text(cx, 4, bstr, C.white, bg_c, 2);
    if (bchg) {
        let gx = cx + btxt_w + 2;
        lcd_rect(gx + 4, b_y + 5, 5, 5, C.green);

    }

    // Battery rectangle
    cx -= 40;
    // Outer frame
    lcd_rect(cx, b_y, b_w, b_h, C.gray);
    // Inside empty out
    lcd_rect(cx + 1, b_y + 1, b_w - 2, b_h - 2, bg_c);
    // Terminal cap
    lcd_rect(cx + b_w, b_y + 5, 2, 6, C.gray);

    // 4 sections based on percent
    let sections = 0;
    if (bpct > 75) sections = 4;
    else if (bpct > 50) sections = 3;
    else if (bpct > 25) sections = 2;
    else if (bpct > 0) sections = 1;
    
    if (!bat?.no_battery) {
        for (let i = 0; i < 4; i++) {
            let s_color = (i < sections) ? (sections == 1 ? C.red : (sections == 2 ? C.yellow : C.green)) : bg_c;
            lcd_rect(cx + 3 + i * 7, b_y + 2, 5, b_h - 4, s_color);
        }
    }
}

function draw_back() {
    lcd_rect(0, BACK_Y, LCD_W, 32, C.back);
    lcd_rect(0, BACK_Y, LCD_W, 2, "#D32F2F"); // top highlight
    lcd_text(120, BACK_Y + 9, "< BACK", C.white, C.back, 2);
}

function draw_btn(idx, title, subtitle, title_c, sub_c, bg_c) {
    let b = btn_pos(idx);
    let bg = bg_c ?? C.btn;
    lcd_rect(b.x, b.y, b.w, b.h, bg);
    lcd_rect(b.x, b.y + b.h - 3, b.w, 3, C.border); // internal shadow element
    lcd_text(b.x + 8, b.y + 8, title, title_c ?? C.white, bg, 2);
    if (subtitle)
        lcd_text(b.x + 8, b.y + 38, subtitle, sub_c ?? C.gray, bg, 1);
}


// =============================================
//  DRAWING: DASHBOARD
// =============================================

function draw_dashboard() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header();

    let ox = st.ox, oy = st.oy;
    let cx = 10 + ox;
    let cw = 300;
    
    // --- 1. WWAN ---
    let y1 = 32 + oy;
    lcd_rect(cx, y1, cw, 56, C.widget);
    lcd_rect(cx, y1, 4, 56, "#D2A8FF"); // Magenta accent
    lcd_text(cx + 16, y1 + 10, "WWAN IP (LTE)", C.gray, C.widget, 1);
    let wwan_ip = d?.lte?.ip ?? d?.uqmi?.ip ?? "Disconnected";
    lcd_text(cx + 16, y1 + 26, wwan_ip, (wwan_ip == "Disconnected" || wwan_ip == "") ? C.dim : C.white, C.widget, 2);

    // --- 2. WAN ---
    let y2 = y1 + 64;
    lcd_rect(cx, y2, cw, 56, C.widget);
    lcd_rect(cx, y2, 4, 56, C.cyan); // Blue accent
    lcd_text(cx + 16, y2 + 10, "WAN IP (ETH)", C.gray, C.widget, 1);
    let wan_ip = d?.wan_ip ?? "Disconnected";
    lcd_text(cx + 16, y2 + 26, wan_ip, (wan_ip == "Disconnected" || wan_ip == "") ? C.dim : C.white, C.widget, 2);

    // --- 3. WIFI ---
    let y3 = y2 + 64;
    lcd_rect(cx, y3, cw, 56, C.widget);
    lcd_rect(cx, y3, 4, 56, C.green); // Green accent
    lcd_text(cx + 16, y3 + 10, "WI-FI STATUS", C.gray, C.widget, 1);
    
    let w_clients = d?.wifi?.clients;
    let nc = type(w_clients) == "array" ? length(w_clients) : 0;
    let wifi_str = nc > 0 ? sprintf("%d Connected Client%s", nc, nc == 1 ? "" : "s") : "No Clients";
    lcd_text(cx + 16, y3 + 26, wifi_str, nc > 0 ? C.white : C.dim, C.widget, 2);
    
    lcd_flush();
}


// =============================================
//  DRAWING: MAIN MENU
// =============================================

function draw_menu() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header();

    if (st.mpg == 1) {
        // 1: WiFi
        let nc = type(d?.wifi?.clients) == "array" ? length(d.wifi.clients) : 0;
        draw_btn(1, "WiFi",
            sprintf("%d clients", nc),
            C.white, C.gray);

        // 2: Modem
        let u = d?.uqmi;
        let rsrp = int(+(u?.rsrp ?? 0));
        let lq = lte_quality(rsrp);
        draw_btn(2, "Modem",
            sprintf("%s", lq.label),
            C.white, C.gray);

        // 3: Traffic
        let rx_last = length(hist.rx) > 0 ? hist.rx[length(hist.rx) - 1] : 0;
        let tx_last = length(hist.tx) > 0 ? hist.tx[length(hist.tx) - 1] : 0;
        draw_btn(3, "Traffic",
            sprintf("R:%s T:%s", fmt_bytes(rx_last), fmt_bytes(tx_last)),
            C.white, C.gray);

        // 4: Info
        draw_btn(4, "Info",
            fmt_uptime(d?.uptime),
            C.white, C.gray);

        // 5: Dashboard
        draw_btn(5, "Dashboard", "Back to dash", C.white, C.gray);

        // 6: MORE
        let b = btn_pos(6);
        lcd_rect(b.x, b.y, b.w, b.h, C.hdr);
        lcd_text(b.x + 20, b.y + 20, "MORE >>>", C.white, C.hdr, 2);
    } else {
        // Page 2
        // 1: Reboot (with confirmation)
        draw_btn(1, "Reboot", "System", C.white, C.gray);

        // 2: Modem Reset
        draw_btn(2, "Modem Reset", "LTE restart", C.white, C.gray);

        // 6: <<< BACK
        let b = btn_pos(6);
        lcd_rect(b.x, b.y, b.w, b.h, C.hdr);
        lcd_text(b.x + 20, b.y + 20, "<<< BACK", C.white, C.hdr, 2);
    }

    lcd_flush();
}


// =============================================
//  DRAWING: SUB-PAGES
// =============================================

function draw_wifi_page() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header("WiFi");

    let ox = st.ox, oy = st.oy;
    let cx = 10 + ox;
    let cw = 300;

    // Card 1: 2.4GHz WiFi (radio1)
    let y1 = 28 + oy;
    let disabled_2g_state = ucur ? wifi_is_disabled("radio1", "default_radio1") : true;
    lcd_rect(cx, y1, cw, 80, C.widget);
    lcd_rect(cx, y1, 4, 80, disabled_2g_state ? C.dim : C.green);
    lcd_text(cx + 10, y1 + 6, "2.4 GHz", C.gray, C.widget, 1);
    
    if (ucur) {
        let ssid_2g = ucur.get("wireless", "default_radio1", "ssid") ?? "N/A";
        let key_2g = ucur.get("wireless", "default_radio1", "key") ?? "N/A";
        let disabled_2g = wifi_is_disabled("radio1", "default_radio1");
        
        lcd_text(cx + 10, y1 + 20, sprintf("SSID: %s", ssid_2g), C.white, C.widget, 2);
        lcd_text(cx + 10, y1 + 38, sprintf("Pass: %s", key_2g), C.accent, C.widget, 2);
        
        // Count clients on 2.4GHz
        let clients_2g = 0;
        let clients = d?.wifi?.clients;
        if (type(clients) == "array") {
            for (let cl in clients) {
                if (cl.band == "2.4G") clients_2g++;
            }
        }
        lcd_text(cx + 10, y1 + 56, sprintf("Clients: %d", clients_2g), C.cyan, C.widget, 2);
        
        let status_2g = disabled_2g ? "OFF" : "ON";
        let status_c_2g = disabled_2g ? C.gray : C.green;
        lcd_text(cx + 220, y1 + 56, status_2g, status_c_2g, C.widget, 2);
    }

    // Card 2: 5GHz WiFi (radio0)
    let y2 = y1 + 86;
    let disabled_5g_state = ucur ? wifi_is_disabled("radio0", "default_radio0") : true;
    lcd_rect(cx, y2, cw, 80, C.widget);
    lcd_rect(cx, y2, 4, 80, disabled_5g_state ? C.dim : C.green);
    lcd_text(cx + 10, y2 + 6, "5 GHz", C.gray, C.widget, 1);
    
    if (ucur) {
        let ssid_5g = ucur.get("wireless", "default_radio0", "ssid") ?? "N/A";
        let key_5g = ucur.get("wireless", "default_radio0", "key") ?? "N/A";
        let disabled_5g = wifi_is_disabled("radio0", "default_radio0");
        
        lcd_text(cx + 10, y2 + 20, sprintf("SSID: %s", ssid_5g), C.white, C.widget, 2);
        lcd_text(cx + 10, y2 + 38, sprintf("Pass: %s", key_5g), C.accent, C.widget, 2);
        
        // Count clients on 5GHz
        let clients_5g = 0;
        let clients = d?.wifi?.clients;
        if (type(clients) == "array") {
            for (let cl in clients) {
                if (cl.band == "5G") clients_5g++;
            }
        }
        lcd_text(cx + 10, y2 + 56, sprintf("Clients: %d", clients_5g), C.cyan, C.widget, 2);
        
        let status_5g = disabled_5g ? "OFF" : "ON";
        let status_c_5g = disabled_5g ? C.gray : C.green;
        lcd_text(cx + 220, y2 + 56, status_5g, status_c_5g, C.widget, 2);
    }

    draw_back();
    lcd_flush();
}

function draw_info_page() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header("System Info");

    let ox = st.ox, oy = st.oy;
    let cx = 10 + ox;
    let cw = 300;
    let board = null;
    if (uconn)
        board = uconn.call("system", "board", {});

    let load = d?.cpu_load_raw ? sprintf("%.2f", d.cpu_load_raw / 65536.0)
             : (d?.cpu_load ?? "?");
    let bat = d?.battery;
    let braw = bat?.raw_hex ?? "??";
    let badc = int(+(bat?.adc ?? 0));
    let bpct = int(+(bat?.percent ?? 0));

    // lcd_drv version (via touch_poll version helper)
    let drv_ver = "?";
    let p = fs.popen("touch_poll version 2>/dev/null", "r");
    if (p) {
        drv_ver = trim(p.read("all") ?? "?");
        p.close();
    }

    // Card 1: System
    let y1 = 28 + oy;
    lcd_rect(cx, y1, cw, 52, C.widget);
    lcd_rect(cx, y1, 4, 52, C.cyan);
    lcd_text(cx + 10, y1 + 6, "SYSTEM", C.gray, C.widget, 1);
    lcd_text(cx + 10, y1 + 20, "Model Almond 3S", C.white, C.widget, 1);
    lcd_text(cx + 10, y1 + 32, sprintf("Uptime %s", fmt_uptime(d?.uptime)), C.white, C.widget, 1);
    lcd_text(cx + 150, y1 + 32, sprintf("Mem %dM", int(+(d?.mem_free_mb ?? 0))), C.green, C.widget, 1);
    lcd_text(cx + 10, y1 + 44, sprintf("CPU %s", load), C.accent, C.widget, 1);

    // Card 2: Power
    let y2 = y1 + 58;
    lcd_rect(cx, y2, cw, 52, C.widget);
    lcd_rect(cx, y2, 4, 52, bat?.no_battery ? C.dim : (bat?.valid ? C.green : C.red));
    lcd_text(cx + 10, y2 + 6, "POWER", C.gray, C.widget, 1);
    if (bat?.no_battery) {
        lcd_text(cx + 10, y2 + 20, "Battery not installed", C.dim, C.widget, 1);
        lcd_text(cx + 10, y2 + 32, sprintf("ADC %d", badc), C.dim, C.widget, 1);
    } else {
        let bat_state = bat?.charging ? "Charging" : "Battery";
        let bat_color = bat?.valid ? (bpct > 20 ? C.green : C.yellow) : C.red;
        lcd_text(cx + 10, y2 + 20, sprintf("%s %d%%", bat_state, bpct), bat_color, C.widget, 1);
        lcd_text(cx + 120, y2 + 20, sprintf("ADC %d", badc), C.white, C.widget, 1);
        lcd_text(cx + 10, y2 + 32, sprintf("Raw %s", braw), C.dim, C.widget, 1);
    }
    lcd_text(cx + 10, y2 + 44, bat?.valid ? "Status OK" : "Status invalid", bat?.valid ? C.green : C.red, C.widget, 1);

    // Card 3: Software
    let y3 = y2 + 58;
    lcd_rect(cx, y3, cw, 52, C.widget);
    lcd_rect(cx, y3, 4, 52, "#D2A8FF");
    lcd_text(cx + 10, y3 + 6, "SOFTWARE", C.gray, C.widget, 1);
    lcd_text(cx + 10, y3 + 20, sprintf("OpenWrt %s", board?.release?.version ?? "?"), C.white, C.widget, 1);
    lcd_text(cx + 10, y3 + 32, sprintf("Kernel %s", board?.kernel ?? "?"), C.dim, C.widget, 1);
    lcd_text(cx + 10, y3 + 44, sprintf("lcd_drv %s", drv_ver), C.accent, C.widget, 1);

    draw_back();
    lcd_flush();
}

function draw_ip_page() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header("External IP");
    let y = 30;

    let eip = d?.vpn?.external_ip ?? "unknown";
    lcd_text(4, y, "Exit IP:", C.cyan, C.bg, 2);
    y += 22;
    lcd_text(4, y, eip, C.accent, C.bg, 3);
    y += 30;

    let vpn = d?.vpn?.active;
    lcd_text(4, y, vpn ? "via VPN (WireGuard)" : "Direct (no VPN)",
        vpn ? C.green : C.red, C.bg, 2);
    y += 24;

    let ping_g = int(+(d?.ping?.google_ms ?? -1));
    let ping_v = int(+(d?.vpn?.ping_ms ?? -1));
    let pg_s = ping_g < 0 ? "FAIL" : sprintf("%dms", ping_g);
    let pv_s = ping_v < 0 ? "FAIL" : sprintf("%dms", ping_v);
    lcd_text(4, y, sprintf("Google: %s  VPN: %s", pg_s, pv_s), C.white, C.bg, 1);
    y += 14;

    // LTE IP for reference
    let lip = d?.lte?.ip ?? "?";
    lcd_text(4, y, sprintf("LTE IP: %s", lip), C.gray, C.bg, 1);

    draw_back();
    lcd_flush();
}

function draw_lte_page() {
    let d = st.data;
    let u = d?.uqmi;
    lcd_clear(C.bg);
    draw_header("Modem");

    let ox = st.ox, oy = st.oy;
    let cx = 10 + ox;
    let cw = 300;

    let rsrp = int(+(u?.rsrp ?? 0));
    let rsrq = int(+(u?.rsrq ?? 0));
    let sinr = int(+(u?.sinr ?? 0));
    let rssi = int(+(u?.rssi ?? 0));
    let band = u?.band ?? "N/A";
    let mode = u?.mode ?? "N/A";
    let pci = int(+(u?.pci ?? 0));
    let enb = int(+(u?.enb_id ?? 0));
    let cid = int(+(u?.cell_id ?? 0));
    let mcc = int(+(u?.mcc ?? 0));
    let mnc = int(+(u?.mnc ?? 0));
    let plmn_name = get_plmn_name(mcc, mnc);
    let ip = d?.lte?.ip ?? d?.uqmi?.ip ?? "N/A";

    // Card 1: modem state + radio metrics
    let y1 = 28 + oy;
    lcd_rect(cx, y1, cw, 46, C.widget);
    lcd_rect(cx, y1, 4, 46, C.green);
    lcd_text(cx + 10, y1 + 6, "MODEM STATUS", C.gray, C.widget, 1);
    let rsrp_c = rsrp > -90 ? C.green : (rsrp > -105 ? C.yellow : C.red);
    lcd_text(cx + 10, y1 + 18, sprintf("Mode %s", mode), C.white, C.widget, 1);
    lcd_text(cx + 105, y1 + 18, sprintf("Band %s", band), C.white, C.widget, 1);
    lcd_text(cx + 10, y1 + 32, sprintf("RSRP %d", rsrp), rsrp_c, C.widget, 1);
    lcd_text(cx + 90, y1 + 32, sprintf("RSRQ %d", rsrq), C.cyan, C.widget, 1);
    lcd_text(cx + 170, y1 + 32, sprintf("SINR %d", sinr), C.white, C.widget, 1);
    lcd_text(cx + 245, y1 + 32, sprintf("RSSI %d", rssi), C.dim, C.widget, 1);

    // Card 2: serving cell
    let y2 = y1 + 52;
    lcd_rect(cx, y2, cw, 46, C.widget);
    lcd_rect(cx, y2, 4, 46, C.cyan);
    lcd_text(cx + 10, y2 + 6, "SERVING CELL", C.gray, C.widget, 1);
    lcd_text(cx + 10, y2 + 18, sprintf("PCI %d", pci), C.white, C.widget, 1);
    lcd_text(cx + 85, y2 + 18, sprintf("eNB %d", enb), C.white, C.widget, 1);
    lcd_text(cx + 170, y2 + 18, sprintf("CID %d", cid), C.white, C.widget, 1);
    lcd_text(cx + 10, y2 + 32, sprintf("PLMN %d-%d", mcc, mnc), C.white, C.widget, 1);
    if (plmn_name)
        lcd_text(cx + 135, y2 + 32, plmn_name, C.accent, C.widget, 1);

    // Card 3: network identity
    let y3 = y2 + 52;
    lcd_rect(cx, y3, cw, 46, C.widget);
    lcd_rect(cx, y3, 4, 46, "#D2A8FF");
    lcd_text(cx + 10, y3 + 6, "NETWORK", C.gray, C.widget, 1);
    lcd_text(cx + 10, y3 + 18, sprintf("IP %s", ip), C.white, C.widget, 1);
    lcd_text(cx + 10, y3 + 32, sprintf("Operator %s", d?.lte?.operator ?? "Unknown"), C.dim, C.widget, 1);

    draw_back();
    lcd_flush();
}

function draw_traffic_page() {
    lcd_clear(C.bg);
    draw_header("Traffic");

    // Fixed coordinates here: avoid burn-in shifting artifacts
    let cx = 10;
    let cw = 300;

    // LTE / WWAN
    let rx_last = length(hist.rx) > 0 ? hist.rx[length(hist.rx) - 1] : 0;
    let tx_last = length(hist.tx) > 0 ? hist.tx[length(hist.tx) - 1] : 0;
    let y1 = 28;
    lcd_rect(cx, y1, cw, 72, C.widget);
    lcd_rect(cx, y1, 4, 72, C.cyan);
    lcd_text(cx + 10, y1 + 6, "LTE / WWAN", C.gray, C.widget, 1);
    lcd_text(cx + 10, y1 + 20, "RX", C.green, C.widget, 1);
    lcd_text(cx + 32, y1 + 20, fmt_bytes(rx_last) + "/s", C.white, C.widget, 1);
    lcd_text(cx + 165, y1 + 20, "TX", C.red, C.widget, 1);
    lcd_text(cx + 187, y1 + 20, fmt_bytes(tx_last) + "/s", C.white, C.widget, 1);

    let rm = arr_minmax(hist.rx);
    let tm = arr_minmax(hist.tx);
    let mx1 = rm.max > tm.max ? rm.max : tm.max;
    if (mx1 < 10240) mx1 = 10240;
    draw_graph_compact(cx + 8, y1 + 34, cw - 16, 28, hist.rx, C.green, 0, mx1);
    let n = length(hist.tx);
    if (n >= 2) {
        let pts = n > HIST_LEN ? HIST_LEN : n;
        let start = n - pts;
        let step_x = ((cw - 16) - 2) / (pts - 1);
        let prev_px = -1, prev_py = -1;
        for (let i = 0; i < pts; i++) {
            let val = hist.tx[start + i];
            let px = cx + 9 + int(i * step_x);
            let py = y1 + 61 - int(val / mx1 * 26);
            if (py < y1 + 34) py = y1 + 34;
            if (py > y1 + 61) py = y1 + 61;
            lcd_rect(px, py, 2, 2, C.red);
            if (prev_px >= 0) {
                let dy = py - prev_py;
                let ys = dy > 0 ? prev_py : py;
                lcd_rect(px, ys, 1, (dy > 0 ? dy : -dy), C.red);
            }
            prev_px = px; prev_py = py;
        }
    }

    // WAN / Ethernet
    let wan_rx = length(hist.wan_rx) > 0 ? hist.wan_rx[length(hist.wan_rx) - 1] : 0;
    let wan_tx = length(hist.wan_tx) > 0 ? hist.wan_tx[length(hist.wan_tx) - 1] : 0;
    let y2 = y1 + 78;
    lcd_rect(cx, y2, cw, 72, C.widget);
    lcd_rect(cx, y2, 4, 72, C.yellow);
    lcd_text(cx + 10, y2 + 6, "WAN / ETHERNET", C.gray, C.widget, 1);
    lcd_text(cx + 10, y2 + 20, "RX", C.green, C.widget, 1);
    lcd_text(cx + 32, y2 + 20, fmt_bytes(wan_rx) + "/s", C.white, C.widget, 1);
    lcd_text(cx + 165, y2 + 20, "TX", C.red, C.widget, 1);
    lcd_text(cx + 187, y2 + 20, fmt_bytes(wan_tx) + "/s", C.white, C.widget, 1);

    let brm = arr_minmax(hist.wan_rx);
    let btm = arr_minmax(hist.wan_tx);
    let mx2 = brm.max > btm.max ? brm.max : btm.max;
    if (mx2 < 10240) mx2 = 10240;
    draw_graph_compact(cx + 8, y2 + 34, cw - 16, 28, hist.wan_rx, C.green, 0, mx2);
    let n2 = length(hist.wan_tx);
    if (n2 >= 2) {
        let pts = n2 > HIST_LEN ? HIST_LEN : n2;
        let start = n2 - pts;
        let step_x = ((cw - 16) - 2) / (pts - 1);
        let prev_px = -1, prev_py = -1;
        for (let i = 0; i < pts; i++) {
            let val = hist.wan_tx[start + i];
            let px = cx + 9 + int(i * step_x);
            let py = y2 + 61 - int(val / mx2 * 26);
            if (py < y2 + 34) py = y2 + 34;
            if (py > y2 + 61) py = y2 + 61;
            lcd_rect(px, py, 2, 2, C.red);
            if (prev_px >= 0) {
                let dy = py - prev_py;
                let ys = dy > 0 ? prev_py : py;
                lcd_rect(px, ys, 1, (dy > 0 ? dy : -dy), C.red);
            }
            prev_px = px; prev_py = py;
        }
    }

    draw_back();
    lcd_flush();
}


// =============================================
//  PAGE DRAWING DISPATCH
// =============================================

function draw_current() {
    switch (st.page) {
    case "dashboard": draw_dashboard(); break;
    case "menu":      draw_menu(); break;
    case "wifi":      draw_wifi_page(); break;
    case "info":      draw_info_page(); break;
    case "ip":        draw_ip_page(); break;
    case "lte":       draw_lte_page(); break;
    case "traffic":   draw_traffic_page(); break;
    }
}


// =============================================
//  SCREENSAVER
// =============================================

function draw_screensaver() {
    let t = localtime();
    let night = t ? (t.hour >= 22 || t.hour < 6) : false;
    let bg = night ? "#000000" : C.bg;
    let primary = night ? "#1F6F3D" : C.white;
    let secondary = night ? "#1F6F3D" : C.gray;
    let accent = night ? "#1F6F3D" : C.accent;
    let rx_c = night ? "#1F6F3D" : C.green;
    let tx_c = night ? "#1F6F3D" : C.red;

    lcd_clear(bg);

    let d = st.data;
    let ts = clock_str();
    let ds = date_str();

    lcd_text(100, 22, ts, primary, bg, 4);
    lcd_text(118, 64, ds, secondary, bg, 2);

    let bat = d?.battery;
    let bpct = int(+(bat?.percent ?? 0));
    let bchg = bat?.charging;
    let bno = bat?.no_battery;
    let bat_txt = bno ? "--" : (bat?.valid ? sprintf("%d%s", bpct, bchg ? "+" : "") : "?");
    let bat_txt_c = bno ? secondary : (bat?.valid ? primary : tx_c);
    let bx = 118, by = 98, bw = 80, bh = 34;
    lcd_rect(bx, by, bw, bh, secondary);
    lcd_rect(bx + 2, by + 2, bw - 4, bh - 4, bg);
    lcd_rect(bx + bw, by + 10, 4, 14, secondary);
    lcd_text(bx + 5, by + 6, bat_txt, bat_txt_c, bg, 3);

    let rx_wwan = length(hist.rx) > 0 ? hist.rx[length(hist.rx) - 1] : 0;
    let tx_wwan = length(hist.tx) > 0 ? hist.tx[length(hist.tx) - 1] : 0;
    let rx_wan = length(hist.wan_rx) > 0 ? hist.wan_rx[length(hist.wan_rx) - 1] : 0;
    let tx_wan = length(hist.wan_tx) > 0 ? hist.wan_tx[length(hist.wan_tx) - 1] : 0;
    let ty = 154;
    let table_border = night ? "#184D2A" : C.border;
    let tx0 = 30;
    let tw = 246;
    let th = 66;
    let mid = tx0 + int(tw / 2);
    let pad = 5;
    lcd_rect(tx0, ty - 4, tw, th, table_border);
    lcd_rect(tx0 + 1, ty - 3, tw - 2, th - 2, bg);
    lcd_rect(mid, ty - 3, 1, th - 2, table_border);
    lcd_rect(tx0 + 1, ty + 16, tw - 2, 1, table_border);

    lcd_text(tx0 + pad + 24, ty + 2, "WWAN", accent, bg, 2);
    lcd_text(mid + pad + 36, ty + 2, "WAN", accent, bg, 2);

    lcd_text(tx0 + pad, ty + 24, "RX:", rx_c, bg, 2);
    lcd_text(tx0 + pad + 40, ty + 24, fmt_bytes(rx_wwan), primary, bg, 2);
    lcd_text(tx0 + pad, ty + 45, "TX:", tx_c, bg, 2);
    lcd_text(tx0 + pad + 40, ty + 45, fmt_bytes(tx_wwan), primary, bg, 2);

    lcd_text(mid + pad, ty + 24, "RX:", rx_c, bg, 2);
    lcd_text(mid + pad + 40, ty + 24, fmt_bytes(rx_wan), primary, bg, 2);
    lcd_text(mid + pad, ty + 45, "TX:", tx_c, bg, 2);
    lcd_text(mid + pad + 40, ty + 45, fmt_bytes(tx_wan), primary, bg, 2);

    if (night)
        lcd_text(50, 224, "Wake up, Neo...The Matrix has you...", secondary, bg, 1);

    lcd_flush();
}


// =============================================
//  TOUCH HANDLING
// =============================================

// Run shell script from SCRIPTS dir (non-blocking with &)
function run_script(name, bg) {
    let cmd = SCRIPTS + "/" + name;
    if (bg) cmd += " &";
    system(cmd);
}

function go_page(p) {
    st.page = p;
    draw_current();
}

// Toast notification — overlay message with auto-dismiss
function toast(msg, color, bg_color, wait_sec) {
    color ??= C.white;
    bg_color ??= "#1082";
    wait_sec ??= 0;

    // Draw toast bar at bottom
    lcd_rect(0, LCD_H - 36, LCD_W, 36, bg_color);
    lcd_rect(0, LCD_H - 37, LCD_W, 1, color);  // top border
    lcd_text(10, LCD_H - 30, msg, color, bg_color, 2);
    lcd_flush();

    if (wait_sec > 0)
        system(sprintf("sleep %d", wait_sec));
}

// Full-screen action splash with progress dots
function action_splash(title, subtitle, color) {
    color ??= C.accent;
    lcd_clear(C.bg);
    lcd_rect(0, 0, LCD_W, HDR_H, C.hdr);
    lcd_text(4, 2, title, C.white, C.hdr, 2);
    lcd_text(LCD_W - 60, 2, clock_str(), C.cyan, C.hdr, 2);

    // Centered subtitle
    lcd_text(20, 90, subtitle, color, C.bg, 3);

    // Animated dots
    lcd_rect(130, 140, 60, 8, C.bg);
    lcd_text(130, 140, ". . . .", C.gray, C.bg, 2);
    lcd_flush();
}

// Button press animation — invert colors briefly
function flash_btn(bx, by, bw, bh, label) {
    lcd_rect(bx, by, bw, bh, C.accent);
    lcd_text(bx + 8, by + 8, label ?? "", C.bg, C.accent, 2);
    lcd_flush();
}

function handle_touch(tx, ty) {
    // Dashboard → Menu on any touch
    if (st.page == "dashboard") {
        go_page("menu");
        return;
    }

    // Back button (all sub-pages except menu)
    if (st.page != "menu" && ty >= BACK_Y - 10) {
        go_page("menu");
        return;
    }

    // Menu button detection
    if (st.page == "menu") {
        for (let i = 1; i <= 6; i++) {
            let b = btn_pos(i);
            if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                // Flash button with label
                let labels = st.mpg == 1
                    ? ["WiFi", "Modem", "Traffic", "Info", "Dashboard", ">>>"]
                    : ["Reboot", "Modem Reset", "", "", "", "<<<"];
                flash_btn(b.x, b.y, b.w, b.h, labels[i - 1] ?? "");
                system("usleep 150000");

                if (st.mpg == 1) {
                    switch (i) {
                    case 1: go_page("wifi"); return;
                    case 2: go_page("lte"); return;
                    case 3: go_page("traffic"); return;
                    case 4: go_page("info"); return;
                    case 5: go_page("dashboard"); return;
                    case 6: st.mpg = 2; draw_menu(); return;
                    }
                } else {
                    switch (i) {
                    case 1:
                        // Reboot with confirmation dialog
                        lcd_clear("#200000");
                        lcd_rect(30, 60, 260, 120, "#300000");
                        lcd_rect(30, 60, 260, 1, C.red);
                        lcd_text(80, 75, "REBOOT?", C.red, "#300000", 3);
                        lcd_rect(50, 120, 100, 35, C.red);
                        lcd_text(62, 128, "YES", C.white, C.red, 2);
                        lcd_rect(170, 120, 100, 35, "#0841");
                        lcd_text(190, 128, "NO", C.white, "#0841", 2);
                        // Countdown
                        for (let sec = 5; sec > 0; sec--) {
                            lcd_rect(120, 165, 80, 16, "#200000");
                            lcd_text(120, 165, sprintf("(%ds)", sec), C.gray, "#200000", 2);
                            lcd_flush();
                            system("sleep 1");
                            let ct = read_touch();
                            if (ct) {
                                if (ct.x < 160) {
                                    // YES
                                    action_splash("System", "Rebooting...", C.red);
                                    lcd_flush();
                                    run_script("reboot.sh");
                                    return;
                                } else {
                                    // NO
                                    toast("Cancelled", C.gray, "#1082", 1);
                                    draw_menu();
                                    return;
                                }
                            }
                        }
                        toast("Cancelled (timeout)", C.gray, "#1082", 1);
                        draw_menu();
                        return;
                    case 2:
                        // LTE Reset
                        action_splash("LTE", "Resetting modem...", C.yellow);
                        run_script("lte_reset.sh");
                        // Wait for script completion (~14 sec)
                        for (let step = 0; step < 7; step++) {
                            system("sleep 2");
                            let msgs = ["Disconnecting...", "GPIO reset...", "Waiting...",
                                       "Reconnecting...", "Waiting...", "Checking...", "Done"];
                            lcd_rect(20, 140, 280, 20, C.bg);
                            lcd_text(20, 140, msgs[step], C.gray, C.bg, 2);
                            lcd_flush();
                        }
                        refresh_data();
                        draw_menu();
                        let u = st.data?.uqmi;
                        let rsrp = int(+(u?.rsrp ?? 0));
                        toast(rsrp < 0 ? sprintf("LTE OK  RSRP:%d", rsrp) : "LTE: no signal",
                              rsrp < 0 ? C.green : C.red,
                              rsrp < 0 ? "#002000" : "#200000", 2);
                        draw_menu();
                        return;
                    case 6:
                        st.mpg = 1;
                        draw_menu();
                        return;
                    }
                }
                draw_menu();
                return;
            }
        }
        return;
    }

    // WiFi page - card touch handling
    if (st.page == "wifi") {
        let ox = st.ox, oy = st.oy;
        let cx = 10 + ox;
        let cw = 300;
        
        // Card 1: 2.4GHz (radio1) (y: 28-108)
        let y1 = 28 + oy;
        if (in_rect(tx, ty, cx, y1, cw, 80)) {
            if (ucur) {
                let disabled = wifi_is_disabled("radio1", "default_radio1");
                let new_state = disabled ? "0" : "1";
                
                action_splash("WiFi 2.4GHz", new_state == "0" ? "Enabling..." : "Disabling...", C.green);
                ucur.set("wireless", "radio1", "disabled", new_state);
                ucur.set("wireless", "default_radio1", "disabled", new_state);
                ucur.commit("wireless");
                system("wifi reload");
                system("sleep 3");
                refresh_data();
                toast(new_state == "0" ? "2.4GHz ON" : "2.4GHz OFF", 
                      new_state == "0" ? C.green : C.red,
                      new_state == "0" ? "#002000" : "#200000", 2);
                draw_wifi_page();
            }
            return;
        }
        
        // Card 2: 5GHz (radio0) (y: 114-194)
        let y2 = y1 + 86;
        if (in_rect(tx, ty, cx, y2, cw, 80)) {
            if (ucur) {
                let disabled = wifi_is_disabled("radio0", "default_radio0");
                let new_state = disabled ? "0" : "1";
                
                action_splash("WiFi 5GHz", new_state == "0" ? "Enabling..." : "Disabling...", C.cyan);
                ucur.set("wireless", "radio0", "disabled", new_state);
                ucur.set("wireless", "default_radio0", "disabled", new_state);
                ucur.commit("wireless");
                system("wifi reload");
                system("sleep 3");
                refresh_data();
                toast(new_state == "0" ? "5GHz ON" : "5GHz OFF", 
                      new_state == "0" ? C.green : C.red,
                      new_state == "0" ? "#002000" : "#200000", 2);
                draw_wifi_page();
            }
            return;
        }
    }
}


// =============================================
//  SCREEN STATE MACHINE
// =============================================

function set_screen(s) {
    if (s == st.screen) return;
    st.screen = s;

    if (s == "active") {
        // Backlight on
        run_script("backlight.sh 1");
        st.page = "dashboard";
        st.mpg = 1;
        refresh_data();
        draw_dashboard();
    } else if (s == "screensaver") {
        st.saver_frame = 0;
        draw_screensaver();
    }
}


// =============================================
//  MAIN
// =============================================

function main() {
    warn(sprintf("lcd_ui: starting (ucode) ubus=%s uci=%s uloop=%s\n",
        uconn ? "OK" : "NO",
        ucur  ? "OK" : "NO",
        uloop_mod ? "OK" : "NO"));

    // Wait for lcd_drv splash logo
    system("sleep 3");

    // Stop splash: ioctl(0) via flush
    run_script("backlight.sh 1");
    system("printf '\\0' > /dev/lcd 2>/dev/null");

    // Initial data + draw
    refresh_data();
    draw_dashboard();

    // === uloop event-driven mode ===
    if (uloop_mod) {
        uloop_mod.init();

        // Data refresh + redraw (every 2s)
        let data_t;
        data_t = uloop_mod.timer(T.data * 1000, function() {
            refresh_data();
            if (st.screen == "active")
                draw_current();
            else if (st.screen == "screensaver")
                draw_screensaver();
            data_t.set(T.data * 1000);
        });

        // Touch polling (every 100ms)
        let touch_t;
        touch_t = uloop_mod.timer(100, function() {
            let t = read_touch();
            if (t) {
                st.ltch = time();
                if (st.screen != "active")
                    set_screen("active");
                else
                    handle_touch(t.x, t.y);
            }
            // Poll slower when screen is off
            touch_t.set(st.screen == "off" ? 500 : 100);
        });

        // Idle check (every 1s)
        let idle_t;
        idle_t = uloop_mod.timer(1000, function() {
            let idle = time() - st.ltch;
            if (st.screen == "active" && idle >= saver_timeout())
                set_screen("screensaver");
            idle_t.set(1000);
        });

        // Anti-burn-in shift (every 30s)
        let burnin_t;
        burnin_t = uloop_mod.timer(T.burnin * 1000, function() {
            st.ox = (st.frame % 5) - 2;
            st.oy = (int(st.frame / 3) % 5) - 2;
            st.frame++;
            burnin_t.set(T.burnin * 1000);
        });

        warn("lcd_ui: uloop running\n");
        uloop_mod.run();

    // === Fallback: poll loop ===
    } else {
        warn("lcd_ui: fallback poll loop (no uloop)\n");
        let last_data = 0;
        let last_burnin = time();

        while (true) {
            let now = time();

            // Data refresh
            if (now - last_data >= T.data) {
                refresh_data();
                last_data = now;
            }

            // Touch
            let t = read_touch();
            if (t) {
                st.ltch = now;
                if (st.screen != "active")
                    set_screen("active");
                else
                    handle_touch(t.x, t.y);
            }

            // Idle
            let idle = now - st.ltch;
            if (st.screen == "active" && idle >= saver_timeout())
                set_screen("screensaver");

            // Burn-in
            if (now - last_burnin >= T.burnin) {
                st.ox = (st.frame % 5) - 2;
                st.oy = (int(st.frame / 3) % 5) - 2;
                st.frame++;
                last_burnin = now;
            }

            // Redraw
            if (st.screen == "active" && now - st.ldraw >= T.data) {
                draw_current();
                st.ldraw = now;
            } else if (st.screen == "screensaver") {
                draw_screensaver();
            }

            // Sleep (usleep via system call)
            let us = st.screen == "off" ? 500000 : 100000;
            system(sprintf("usleep %d", us));
        }
    }
}

// Single run — procd handles respawn on crash
main();
