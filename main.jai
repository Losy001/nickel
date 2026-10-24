// Nickel: a native, DPI-aware music player with a custom title bar. Windows only.
// Build: jai build.jai     Run: nickel.exe [files or folders...]
//
// One self-contained exe: Direct3D 11 (shaders precompiled at build time), FreeType and
// stb_vorbis are linked in statically; mp3/flac/aac/... are decoded by the OS's own
// Media Foundation codecs, so nothing has to be shipped next to the executable.

#import "Basic";
#import "Math";
#import "String";
#import "File";
#import "File_Utilities";
#import "Sort";
#import "Random";
#import "Hash_Table";
#import "Windows";
#import "Windows_Utf8";
#load "gfx.jai";
#load "audio.jai";
#load "library.jai";
#load "art.jai";
#load "shell.jai";

HIDE_CONSOLE :: true;

#run {
    #if HIDE_CONSOLE {
        WR :: #import "Windows_Resources";
        WR.disable_runtime_console();
    }
}

//
// Win32 bindings (own names so they never collide with the Windows module).
//
lib_user32   :: #library,system "user32";
lib_kernel32 :: #library,system "kernel32";
lib_shell32  :: #library,system "shell32";
lib_comdlg32 :: #library,system "comdlg32";
lib_dwmapi   :: #library,system "dwmapi";

TRACKMOUSEEVENT_ :: struct { cbSize: u32; dwFlags: u32; hwndTrack: HWND; dwHoverTime: u32; }
NCCALCSIZE_PARAMS_ :: struct { rgrc: [3] RECT; lppos: *void; }
MINMAXINFO_ :: struct { ptReserved, ptMaxSize, ptMaxPosition, ptMinTrackSize, ptMaxTrackSize: POINT; }

w_RegisterClassExW :: (wc: *WNDCLASSEXW) -> u16 #foreign lib_user32 "RegisterClassExW";
w_CreateWindowExW  :: (ex: u32, cls: *u16, name: *u16, style: u32, x: s32, y: s32, w: s32, h: s32, parent: HWND, menu: HMENU, inst: HINSTANCE, param: *void) -> HWND #foreign lib_user32 "CreateWindowExW";
w_DefWindowProcW   :: (h: HWND, m: u32, wp: WPARAM, lp: LPARAM) -> s64 #foreign lib_user32 "DefWindowProcW";
w_PeekMessageW     :: (msg: *MSG, h: HWND, min_msg: u32, max_msg: u32, flags: u32) -> s32 #foreign lib_user32 "PeekMessageW";
w_TranslateMessage :: (msg: *MSG) -> s32 #foreign lib_user32 "TranslateMessage";
w_DispatchMessageW :: (msg: *MSG) -> s64 #foreign lib_user32 "DispatchMessageW";
w_PostQuitMessage  :: (code: s32) #foreign lib_user32 "PostQuitMessage";
w_PostMessageW     :: (h: HWND, m: u32, wp: WPARAM, lp: LPARAM) -> s32 #foreign lib_user32 "PostMessageW";
w_DestroyWindow    :: (h: HWND) -> s32 #foreign lib_user32 "DestroyWindow";
w_ShowWindow       :: (h: HWND, cmd: s32) -> s32 #foreign lib_user32 "ShowWindow";
w_SetWindowPos     :: (h: HWND, after: HWND, x: s32, y: s32, w: s32, hh: s32, flags: u32) -> s32 #foreign lib_user32 "SetWindowPos";
w_GetClientRect    :: (h: HWND, r: *RECT) -> s32 #foreign lib_user32 "GetClientRect";
w_GetWindowRect    :: (h: HWND, r: *RECT) -> s32 #foreign lib_user32 "GetWindowRect";
w_IsZoomed         :: (h: HWND) -> s32 #foreign lib_user32 "IsZoomed";
w_IsIconic         :: (h: HWND) -> s32 #foreign lib_user32 "IsIconic";
w_SetWindowTextW   :: (h: HWND, s: *u16) -> s32 #foreign lib_user32 "SetWindowTextW";
w_SetCapture       :: (h: HWND) -> HWND #foreign lib_user32 "SetCapture";
w_ReleaseCapture   :: () -> s32 #foreign lib_user32 "ReleaseCapture";
w_SetTimer         :: (h: HWND, id: u64, ms: u32, proc: *void) -> u64 #foreign lib_user32 "SetTimer";
w_KillTimer        :: (h: HWND, id: u64) -> s32 #foreign lib_user32 "KillTimer";
w_LoadCursorW      :: (inst: HINSTANCE, name: *void) -> HCURSOR #foreign lib_user32 "LoadCursorW";
w_SetCursor        :: (c: HCURSOR) -> HCURSOR #foreign lib_user32 "SetCursor";
w_TrackMouseEvent  :: (t: *TRACKMOUSEEVENT_) -> s32 #foreign lib_user32 "TrackMouseEvent";
w_GetKeyState      :: (vk: s32) -> s16 #foreign lib_user32 "GetKeyState";
w_MonitorFromWindow :: (h: HWND, flags: u32) -> HMONITOR #foreign lib_user32 "MonitorFromWindow";
w_GetMonitorInfoW  :: (m: HMONITOR, mi: *MONITORINFO) -> s32 #foreign lib_user32 "GetMonitorInfoW";
w_GetDpiForWindow  :: (h: HWND) -> u32 #foreign lib_user32 "GetDpiForWindow";
w_GetDpiForSystem  :: () -> u32 #foreign lib_user32 "GetDpiForSystem";
w_SetProcessDpiAwarenessContext :: (c: *void) -> s32 #foreign lib_user32 "SetProcessDpiAwarenessContext";
w_MsgWaitForMultipleObjects :: (n: u32, handles: *void, wait_all: s32, ms: u32, mask: u32) -> u32 #foreign lib_user32 "MsgWaitForMultipleObjects";
w_ValidateRect     :: (h: HWND, r: *RECT) -> s32 #foreign lib_user32 "ValidateRect";
w_DragQueryFileW   :: (drop: HDROP, i: u32, buf: *u16, cch: u32) -> u32 #foreign lib_shell32 "DragQueryFileW";
w_DragFinish       :: (drop: HDROP) #foreign lib_shell32 "DragFinish";
w_GetOpenFileNameW :: (o: *OPENFILENAMEW) -> s32 #foreign lib_comdlg32 "GetOpenFileNameW";
w_GetModuleHandleW :: (n: *u16) -> HINSTANCE #foreign lib_kernel32 "GetModuleHandleW";
w_GetFileAttributesW :: (n: *u16) -> u32 #foreign lib_kernel32 "GetFileAttributesW";
w_RegisterHotKey   :: (h: HWND, id: s32, mods: u32, vk: u32) -> s32 #foreign lib_user32 "RegisterHotKey";
w_SendMessageW     :: (h: HWND, m: u32, wp: WPARAM, lp: LPARAM) -> s64 #foreign lib_user32 "SendMessageW";
w_ExtractIconW     :: (inst: HINSTANCE, file: *u16, index: u32) -> HICON #foreign lib_shell32 "ExtractIconW";
w_GetModuleFileNameW :: (m: HINSTANCE, buf: *u16, size: u32) -> u32 #foreign lib_kernel32 "GetModuleFileNameW";
w_DwmSetWindowAttribute :: (h: HWND, attr: u32, value: *void, size: u32) -> s32 #foreign lib_dwmapi "DwmSetWindowAttribute";

K_WM_DESTROY :: 0x0002; K_WM_SIZE :: 0x0005; K_WM_SETFOCUS :: 0x0007;
K_WM_PAINT :: 0x000F; K_WM_CLOSE :: 0x0010; K_WM_QUIT :: 0x0012; K_WM_ERASEBKGND :: 0x0014;
K_WM_SETCURSOR :: 0x0020; K_WM_GETMINMAXINFO :: 0x0024;
K_WM_NCCALCSIZE :: 0x0083; K_WM_NCHITTEST :: 0x0084; K_WM_NCACTIVATE :: 0x0086;
K_WM_NCMOUSEMOVE :: 0x00A0; K_WM_NCLBUTTONDOWN :: 0x00A1; K_WM_NCLBUTTONUP :: 0x00A2;
K_WM_KEYDOWN :: 0x0100; K_WM_CHAR :: 0x0102; K_WM_SYSCOMMAND :: 0x0112; K_WM_TIMER :: 0x0113; K_WM_HOTKEY :: 0x0312;
K_WM_MOUSEMOVE :: 0x0200; K_WM_LBUTTONDOWN :: 0x0201; K_WM_LBUTTONUP :: 0x0202; K_WM_MOUSEWHEEL :: 0x020A;
K_WM_CAPTURECHANGED :: 0x0215; K_WM_ENTERSIZEMOVE :: 0x0231; K_WM_EXITSIZEMOVE :: 0x0232;
K_WM_DROPFILES :: 0x0233; K_WM_NCMOUSELEAVE :: 0x02A2; K_WM_MOUSELEAVE :: 0x02A3;
K_WM_DPICHANGED :: 0x02E0; K_WM_APPCOMMAND :: 0x0319; K_WM_COPYDATA :: 0x004A;

HT_CLIENT :: 1; HT_CAPTION :: 2; HT_MINBUTTON :: 8; HT_MAXBUTTON :: 9;
HT_LEFT :: 10; HT_RIGHT :: 11; HT_TOP :: 12; HT_TOPLEFT :: 13; HT_TOPRIGHT :: 14;
HT_BOTTOM :: 15; HT_BOTTOMLEFT :: 16; HT_BOTTOMRIGHT :: 17; HT_CLOSE :: 20;

// WM_APPCOMMAND media commands. The global media-key hotkeys use the same numbers as their ids.
APPCOMMAND_NEXT :: 11; APPCOMMAND_PREV :: 12; APPCOMMAND_STOP :: 13; APPCOMMAND_PLAY_PAUSE :: 14;
APPCOMMAND_PLAY :: 46; APPCOMMAND_PAUSE :: 47;

//
// App state
//
APP_NAME   :: "Nickel";
MIN_W      :: 480;   // logical pixels
MIN_H      :: 400;
TITLEBAR_H :: 40.0;
CAPTION_BTN_W :: 46.0;

main_hwnd: HWND;
dpi_scale := 1.0;           // DPI / 96
win_w: s32;                 // client size in physical pixels
win_h: s32;
gfx_ready := false;
in_frame  := false;
quit      := false;
dirty     := true;
animating := false;
app_context: #Context;
app_context_ready := false;

// Input (physical pixels), written by the window proc, consumed once per frame.
mx: float = -10000;
my: float = -10000;
mouse_down     := false;
mouse_pressed  := false;
mouse_released := false;
mouse_tracked  := false;
nc_tracked     := false;
nc_hot: s32;                // caption button under the cursor (HT_* code or 0)
nc_pressed: s32;
wheel_accum: float;
key_events: [..] u32;
char_events: [..] u32;
app_commands: [..] s32;
dropped: [..] string;
shell_opened: [..] string;  // paths from the command line or from another instance; played right away
want_open_dialog := false;
want_rescan := false;

cursor_arrow_h: HCURSOR;
cursor_hand_h:  HCURSOR;
cursor_we_h:    HCURSOR;

font_dir  := "C:/Windows/Fonts";
font_file := "segoeui.ttf";

//
// Library and playback state
//
library: [..] Source;       // scanned from the Music folder
opened: Source;             // files/folders the user opened or dropped
view_src := 0;              // source shown in the playlist
play_src := -1;             // source the current track belongs to
current  := -1;             // index into the playing source
play_serial: s64;
end_handled := true;
last_scan_time: float64;
status_text: string;

volume := 0.8;
muted := false;
shuffle := false;
repeat_all := false;

source_count :: () -> int {
    return library.count + ifx opened.tracks.count > 0 then 1 else 0;
}

get_source :: (i: int) -> *Source {
    if i < 0 return null;
    if i < library.count return *library[i];
    if i == library.count && opened.tracks.count > 0 return *opened;
    return null;
}

current_track :: () -> *Track {
    s := get_source(play_src);
    if !s || current < 0 || current >= s.tracks.count return null;
    return *s.tracks[current];
}

//
// Animation
//
anim_tab: Table(int, float);
frame_dt: float = 1.0 / 60.0;
anim_time: float;

// Eases a value toward `target`; the first call snaps to it. Keeps the app redrawing while moving.
animate :: (id: int, target: float, rate: float = 16) -> float {
    p := table_find_pointer(*anim_tab, id);
    if !p {
        table_add(*anim_tab, id, target);
        return target;
    }
    v := p.*;
    d := target - v;
    if abs(d) < 0.002 { p.* = target; return target; }
    v += d * (1 - exp(-rate * frame_dt));
    p.* = v;
    animating = true;
    return v;
}

anim_set :: (id: int, value: float) {
    p := table_find_pointer(*anim_tab, id);
    if p p.* = value; else table_add(*anim_tab, id, value);
}

// Key ranges for anim_tab, so widget ids can be reused for different animations.
ANIM_HOVER :: 100000;
ANIM_PRESS :: 300000;
ANIM_MISC  :: 400000;
ANIM_ROW   :: 500000;

// ANIM_MISC keys.
ID_TITLE_FADE :: 1; ID_SEEK_POS :: 2; ID_VOL_POS :: 3; ID_SCROLL_THUMB :: 4; ID_COVER_FADE :: 5;

//
// Colors: flat. One accent, everything else grey, 1px outlines instead of gradients/shadows.
//
lerp4 :: (a: Vector4, b: Vector4, t: float) -> Vector4 {
    return .{a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t};
}

with_alpha :: (c: Vector4, a: float) -> Vector4 { return .{c.x, c.y, c.z, a}; }

COL_WARN   :: Vector4.{1.0, 0.62, 0.45, 1};
COL_CLOSE  :: Vector4.{0.769, 0.169, 0.110, 1};
WHITE      :: Vector4.{1, 1, 1, 1};

// Color schemes. One accent, everything else grey; switch with the palette button.
Theme :: struct {
    name: string;
    bg, panel, hover, border, track, text, dim, accent: Vector4;
}

THEMES :: Theme.[
    .{"Ember",  .{0.071, 0.067, 0.063, 1}, .{0.102, 0.098, 0.090, 1}, .{0.149, 0.141, 0.129, 1}, .{0.188, 0.176, 0.161, 1}, .{0.255, 0.239, 0.216, 1}, .{0.949, 0.933, 0.906, 1}, .{0.635, 0.600, 0.557, 1}, .{0.961, 0.647, 0.141, 1}},
    .{"Ocean",  .{0.051, 0.067, 0.090, 1}, .{0.082, 0.106, 0.137, 1}, .{0.118, 0.149, 0.192, 1}, .{0.165, 0.204, 0.255, 1}, .{0.227, 0.275, 0.337, 1}, .{0.902, 0.929, 0.953, 1}, .{0.545, 0.596, 0.659, 1}, .{0.345, 0.651, 1.000, 1}},
    .{"Orchid", .{0.063, 0.055, 0.078, 1}, .{0.094, 0.082, 0.122, 1}, .{0.133, 0.118, 0.169, 1}, .{0.176, 0.157, 0.220, 1}, .{0.251, 0.227, 0.314, 1}, .{0.925, 0.914, 0.949, 1}, .{0.604, 0.576, 0.667, 1}, .{0.706, 0.549, 1.000, 1}},
    .{"Forest", .{0.055, 0.058, 0.064, 1}, .{0.082, 0.086, 0.094, 1}, .{0.122, 0.129, 0.141, 1}, .{0.176, 0.188, 0.208, 1}, .{0.235, 0.247, 0.271, 1}, .{0.920, 0.930, 0.940, 1}, .{0.550, 0.580, 0.630, 1}, .{0.118, 0.843, 0.376, 1}},
];

theme_index := 0;

COL_BG:     Vector4;
COL_PANEL:  Vector4;
COL_HOVER:  Vector4;
COL_BORDER: Vector4;
COL_TRACK:  Vector4;
COL_TEXT:   Vector4;
COL_DIM:    Vector4;
COL_ACCENT: Vector4;

apply_theme :: () {
    t := THEMES[clamp(theme_index, 0, THEMES.count - 1)];
    COL_BG = t.bg; COL_PANEL = t.panel; COL_HOVER = t.hover; COL_BORDER = t.border;
    COL_TRACK = t.track; COL_TEXT = t.text; COL_DIM = t.dim; COL_ACCENT = t.accent;
    dirty = true;
}

// Corner radius shared by every control. Windows 11 rounds top-level windows by 8px (at 100% DPI),
// so everything inside uses the same value.
radius :: () -> float { return 8 * dpi_scale; }

line_w :: () -> float { return max(1.0, dpi_scale); }

//
// Drawing helpers (physical pixels, y down). Everything goes through tri().
//
ui_alpha: float = 1;

tri :: (a: Vector2, b: Vector2, c: Vector2, col: Vector4) {
    k := col;
    k.w *= ui_alpha;
    gfx_tri(a.x, a.y, b.x, b.y, c.x, c.y, k);
}

quad4 :: (a: Vector2, b: Vector2, c: Vector2, d: Vector2, col: Vector4) {
    tri(a, b, c, col);
    tri(a, c, d, col);
}

fill :: (x0: float, y0: float, x1: float, y1: float, c: Vector4) {
    quad4(.{x0, y0}, .{x1, y0}, .{x1, y1}, .{x0, y1}, c);
}

line :: (x0: float, y0: float, x1: float, y1: float, thick: float, c: Vector4) {
    dx := x1 - x0; dy := y1 - y0;
    len := sqrt(dx*dx + dy*dy);
    if len < 0.001 return;
    nx := -dy / len * thick * 0.5;
    ny :=  dx / len * thick * 0.5;
    quad4(.{x0+nx, y0+ny}, .{x1+nx, y1+ny}, .{x1-nx, y1-ny}, .{x0-nx, y0-ny}, c);
}

fan :: (cx: float, cy: float, r: float, a0: float, a1: float, c: Vector4) {
    segs := max(6, cast(int) (r * 0.35 * abs(a1 - a0)));
    for 0..segs-1 {
        t0 := a0 + (a1 - a0) * cast(float) it / segs;
        t1 := a0 + (a1 - a0) * cast(float) (it + 1) / segs;
        tri(.{cx, cy}, .{cx + cos(t0) * r, cy + sin(t0) * r}, .{cx + cos(t1) * r, cy + sin(t1) * r}, c);
    }
}

disc :: (cx: float, cy: float, r: float, c: Vector4) {
    fan(cx, cy, r, 0, TAU, c);
}

arc :: (cx: float, cy: float, r: float, thick: float, a0: float, a1: float, c: Vector4) {
    segs := max(8, cast(int) (r * 0.35 * abs(a1 - a0)));
    ri := r - thick;
    for 0..segs-1 {
        t0 := a0 + (a1 - a0) * cast(float) it / segs;
        t1 := a0 + (a1 - a0) * cast(float) (it + 1) / segs;
        quad4(.{cx + cos(t0) * r,  cy + sin(t0) * r},  .{cx + cos(t1) * r,  cy + sin(t1) * r},
              .{cx + cos(t1) * ri, cy + sin(t1) * ri}, .{cx + cos(t0) * ri, cy + sin(t0) * ri}, c);
    }
}

rounded :: (x0: float, y0: float, x1: float, y1: float, r: float, c: Vector4) {
    r = max(0.0, min(r, min((x1 - x0) * 0.5, (y1 - y0) * 0.5)));
    fill(x0 + r, y0, x1 - r, y1, c);
    fill(x0, y0 + r, x0 + r, y1 - r, c);
    fill(x1 - r, y0 + r, x1, y1 - r, c);
    if r > 0.5 {
        fan(x0 + r, y0 + r, r, PI,       PI * 1.5, c);
        fan(x1 - r, y0 + r, r, PI * 1.5, TAU,      c);
        fan(x1 - r, y1 - r, r, 0,        PI * 0.5, c);
        fan(x0 + r, y1 - r, r, PI * 0.5, PI,       c);
    }
}

// Rounded rectangle outline, drawn inside the given rectangle.
outline :: (x0: float, y0: float, x1: float, y1: float, r: float, t: float, c: Vector4) {
    r = max(t, min(r, min((x1 - x0) * 0.5, (y1 - y0) * 0.5)));
    fill(x0 + r, y0, x1 - r, y0 + t, c);
    fill(x0 + r, y1 - t, x1 - r, y1, c);
    fill(x0, y0 + r, x0 + t, y1 - r, c);
    fill(x1 - t, y0 + r, x1, y1 - r, c);
    arc(x0 + r, y0 + r, r, t, PI,       PI * 1.5, c);
    arc(x1 - r, y0 + r, r, t, PI * 1.5, TAU,      c);
    arc(x1 - r, y1 - r, r, t, 0,        PI * 0.5, c);
    arc(x0 + r, y1 - r, r, t, PI * 0.5, PI,       c);
}

// A flat panel: fill plus a 1px outline.
panel :: (x0: float, y0: float, x1: float, y1: float) {
    rounded(x0, y0, x1, y1, radius(), COL_PANEL);
    outline(x0, y0, x1, y1, radius(), line_w(), COL_BORDER);
}

font_px :: (size: float) -> s32 {
    return cast(s32) max(6, cast(int) (size * dpi_scale + 0.5));
}

text_width :: (s: string, size: float) -> float {
    return gfx_text_width(font_px(size), s);
}

// Draws text vertically centered on cy. Returns the width.
text :: (s: string, x: float, cy: float, size: float, c: Vector4) -> float {
    px := font_px(size);
    col := c;
    col.w *= ui_alpha;
    cap := cast(float) gfx_glyph(px, #char "H").top;
    xh  := gfx_ascender(px);
    return gfx_text(px, x, cy + (cap + xh) * 0.25, s, col);
}

text_centered :: (s: string, cx: float, cy: float, size: float, c: Vector4) {
    w := text_width(s, size);
    text(s, cx - w * 0.5, cy, size, c);
}

fit_text :: (s: string, max_w: float, size: float) -> string {
    w := text_width(s, size);
    if w <= max_w return s;
    t := s;
    t.count = max(0, cast(int) (cast(float) s.count * max_w / w) - 1);
    while true {
        while t.count > 0 && (t.data[t.count] & 0xC0) == 0x80  t.count -= 1;
        cand := tprint("%…", t);
        if t.count == 0 || text_width(cand, size) <= max_w return cand;
        t.count -= 1;
    }
    return s;
}

format_time :: (seconds: float64) -> string {
    t := cast(int) max(seconds, 0);
    if t >= 3600 return tprint("%:%:%", t / 3600, formatInt((t / 60) % 60, minimum_digits = 2), formatInt(t % 60, minimum_digits = 2));
    return tprint("%:%", t / 60, formatInt(t % 60, minimum_digits = 2));
}

//
// Icons: drawn from lines and triangles on a 16x16 grid so they scale with DPI.
//
Icon :: enum { PLAY; PAUSE; PREV; NEXT; SHUFFLE; REPEAT; VOLUME; MUTE; FOLDER; REFRESH; TRASH; PANEL; NOTE; STOP; SEARCH; PLUS; CLOSE; PALETTE; FOLDER_PLUS; DEFAULT_APP; }

ic_cx: float; ic_cy: float; ic_k: float; ic_t: float;
ic_col: Vector4;

ic_begin :: (cx: float, cy: float, size: float, c: Vector4) {
    ic_cx = cx; ic_cy = cy; ic_k = size / 16.0; ic_col = c;
    ic_t = max(1.0, 1.5 * ic_k);
}

ip :: (x: float, y: float) -> Vector2 {
    return .{ic_cx + (x - 8) * ic_k, ic_cy + (y - 8) * ic_k};
}

// Line with round caps.
il :: (x0: float, y0: float, x1: float, y1: float) {
    a := ip(x0, y0); b := ip(x1, y1);
    line(a.x, a.y, b.x, b.y, ic_t, ic_col);
    disc(a.x, a.y, ic_t * 0.5, ic_col);
    disc(b.x, b.y, ic_t * 0.5, ic_col);
}

itri :: (x0: float, y0: float, x1: float, y1: float, x2: float, y2: float) {
    tri(ip(x0, y0), ip(x1, y1), ip(x2, y2), ic_col);
}

draw_icon :: (icon: Icon, cx: float, cy: float, size: float, c: Vector4) {
    ic_begin(cx, cy, size, c);
    if icon == {
    case .PLAY;
        itri(4, 2, 4, 14, 14, 8);
    case .PAUSE;
        a := ip(3.5, 2); b := ip(6.5, 14);
        rounded(a.x, a.y, b.x, b.y, ic_k, c);
        a = ip(9.5, 2); b = ip(12.5, 14);
        rounded(a.x, a.y, b.x, b.y, ic_k, c);
    case .PREV;
        a := ip(2.5, 2.5); b := ip(4.5, 13.5);
        rounded(a.x, a.y, b.x, b.y, ic_k * 0.6, c);
        itri(14, 2.5, 14, 13.5, 6, 8);
    case .NEXT;
        a := ip(11.5, 2.5); b := ip(13.5, 13.5);
        rounded(a.x, a.y, b.x, b.y, ic_k * 0.6, c);
        itri(2, 2.5, 2, 13.5, 10, 8);
    case .SHUFFLE;
        il(1, 11.5, 4.5, 11.5); il(4.5, 11.5, 9.5, 4.5); il(9.5, 4.5, 12, 4.5);
        itri(11.5, 2, 11.5, 7, 15, 4.5);
        il(1, 4.5, 4.5, 4.5);   il(4.5, 4.5, 9.5, 11.5); il(9.5, 11.5, 12, 11.5);
        itri(11.5, 9, 11.5, 14, 15, 11.5);
    case .REPEAT;
        il(2.5, 8, 2.5, 5.5); il(2.5, 5.5, 11.5, 5.5);
        itri(11, 3, 11, 8, 14.5, 5.5);
        il(13.5, 8, 13.5, 10.5); il(13.5, 10.5, 4.5, 10.5);
        itri(5, 8, 5, 13, 1.5, 10.5);
    case .VOLUME; #through;
    case .MUTE;
        a := ip(1.5, 6); b := ip(4.5, 10);
        fill(a.x, a.y, b.x, b.y, c);
        itri(4.5, 6, 8.5, 2.5, 8.5, 13.5);
        itri(4.5, 6, 8.5, 13.5, 4.5, 10);
        if icon == .MUTE {
            il(10.5, 5.5, 14.5, 10.5); il(10.5, 10.5, 14.5, 5.5);
        } else {
            m := ip(8.5, 8);
            arc(m.x, m.y, 5.0 * ic_k, ic_t, -0.85, 0.85, c);
            arc(m.x, m.y, 8.0 * ic_k, ic_t, -0.85, 0.85, c);
        }
    case .FOLDER;
        il(1.5, 3.5, 6, 3.5); il(6, 3.5, 7.8, 5.5); il(7.8, 5.5, 14.5, 5.5);
        il(14.5, 5.5, 14.5, 13); il(14.5, 13, 1.5, 13); il(1.5, 13, 1.5, 3.5);
    case .REFRESH;
        m := ip(8, 8);
        a1: float = 5.3;
        arc(m.x, m.y, 5.5 * ic_k, ic_t, 0.7, a1, c);
        ex := m.x + cos(a1) * 5.5 * ic_k;
        ey := m.y + sin(a1) * 5.5 * ic_k;
        tx := -sin(a1); ty := cos(a1);      // direction of travel
        rx := cos(a1);  ry := sin(a1);      // radial
        tri(.{ex + tx * 4 * ic_k, ey + ty * 4 * ic_k},
            .{ex + rx * 3 * ic_k, ey + ry * 3 * ic_k},
            .{ex - rx * 3 * ic_k, ey - ry * 3 * ic_k}, c);
    case .TRASH;
        il(2.5, 4, 13.5, 4); il(6, 4, 6, 2); il(6, 2, 10, 2); il(10, 2, 10, 4);
        il(3.8, 4.5, 4.8, 14); il(4.8, 14, 11.2, 14); il(11.2, 14, 12.2, 4.5);
        il(7, 6.5, 7, 12); il(9, 6.5, 9, 12);
    case .PANEL;
        a := ip(1.2, 2.2); b := ip(14.8, 13.8);
        outline(a.x, a.y, b.x, b.y, ic_k * 2, ic_t, c);
        il(10, 3, 10, 13);
    case .STOP;
        a := ip(3, 3); b := ip(13, 13);
        rounded(a.x, a.y, b.x, b.y, ic_k * 1.5, c);
    case .SEARCH;
        m := ip(7, 7);
        arc(m.x, m.y, 4.8 * ic_k, ic_t, 0, TAU, c);
        il(10.6, 10.6, 14, 14);
    case .PLUS;
        il(8, 2.5, 8, 13.5); il(2.5, 8, 13.5, 8);
    case .CLOSE;
        il(3.5, 3.5, 12.5, 12.5); il(12.5, 3.5, 3.5, 12.5);
    case .PALETTE;
        m := ip(8, 8);
        arc(m.x, m.y, 6.6 * ic_k, ic_t, 0, TAU, c);
        d := ip(5.2, 6.4); disc(d.x, d.y, 1.1 * ic_k, c);
        d = ip(8.6, 4.6);  disc(d.x, d.y, 1.1 * ic_k, c);
        d = ip(11.0, 7.4); disc(d.x, d.y, 1.1 * ic_k, c);
        d = ip(6.0, 10.4); disc(d.x, d.y, 1.1 * ic_k, c);
    case .FOLDER_PLUS;
        il(1.5, 3.5, 6, 3.5); il(6, 3.5, 7.8, 5.5); il(7.8, 5.5, 14.5, 5.5);
        il(14.5, 5.5, 14.5, 13); il(14.5, 13, 1.5, 13); il(1.5, 13, 1.5, 3.5);
        il(8, 7.5, 8, 11.5); il(6, 9.5, 10, 9.5);
    case .DEFAULT_APP;   // check mark in a circle
        m := ip(8, 8);
        arc(m.x, m.y, 6.6 * ic_k, ic_t, 0, TAU, c);
        il(5.2, 8.2, 7.2, 10.2); il(7.2, 10.2, 10.9, 6.2);
    case .NOTE;
        n := ip(5.2, 11.8);
        disc(n.x, n.y, 2.7 * ic_k, c);
        il(7.9, 11.8, 7.9, 2.5); il(7.9, 2.5, 13, 4.5);
    }
}

//
// Widgets
//
active_id: int;
cursor_hand := false;
cursor_size := false;

tip_text: string;
tip_x: float;
tip_y: float;

// Returns clicked, hovered, held.
button :: (id: int, x0: float, y0: float, x1: float, y1: float) -> bool, bool, bool {
    hovered := in_box(x0, y0, x1, y1) && (active_id == 0 || active_id == id);
    if hovered cursor_hand = true;
    if hovered && mouse_pressed && active_id == 0  active_id = id;
    held := active_id == id;
    clicked := false;
    if held && mouse_released {
        clicked = hovered;
        active_id = 0;
    }
    return clicked, hovered, held;
}

in_box :: (x0: float, y0: float, x1: float, y1: float) -> bool {
    return mx >= x0 && mx < x1 && my >= y0 && my < y1;
}

// Seconds the pointer has rested on a widget; used to delay tooltips.
hover_time :: (id: int, hovered: bool) -> float {
    key := ANIM_PRESS + 5000 + id;
    p := table_find_pointer(*anim_tab, key);
    if !hovered {
        if p p.* = 0;
        return 0;
    }
    if !p { table_add(*anim_tab, key, 0); p = table_find_pointer(*anim_tab, key); }
    p.* += frame_dt;
    if p.* < 0.7 animating = true;
    return p.*;
}

// A flat icon button. `box` is the hit area, `size` the icon. Toggles show an accent color and a dot.
icon_btn :: (id: int, icon: Icon, cx: float, cy: float, box: float, size: float, active: bool, tip: string, with_bg := false, dot := false) -> bool {
    S := dpi_scale;
    clicked, hovered, held := button(id, cx - box * 0.5, cy - box * 0.5, cx + box * 0.5, cy + box * 0.5);
    hv := animate(ANIM_HOVER + id, ifx hovered then 1.0 else 0.0, 20);
    if with_bg && hv > 0.01 {
        rounded(cx - box * 0.5, cy - box * 0.5, cx + box * 0.5, cy + box * 0.5, radius(), with_alpha(COL_HOVER, hv));
    }
    col := ifx active then COL_ACCENT else lerp4(COL_DIM, COL_TEXT, hv);
    if held col = lerp4(col, COL_DIM, 0.4);
    draw_icon(icon, cx, cy, size, col);
    if dot && active disc(cx, cy + box * 0.5 + 1 * S, 1.6 * S, COL_ACCENT);

    if hover_time(id, hovered) > 0.5 && tip.count {
        tip_text = tip; tip_x = cx; tip_y = cy - box * 0.5;
    }
    return clicked;
}

// Horizontal slider; returns value, dragging, released.
slider :: (id: int, x0: float, y0: float, x1: float, y1: float, value: float) -> float, bool, bool {
    hovered := in_box(x0 - 6 * dpi_scale, y0, x1 + 6 * dpi_scale, y1) && (active_id == 0 || active_id == id);
    if hovered cursor_hand = true;
    if hovered && mouse_pressed && active_id == 0  active_id = id;
    dragging := active_id == id;
    released := false;
    if dragging {
        value = clamp((mx - x0) / (x1 - x0), 0, 1);
        if mouse_released { released = true; active_id = 0; }
    }
    return value, dragging, released;
}

// Draws a seek/volume style bar: flat track, flat fill, knob on hover. Fill turns accent on hover.
draw_bar :: (id: int, x0: float, x1: float, cy: float, frac: float, hot: bool) {
    S := dpi_scale;
    hv := animate(ANIM_HOVER + id, ifx hot then 1.0 else 0.0, 18);
    th := 4 * S;
    rounded(x0, cy - th * 0.5, x1, cy + th * 0.5, th * 0.5, COL_TRACK);
    px := x0 + (x1 - x0) * clamp(frac, 0, 1);
    if px > x0 + 1 {
        rounded(x0, cy - th * 0.5, max(px, x0 + th), cy + th * 0.5, th * 0.5, lerp4(COL_TEXT, COL_ACCENT, hv));
    }
    if hv > 0.01 disc(px, cy, 6 * S * hv, WHITE);
}

// A draggable divider between panes. `value` is in logical pixels; `sign` is +1 if dragging right
// makes the pane bigger, -1 if it makes it smaller. Returns true when the drag ends.
split_start_mx: float;
split_start_val: float;

splitter :: (id: int, x: float, y0: float, y1: float, value: *float, sign: float, lo: float, hi: float) -> bool {
    S := dpi_scale;
    hw := 5 * S;
    hovered := in_box(x - hw, y0, x + hw, y1) && (active_id == 0 || active_id == id);
    if hovered cursor_size = true;
    if hovered && mouse_pressed && active_id == 0 {
        active_id = id;
        split_start_mx = mx;
        split_start_val = value.*;
    }
    done := false;
    drag := active_id == id;
    if drag {
        cursor_size = true;
        before := value.*;
        value.* = clamp(split_start_val + sign * (mx - split_start_mx) / S, lo, hi);
        if value.* != before dirty = true;   // the panes were already laid out this frame; draw once more
        if mouse_released { active_id = 0; done = true; dirty = true; }
    }
    hv := animate(ANIM_HOVER + id, ifx hovered || drag then 1.0 else 0.0, 20);
    if hv > 0.01 fill(x - line_w(), y0, x + line_w(), y1, with_alpha(COL_ACCENT, hv));
    return done;
}

draw_tooltip :: () {
    if !tip_text.count return;
    S := dpi_scale;
    w := text_width(tip_text, 12) + 18 * S;
    h := 26 * S;
    x := clamp(tip_x - w * 0.5, 6 * S, win_w - w - 6 * S);
    y := tip_y - h - 6 * S;
    if y < 4 * S y = tip_y + 40 * S;
    rounded(x, y, x + w, y + h, radius(), COL_BG);
    outline(x, y, x + w, y + h, radius(), line_w(), COL_BORDER);
    text_centered(tip_text, x + w * 0.5, y + h * 0.5, 12, COL_TEXT);
    tip_text = "";
}

//
// Playback control
//
apply_volume :: () {
    audio_gain = ifx muted then 0.0 else volume * volume;
}

play_track :: (src: int, index: int, start_at: float64 = 0) {
    s := get_source(src);
    if !s || index < 0 || index >= s.tracks.count return;
    play_src = src;
    current = index;
    t := *s.tracks[index];
    play_serial = audio_play(t.path, start_at);
    end_handled = false;
    free(status_text.data); status_text = "";
    anim_set(ANIM_MISC + ID_TITLE_FADE, 0);
    scroll_to_current = true;
    request_cover(t.path);
    title := ifx t.artist.count then tprint("% - % - %", t.artist, t.title, APP_NAME) else tprint("% - %", t.title, APP_NAME);
    w_SetWindowTextW(main_hwnd, utf8_to_wide(title,, temp));
    dirty = true;
}

toggle_play :: () {
    if audio_state == .PLAYING {
        audio_pause();
    } else if audio_state == .PAUSED {
        audio_resume();
    } else if current >= 0 && current_track() {
        play_track(play_src, current);
    } else {
        s := get_source(view_src);
        if s && s.tracks.count > 0 play_track(view_src, 0);
    }
    dirty = true;
}

next_index :: (auto: bool) -> int {
    s := get_source(play_src);
    if !s return -1;
    n := s.tracks.count;
    if n == 0 return -1;
    if shuffle && n > 1 {
        r := cast(int) (random_get() % cast(u64) (n - 1));
        if r >= current r += 1;
        return r;
    }
    if current + 1 < n return current + 1;
    if repeat_all || !auto return 0;
    return -1;
}

next_track :: (auto := false) {
    i := next_index(auto);
    if i < 0 { dirty = true; return; }
    play_track(play_src, i);
}

prev_track :: () {
    s := get_source(play_src);
    if !s || s.tracks.count == 0 return;
    if audio_position() > 3 { audio_seek(0); return; }
    i := current - 1;
    if i < 0 i = s.tracks.count - 1;
    play_track(play_src, i);
}

select_source :: (i: int) {
    if search_text.count { search_text.count = 0; search_dirty = true; }
    if i == view_src return;
    view_src = i;
    scroll_y = 0; scroll_target = 0;
    dirty = true;
}

tick :: () {
    if gfx_ready receive_cover();
    if scan_job.done {
        apply_scan();
    }
    if want_rescan && !scan_job.running {
        want_rescan = false;
        start_scan(custom_folders);
    }

    if play_serial != 0 && audio_serial == play_serial {
        if audio_state == .ENDED && !end_handled {
            end_handled = true;
            next_track(auto = true);
        } else if audio_state == .ERROR && !end_handled {
            end_handled = true;
            free(status_text.data);
            status_text = copy_string(audio_error);
            dirty = true;
        }
    }
}

// Swaps in a finished scan. Keeps the shown/playing folder and track pointing at the same things.
apply_scan :: () {
    thread_is_done(*scan_job.thread, 1000);
    thread_deinit(*scan_job.thread);

    view_name := ifx get_source(view_src) then copy_string(get_source(view_src).name) else "";
    play_path := ifx current_track() then copy_string(current_track().path) else "";
    play_name := ifx get_source(play_src) then copy_string(get_source(play_src).name) else "";
    was_opened_playing := play_src == library.count && opened.tracks.count > 0;
    was_opened_view := view_src == library.count && opened.tracks.count > 0;

    for *s: library free_source(s);
    array_reset(*library);
    library = scan_job.sources;
    scan_job.sources.count = 0; scan_job.sources.data = null; scan_job.sources.allocated = 0;
    scan_job.done = false;
    scan_job.running = false;
    last_scan_time = seconds_since_init();
    search_dirty = true;

    new_view := 0;
    if was_opened_view {
        new_view = library.count;
    } else {
        for library if it.name == view_name { new_view = it_index; break; }
    }
    view_src = clamp(new_view, 0, max(source_count() - 1, 0));

    if was_opened_playing {
        play_src = library.count;
    } else if play_path.count {
        found := false;
        for library if it.name == play_name {
            for t, ti: it.tracks if t.path == play_path { play_src = it_index; current = ti; found = true; break; }
            if found break;
        }
        if !found { play_src = -1; current = -1; }
    }
    free_str(view_name); free_str(play_path); free_str(play_name);
    dirty = true;
}

//
// Opening files
//
// Adds files (and the audio files inside folders) to the "Opened files" list. Starts playing the
// first of them if nothing is playing, or always with `play_first` (a file opened from Explorer).
add_paths :: (paths: [] string, play_first := false) {
    found: Scan_Collect;
    for paths {
        attrs := w_GetFileAttributesW(utf8_to_wide(it,, temp));
        if attrs == 0xFFFFFFFF continue;                                     // INVALID_FILE_ATTRIBUTES
        if attrs & 0x10 visit_files(it, true, *found, collect_visit);       // FILE_ATTRIBUTE_DIRECTORY
        else if is_audio_path(it) array_add(*found.paths, copy_string(it));
    }
    if found.paths.count == 0 return;
    quick_sort(found.paths, path_less);

    first_new := opened.tracks.count;
    first_given := -1;
    for p: found.paths {
        index := -1;
        for opened.tracks  if compare_nocase(it.path, p) == 0 { index = it_index; break; }
        if index < 0 {
            array_add(*opened.tracks, make_track(p));
            index = opened.tracks.count - 1;
        }
        if first_given < 0 first_given = index;
        free(p.data);
    }
    array_reset(*found.paths);
    if !opened.name.count opened.name = copy_string("Opened files");
    opened.kind = .OPENED;

    search_dirty = true;
    idx := library.count;
    select_source(idx);
    if play_first                                                 play_track(idx, first_given);
    else if audio_state != .PLAYING && first_new < opened.tracks.count  play_track(idx, first_new);
    dirty = true;
}

wide_len :: (buf: [] u16, off: int) -> int {
    n := 0;
    while off + n < buf.count && buf[off + n] != 0  n += 1;
    return n;
}

make_filter :: (spec: string) -> [] u16 {
    out: [..] u16;
    out.allocator = temp;
    for 0..spec.count-1 {
        c := spec[it];
        array_add(*out, ifx c == #char "|" then cast(u16) 0 else cast(u16) c);
    }
    array_add(*out, 0);
    return out;
}

open_file_dialog :: () {
    buf    := NewArray(65536, u16,, temp);
    filter := make_filter("Audio files|*.mp3;*.flac;*.ogg;*.wav;*.m4a;*.aac;*.wma|All files|*.*|");

    ofn: OPENFILENAMEW;
    ofn.lStructSize = size_of(OPENFILENAMEW);
    ofn.hwndOwner   = main_hwnd;
    ofn.lpstrFilter = filter.data;
    ofn.lpstrFile   = buf.data;
    ofn.nMaxFile    = 65536;
    // ALLOWMULTISELECT | EXPLORER | FILEMUSTEXIST | PATHMUSTEXIST | NOCHANGEDIR
    ofn.Flags = 0x200 | 0x80000 | 0x1000 | 0x800 | 0x8;

    if !w_GetOpenFileNameW(*ofn) return;

    paths: [..] string;
    paths.allocator = temp;
    n0 := wide_len(buf, 0);
    if buf[n0 + 1] == 0 {
        array_add(*paths, wide_to_utf8(*buf[0],, temp));
    } else {
        dir := wide_to_utf8(*buf[0],, temp);
        off := n0 + 1;
        while buf[off] != 0 {
            name := wide_to_utf8(*buf[off],, temp);
            array_add(*paths, tprint("%\\%", dir, name));
            off += wide_len(buf, off) + 1;
        }
    }
    add_paths(paths);
}

clear_opened :: () {
    if play_src == library.count { audio_stop(); play_src = -1; current = -1; }
    for *opened.tracks free_track(it);
    array_reset(*opened.tracks);
    view_src = clamp(view_src, 0, max(source_count() - 1, 0));
    search_dirty = true;
    dirty = true;
}

//
// Window procedure
//
get_x :: (lp: LPARAM) -> float { return cast(float) cast,trunc(s16) lp; }
get_y :: (lp: LPARAM) -> float { return cast(float) cast,trunc(s16) (lp >> 16); }

window_proc :: (h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> s64 #c_call {
    ctx: #Context;
    if app_context_ready  ctx = app_context;
    push_context ctx {
        return handle_message(h, msg, wp, lp);
    }
}

caption_action :: (code: s32) {
    if code == {
        case HT_MINBUTTON; w_PostMessageW(main_hwnd, K_WM_SYSCOMMAND, 0xF020, 0);
        case HT_MAXBUTTON; w_PostMessageW(main_hwnd, K_WM_SYSCOMMAND, ifx w_IsZoomed(main_hwnd) then cast(u64) 0xF120 else cast(u64) 0xF030, 0);
        case HT_CLOSE;     w_PostMessageW(main_hwnd, K_WM_CLOSE, 0, 0);
    }
}

handle_message :: (h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> s64 {
    if msg == {
    case K_WM_NCCALCSIZE;
        // The whole window is client area: we draw our own title bar. DWM still provides
        // the rounded corners, border and shadow because the window keeps its frame styles.
        if wp != 0 && w_IsZoomed(h) {
            p := cast(*NCCALCSIZE_PARAMS_) lp;
            mi: MONITORINFO;
            mi.cbSize = size_of(MONITORINFO);
            if w_GetMonitorInfoW(w_MonitorFromWindow(h, 2), *mi) {
                p.rgrc[0] = mi.rcWork;
                // Keep the taskbar reachable when it auto-hides.
                if mi.rcWork.bottom == mi.rcMonitor.bottom  p.rgrc[0].bottom -= 1;
            }
        }
        return 0;

    case K_WM_NCHITTEST;
        r: RECT;
        w_GetWindowRect(h, *r);
        x := cast(s32) get_x(lp) - r.left;
        y := cast(s32) get_y(lp) - r.top;
        w := r.right - r.left;
        hh := r.bottom - r.top;
        s := cast(float) w_GetDpiForWindow(h) / 96.0;

        if !w_IsZoomed(h) {
            b  := cast(s32) (6 * s);
            cb := cast(s32) (14 * s);   // corner grab size
            if (x < cb && y < cb) return HT_TOPLEFT;
            if (x >= w - cb && y < cb) return HT_TOPRIGHT;
            if (x < cb && y >= hh - cb) return HT_BOTTOMLEFT;
            if (x >= w - cb && y >= hh - cb) return HT_BOTTOMRIGHT;
            if x < b return HT_LEFT;
            if x >= w - b return HT_RIGHT;
            if y < b return HT_TOP;
            if y >= hh - b return HT_BOTTOM;
        }

        code: s32 = HT_CLIENT;
        tb := cast(s32) (TITLEBAR_H * s);
        if y < tb {
            bw := cast(s32) (CAPTION_BTN_W * s);
            if x >= w - bw          code = HT_CLOSE;
            else if x >= w - 2 * bw code = HT_MAXBUTTON;   // lets Windows 11 show Snap Layouts
            else if x >= w - 3 * bw code = HT_MINBUTTON;
            else                    code = HT_CAPTION;
        }
        hot: s32 = ifx code == HT_CLOSE || code == HT_MAXBUTTON || code == HT_MINBUTTON then code else 0;
        if hot != nc_hot { nc_hot = hot; dirty = true; }
        return code;

    case K_WM_NCMOUSEMOVE;
        if !nc_tracked {
            t: TRACKMOUSEEVENT_;
            t.cbSize = size_of(TRACKMOUSEEVENT_);
            t.dwFlags = 2 | 0x10;  // TME_LEAVE | TME_NONCLIENT
            t.hwndTrack = h;
            w_TrackMouseEvent(*t);
            nc_tracked = true;
        }
        mx = -10000; my = -10000;
        if nc_pressed != 0 && wp != cast(u64) nc_pressed nc_pressed = 0;
        dirty = true;
        return w_DefWindowProcW(h, msg, wp, lp);
    case K_WM_NCMOUSELEAVE;
        nc_tracked = false;
        nc_hot = 0; nc_pressed = 0;
        dirty = true;
        return 0;
    case K_WM_NCLBUTTONDOWN;
        if wp == HT_MINBUTTON || wp == HT_MAXBUTTON || wp == HT_CLOSE {
            nc_pressed = cast(s32) wp;
            dirty = true;
            return 0;
        }
        return w_DefWindowProcW(h, msg, wp, lp);
    case K_WM_NCLBUTTONUP;
        if nc_pressed != 0 {
            code := nc_pressed;
            nc_pressed = 0;
            dirty = true;
            if wp == cast(u64) code caption_action(code);
            return 0;
        }
        return w_DefWindowProcW(h, msg, wp, lp);
    case K_WM_NCACTIVATE;
        return w_DefWindowProcW(h, msg, wp, -1);   // don't let Windows repaint a frame we don't have

    case K_WM_GETMINMAXINFO;
        if h != null {
            s := cast(float) w_GetDpiForWindow(h) / 96.0;
            mm := cast(*MINMAXINFO_) lp;
            mm.ptMinTrackSize.x = cast(s32) (MIN_W * s);
            mm.ptMinTrackSize.y = cast(s32) (MIN_H * s);
        }
        return 0;

    case K_WM_ERASEBKGND;
        return 1;

    case K_WM_PAINT;
        // Flip-model frames persist in DWM, so only draw if something changed.
        w_ValidateRect(h, null);
        if dirty frame();
        return 0;

    case K_WM_SIZE;
        if wp != 1 {  // not minimized
            win_w = cast(s32) (lp & 0xFFFF);
            win_h = cast(s32) ((lp >> 16) & 0xFFFF);
            dirty = true;
            if gfx_ready {
                gfx_resize(win_w, win_h);   // resize the swap chain right here...
                frame();                    // ...and present a frame for the new size before returning
            }
        }
        return 0;

    case K_WM_DPICHANGED;
        dpi_scale = cast(float) (wp & 0xFFFF) / 96.0;
        r := cast(*RECT) lp;
        w_SetWindowPos(h, null, r.left, r.top, r.right - r.left, r.bottom - r.top, 0x0004 | 0x0010);  // NOZORDER | NOACTIVATE
        dirty = true;
        return 0;

    case K_WM_ENTERSIZEMOVE;
        w_SetTimer(h, 1, 16, null);
        return 0;
    case K_WM_EXITSIZEMOVE;
        w_KillTimer(h, 1);
        return 0;
    case K_WM_TIMER;
        if wp == 1 && (dirty || animating) frame();
        return 0;

    case K_WM_SETFOCUS;
        if seconds_since_init() - last_scan_time > 10 want_rescan = true;
        dirty = true;
        return 0;

    case K_WM_MOUSEMOVE;
        mx = get_x(lp); my = get_y(lp);
        if nc_hot != 0 { nc_hot = 0; }
        if !mouse_tracked {
            t: TRACKMOUSEEVENT_;
            t.cbSize = size_of(TRACKMOUSEEVENT_);
            t.dwFlags = 2;  // TME_LEAVE
            t.hwndTrack = h;
            w_TrackMouseEvent(*t);
            mouse_tracked = true;
        }
        dirty = true;
        return 0;
    case K_WM_MOUSELEAVE;
        mouse_tracked = false;
        if !mouse_down { mx = -10000; my = -10000; }
        dirty = true;
        return 0;
    case K_WM_LBUTTONDOWN;
        mx = get_x(lp); my = get_y(lp);
        mouse_down = true; mouse_pressed = true;
        w_SetCapture(h);
        dirty = true;
        return 0;
    case K_WM_LBUTTONUP;
        mx = get_x(lp); my = get_y(lp);
        mouse_down = false; mouse_released = true;
        nc_pressed = 0;
        w_ReleaseCapture();
        dirty = true;
        return 0;
    case K_WM_CAPTURECHANGED;
        if mouse_down { mouse_down = false; mouse_released = true; dirty = true; }
        return 0;
    case K_WM_MOUSEWHEEL;
        wheel_accum += cast(float) cast,trunc(s16) (wp >> 16) / 120.0;
        dirty = true;
        return 0;
    case K_WM_KEYDOWN;
        array_add(*key_events, cast,trunc(u32) wp);
        dirty = true;
        return 0;
    case K_WM_CHAR;
        array_add(*char_events, cast,trunc(u32) wp);
        dirty = true;
        return 0;
    case K_WM_HOTKEY;
        // Global media keys (work while the window is in the background); the id is the APPCOMMAND.
        array_add(*app_commands, cast(s32) wp);
        dirty = true;
        return 0;
    case K_WM_APPCOMMAND;
        cmd := cast(s32) ((lp >> 16) & 0xFFF);
        if (cmd >= APPCOMMAND_NEXT && cmd <= APPCOMMAND_PLAY_PAUSE) || cmd == APPCOMMAND_PLAY || cmd == APPCOMMAND_PAUSE {
            array_add(*app_commands, cmd);
            dirty = true;
            return 1;
        }
        return w_DefWindowProcW(h, msg, wp, lp);

    case K_WM_SETCURSOR;
        if (lp & 0xFFFF) == HT_CLIENT {
            w_SetCursor(ifx cursor_size then cursor_we_h else (ifx cursor_hand then cursor_hand_h else cursor_arrow_h));
            return 1;
        }
        return w_DefWindowProcW(h, msg, wp, lp);

    case K_WM_DROPFILES;
        drop := cast(HDROP) wp;
        count := w_DragQueryFileW(drop, 0xFFFFFFFF, null, 0);
        for 0..cast(int)count-1 {
            len := w_DragQueryFileW(drop, xx it, null, 0);
            buf := NewArray(len + 1, u16,, temp);
            w_DragQueryFileW(drop, xx it, buf.data, len + 1);
            array_add(*dropped, copy_string(wide_to_utf8(buf.data,, temp)));
        }
        w_DragFinish(drop);
        dirty = true;
        return 0;

    case K_WM_COPYDATA;
        return ifx receive_paths(lp) then 1 else 0;

    case K_WM_CLOSE;
        w_DestroyWindow(h);
        return 0;
    case K_WM_DESTROY;
        quit = true;
        w_PostQuitMessage(0);
        return 0;
    }

    return w_DefWindowProcW(h, msg, wp, lp);
}

create_main_window :: () -> bool {
    hinst := w_GetModuleHandleW(null);
    cursor_arrow_h = w_LoadCursorW(null, IDC_ARROW);
    cursor_hand_h  = w_LoadCursorW(null, IDC_HAND);
    cursor_we_h    = w_LoadCursorW(null, cast(*void) 32644);   // IDC_SIZEWE

    wc: WNDCLASSEXW;
    wc.cbSize        = size_of(WNDCLASSEXW);
    wc.lpfnWndProc   = window_proc;
    wc.hInstance     = hinst;
    wc.hCursor       = cursor_arrow_h;
    wc.lpszClassName = utf8_to_wide(WINDOW_CLASS,, temp);
    if w_RegisterClassExW(*wc) == 0 return false;

    s := cast(float) w_GetDpiForSystem() / 96.0;
    dpi_scale = s;

    // WS_OVERLAPPEDWINDOW keeps what Windows expects of a normal window (snapping, shadow,
    // rounded corners, min/max animations, system menu); WM_NCCALCSIZE removes the frame.
    main_hwnd = w_CreateWindowExW(0x10,  // WS_EX_ACCEPTFILES
        wc.lpszClassName, utf8_to_wide(APP_NAME,, temp), 0x00CF0000,
        cast(s32) 0x80000000, cast(s32) 0x80000000,
        cast(s32) (1180 * s), cast(s32) (720 * s),
        null, null, hinst, null);
    if !main_hwnd return false;

    // Dark title/system menu, and rounded corners (Windows 11).
    dark: s32 = 1;
    w_DwmSetWindowAttribute(main_hwnd, 20, *dark, 4);     // DWMWA_USE_IMMERSIVE_DARK_MODE
    round: s32 = 2;
    w_DwmSetWindowAttribute(main_hwnd, 33, *round, 4);    // DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND

    // Global media keys (0x4000 = MOD_NOREPEAT).
    w_RegisterHotKey(main_hwnd, APPCOMMAND_PLAY_PAUSE, 0x4000, VK_MEDIA_PLAY_PAUSE);
    w_RegisterHotKey(main_hwnd, APPCOMMAND_STOP,       0x4000, VK_MEDIA_STOP);
    w_RegisterHotKey(main_hwnd, APPCOMMAND_NEXT,       0x4000, VK_MEDIA_NEXT_TRACK);
    w_RegisterHotKey(main_hwnd, APPCOMMAND_PREV,       0x4000, VK_MEDIA_PREV_TRACK);

    // Window/taskbar icon: the first icon resource embedded in the exe (see build.jai).
    icon := w_ExtractIconW(hinst, utf8_to_wide(exe_path(),, temp), 0);
    if icon {
        w_SendMessageW(main_hwnd, 0x80, 0, cast(s64) icon);   // WM_SETICON, ICON_SMALL
        w_SendMessageW(main_hwnd, 0x80, 1, cast(s64) icon);   // ICON_BIG
    }

    dpi_scale = cast(float) w_GetDpiForWindow(main_hwnd) / 96.0;
    r: RECT;
    w_GetClientRect(main_hwnd, *r);
    win_w = r.right - r.left;
    win_h = r.bottom - r.top;
    return true;
}


//
// Settings: pane sizes, color scheme, volume, toggles and your own music folders are kept in
// %APPDATA%\Nickel\settings.txt (one "key value" per line; "folder <path>" can repeat).
//
FOLDERID_APPDATA :: GUID.{0x3EB685DB, 0x65F9, 0x4CF6, .[0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D]};

// Pane sizes in logical pixels; both panes can be resized by dragging the gutter next to them.
sidebar_w: float = 232;
right_w:   float = 340;

custom_folders: [..] string;

settings_dirty := false;
settings_changed_at: float64;

mark_settings :: () {
    settings_dirty = true;
    settings_changed_at = seconds_since_init();
}

settings_file :: () -> string {
    id := FOLDERID_APPDATA;
    out: *u16;
    if w_SHGetKnownFolderPath(*id, 0, null, *out) < 0 || !out return "";
    dir := tprint("%/Nickel", wide_to_utf8(out,, temp));
    w_CoTaskMemFree(out);
    make_directory_if_it_does_not_exist(dir);
    return tprint("%/settings.txt", dir);
}

b2i :: (b: bool) -> int { return ifx b then 1 else 0; }

save_settings :: () {
    path := settings_file();
    if !path.count return;
    text := tprint("sidebar_w %\nright_w %\ntheme %\nvolume %\nshuffle %\nrepeat %\n",
                   cast(int) sidebar_w, cast(int) right_w, theme_index, cast(int) (volume * 100), b2i(shuffle), b2i(repeat_all));
    for custom_folders text = tprint("%folder %\n", text, it);
    write_entire_file(path, text);
    settings_dirty = false;
}

load_settings :: () {
    path := settings_file();
    if !path.count return;
    data, ok := read_entire_file(path);
    if !ok return;
    defer free(data.data);
    lines := split(data, "\n",, temp);
    for lines {
        line := trim(it);
        if starts_with(line, "folder ") {
            f := trim(slice(line, 7, line.count - 7));
            if f.count array_add(*custom_folders, copy_string(f));
            continue;
        }
        parts := split(line, " ",, temp);
        if parts.count < 2 continue;
        v, good := to_integer(parts[1]);
        if !good continue;
        if parts[0] == "sidebar_w" sidebar_w = clamp(cast(float) v, 160, 420);
        else if parts[0] == "right_w"   right_w = clamp(cast(float) v, 260, 560);
        else if parts[0] == "theme"     theme_index = clamp(v, 0, THEMES.count - 1);
        else if parts[0] == "volume"    volume = clamp(cast(float) v / 100.0, 0, 1);
        else if parts[0] == "shuffle"   shuffle = v != 0;
        else if parts[0] == "repeat"    repeat_all = v != 0;
    }
}

add_custom_folder :: (path: string) {
    for custom_folders if compare_nocase(it, path) == 0 return;
    array_add(*custom_folders, copy_string(path));
    mark_settings();
    want_rescan = true;
}

remove_custom_folder :: (path: string) {
    for custom_folders if compare_nocase(it, path) == 0 {
        free_str(it);
        remove it;
        break;
    }
    mark_settings();
    want_rescan = true;
}

//
// Windows folder picker (IFileOpenDialog with FOS_PICKFOLDERS).
//
CLSID_FileOpenDialog :: GUID.{0xDC1C5A9C, 0xE88A, 0x4DDE, .[0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7]};
IID_IFileOpenDialog  :: GUID.{0xD57C7288, 0xD4AD, 0x4768, .[0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60]};

w_CoCreateInstance :: (clsid: *GUID, outer: *void, ctx: u32, iid: *GUID, out: **void) -> s32 #foreign lib_ole32 "CoCreateInstance";

Fn_FD_Show       :: #type (this: *void, owner: HWND) -> s32 #c_call;
Fn_FD_SetOptions :: #type (this: *void, opts: u32) -> s32 #c_call;
Fn_FD_GetOptions :: #type (this: *void, opts: *u32) -> s32 #c_call;
Fn_FD_SetTitle   :: #type (this: *void, title: *u16) -> s32 #c_call;
Fn_FD_GetResult  :: #type (this: *void, item: **void) -> s32 #c_call;
Fn_SI_GetName    :: #type (this: *void, sigdn: u32, name: **u16) -> s32 #c_call;

pick_folder :: () -> string {
    clsid := CLSID_FileOpenDialog;
    iid := IID_IFileOpenDialog;
    dlg: *void;
    if w_CoCreateInstance(*clsid, null, 1, *iid, *dlg) < 0 || !dlg return "";
    defer com_release(dlg);

    opts: u32;
    get_options := cast(Fn_FD_GetOptions) com_slot(dlg, 10);
    set_options := cast(Fn_FD_SetOptions) com_slot(dlg, 9);
    set_title   := cast(Fn_FD_SetTitle)   com_slot(dlg, 17);
    show        := cast(Fn_FD_Show)       com_slot(dlg, 3);
    get_result  := cast(Fn_FD_GetResult)  com_slot(dlg, 20);
    get_options(dlg, *opts);
    set_options(dlg, opts | 0x20 | 0x40);   // FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM
    set_title(dlg, utf8_to_wide("Add a music folder",, temp));
    if show(dlg, main_hwnd) < 0 return "";

    item: *void;
    if get_result(dlg, *item) < 0 || !item return "";
    defer com_release(item);

    get_name := cast(Fn_SI_GetName) com_slot(item, 5);
    name: *u16;
    if get_name(item, 0x80058000, *name) < 0 || !name return "";   // SIGDN_FILESYSPATH
    result := copy_string(wide_to_utf8(name,, temp));
    w_CoTaskMemFree(name);
    return result;
}

//
// Fuzzy search: every space-separated word must match; a whole-substring match beats a scattered
// (subsequence) match, and matches at word starts and in a row score higher.
//
search_text: [..] u8;
search_focused := false;
search_dirty := false;

Search_Hit :: struct { src: int; idx: int; score: int; }
search_hits: [..] Search_Hit;

searching :: () -> bool { return search_text.count > 0; }

search_query :: () -> string { return string.{search_text.count, search_text.data}; }

is_boundary :: (c: u8) -> bool {
    return c == #char " " || c == #char "-" || c == #char "_" || c == #char "." || c == #char "(" || c == #char "[" || c == #char "/" || c == #char "'";
}

find_sub :: (hay: string, needle: string) -> int {
    if needle.count == 0 return 0;
    if needle.count > hay.count return -1;
    for i: 0..hay.count - needle.count {
        match := true;
        for j: 0..needle.count-1 if hay[i + j] != needle[j] { match = false; break; }
        if match return i;
    }
    return -1;
}

// Both strings must already be lowercase. Returns -1 for "no match".
fuzzy_score :: (needle: string, hay: string) -> int {
    if !needle.count return 0;
    pos := find_sub(hay, needle);
    if pos >= 0 {
        bonus := 1000 - pos * 2;
        if pos == 0 || is_boundary(hay[pos - 1]) bonus += 300;
        return bonus - hay.count / 4;
    }

    score := 0;
    hi := 0;
    last := -2;
    gaps := 0;
    for 0..needle.count-1 {
        c := needle[it];
        found := false;
        while hi < hay.count {
            if hay[hi] == c {
                s := 10;
                if hi == last + 1 s += 18;
                if hi == 0 || is_boundary(hay[hi - 1]) s += 14;
                score += s;
                last = hi;
                hi += 1;
                found = true;
                break;
            }
            gaps += 1;
            hi += 1;
        }
        if !found return -1;
    }
    if gaps > needle.count * 6 + 12 return -1;   // too scattered to be a useful match
    return max(score - gaps, 1);
}

hit_cmp :: (a: Search_Hit, b: Search_Hit) -> s64 {
    if a.score != b.score return cast(s64) (b.score - a.score);
    if a.src != b.src return cast(s64) (a.src - b.src);
    return cast(s64) (a.idx - b.idx);
}

rebuild_search :: () {
    search_dirty = false;
    array_reset(*search_hits);
    if !searching() return;

    q := to_lower_copy(search_query(),, temp);
    tokens: [..] string;
    tokens.allocator = temp;
    for split(q, " ",, temp) if it.count array_add(*tokens, it);
    if !tokens.count return;

    n := source_count();
    for si: 0..n-1 {
        s := get_source(si);
        if !s || s.kind == .ALL continue;   // "All music" would only repeat the others
        for t, ti: s.tracks {
            hay := to_lower_copy(tprint("% % % %", t.title, t.artist, t.album, path_filename(t.path)),, temp);
            total := 0;
            ok := true;
            for tok: tokens {
                sc := fuzzy_score(tok, hay);
                if sc < 0 { ok = false; break; }
                total += sc;
            }
            if ok array_add(*search_hits, .{si, ti, total});
        }
    }
    quick_sort(search_hits, hit_cmp);
    scroll_y = 0; scroll_target = 0;
}

//
// UI
//
ID_OPEN :: 10; ID_REFRESH :: 11; ID_CLEAR :: 12; ID_SHUF :: 13; ID_REP :: 14; ID_DEFAULT_APP :: 15; ID_ADD_FOLDER :: 16;
ID_THEME_BTN :: 17; ID_SEARCH :: 18; ID_SEARCH_CLR :: 19;
ID_PLAY :: 20; ID_PREV :: 21; ID_NEXT :: 22; ID_SEEK :: 23; ID_VOL :: 24; ID_MUTE :: 25;
ID_SPLIT_SB :: 26; ID_SPLIT_RP :: 27;
ID_SCROLL :: 30; ID_SRC :: 1000; ID_REMOVE :: 3000; ID_ROW :: 100000;

scroll_y: float;
scroll_target: float;
scroll_to_current := false;
scroll_grab: float;
chip_scroll: float;
viz_raw: [VIZ_BARS] float;
viz_smooth: [VIZ_BARS] float;
last_frame_time: float64;
want_add_folder := false;

stop_playback :: () {
    audio_stop();
    end_handled = true;
    dirty = true;
}

frame :: () {
    if in_frame return;
    in_frame = true;
    defer in_frame = false;

    tick();
    if !gfx_ready || win_w <= 0 || win_h <= 0 || w_IsIconic(main_hwnd) return;

    dirty = false;
    now := seconds_since_init();
    frame_dt = cast(float) clamp(now - last_frame_time, 0.0005, 0.1);
    last_frame_time = now;
    anim_time += frame_dt;

    handle_input_events();
    if search_dirty rebuild_search();

    animating = false;
    cursor_hand = false;
    cursor_size = false;
    if search_focused animating = true;   // caret blink

    // Spectrum for the visualizer.
    if audio_state == .PLAYING {
        compute_spectrum(*viz_raw);
    } else {
        for 0..VIZ_BARS-1 viz_raw[it] = 0;
    }
    any_viz := false;
    for 0..VIZ_BARS-1 {
        target := viz_raw[it];
        rate := ifx target > viz_smooth[it] then 30.0 else 7.0;
        viz_smooth[it] += (target - viz_smooth[it]) * (1 - exp(-rate * frame_dt));
        if viz_smooth[it] > 0.004 any_viz = true;
    }
    if any_viz animating = true;

    gfx_begin(COL_BG.x, COL_BG.y, COL_BG.z);
    draw_ui();
    gfx_end();

    mouse_pressed = false;
    mouse_released = false;
    wheel_accum = 0;
    array_reset(*key_events);
    array_reset(*char_events);
    if !mouse_down active_id = 0;
    if audio_state == .PLAYING || audio_state == .LOADING animating = true;
    reset_temporary_storage();
}

handle_input_events :: () {
    ctrl := (w_GetKeyState(VK_CONTROL) & 0x8000) != 0;

    // Text typed into the search box.
    if search_focused {
        high: u32 = 0;
        for c: char_events {
            if c == VK_BACK {
                if search_text.count > 0 {
                    search_text.count -= 1;
                    while search_text.count > 0 && (search_text.data[search_text.count] & 0xC0) == 0x80  search_text.count -= 1;
                    search_dirty = true;
                }
            } else if c >= 0xD800 && c < 0xDC00 {
                high = c;
            } else if c >= 32 && c != 127 {
                cp := c;
                if c >= 0xDC00 && c < 0xE000 && high != 0 { cp = 0x10000 + ((high - 0xD800) << 10) + (c - 0xDC00); high = 0; }
                append_utf8(*search_text, cp);
                search_dirty = true;
            }
        }
    }

    for key_events {
        if search_focused {
            if it == VK_ESCAPE { search_text.count = 0; search_focused = false; search_dirty = true; }
            else if it == VK_RETURN && search_hits.count > 0 { play_track(search_hits[0].src, search_hits[0].idx); }
            continue;
        }
        if ctrl && it == #char "F" { search_focused = true; continue; }
        if it == {
            case VK_ESCAPE; if searching() { search_text.count = 0; search_dirty = true; }
            case VK_SPACE;  toggle_play();
            case #char "X"; stop_playback();
            case VK_LEFT;   if ctrl prev_track(); else audio_seek(audio_position() - 5);
            case VK_RIGHT;  if ctrl next_track(); else audio_seek(audio_position() + 5);
            case VK_UP;     volume = min(1.0, volume + 0.05); muted = false; apply_volume(); mark_settings();
            case VK_DOWN;   volume = max(0.0, volume - 0.05); apply_volume(); mark_settings();
            case #char "M"; muted = !muted; apply_volume();
            case #char "O"; want_open_dialog = true;
            case #char "S"; shuffle = !shuffle; mark_settings();
            case #char "R"; repeat_all = !repeat_all; mark_settings();
            case VK_F5;     want_rescan = true;
        }
    }
    for app_commands {
        if it == {
            case APPCOMMAND_NEXT;       next_track();
            case APPCOMMAND_PREV;       prev_track();
            case APPCOMMAND_STOP;       stop_playback();
            case APPCOMMAND_PLAY_PAUSE; toggle_play();
            case APPCOMMAND_PLAY;       if audio_state != .PLAYING toggle_play();
            case APPCOMMAND_PAUSE;      if audio_state == .PLAYING audio_pause();
        }
    }
    array_reset(*app_commands);

    if dropped.count {
        add_paths(dropped);
        for dropped free(it.data);
        array_reset(*dropped);
    }
    if shell_opened.count {
        add_paths(shell_opened, play_first = true);
        for shell_opened free(it.data);
        array_reset(*shell_opened);
    }
}

draw_ui :: () {
    W := cast(float) win_w;
    H := cast(float) win_h;
    S := dpi_scale;
    ui_alpha = 1;

    fill(0, 0, W, H, COL_BG);

    g := 8 * S;
    tb_h := TITLEBAR_H * S;
    body_y0 := tb_h;
    body_y1 := H - g;
    wide := W >= 760 * S;

    if wide {
        // sidebar | playlist | player, with draggable gutters between them
        avail := W - 4 * g;
        sbw := clamp(sidebar_w, 160, 420) * S;
        rw  := clamp(right_w, 260, 560) * S;
        over := sbw + rw + 300 * S - avail;
        if over > 0 {
            cut := min(over * 0.5, sbw - 160 * S);
            sbw -= cut; over -= cut;
            cut = min(over, rw - 260 * S);
            rw -= cut; over -= cut;
            if over > 0 sbw = max(160 * S, sbw - over);
        }
        x := g;
        draw_sidebar(x, body_y0, x + sbw, body_y1);
        if splitter(ID_SPLIT_SB, x + sbw + g * 0.5, body_y0, body_y1, *sidebar_w, 1, 160, 420) mark_settings();
        x += sbw + g;
        rx0 := W - g - rw;
        draw_playlist(x, body_y0, rx0 - g, body_y1);
        draw_now_playing(rx0, body_y0, W - g, body_y1);
        if splitter(ID_SPLIT_RP, rx0 - g * 0.5, body_y0, body_y1, *right_w, -1, 260, 560) mark_settings();
    } else {
        chips_h := 40 * S;
        draw_chips(g, body_y0, W - g, body_y0 + chips_h);
        np_h := 150 * S;
        np_y0 := body_y1 - np_h;
        draw_playlist(g, body_y0 + chips_h + g, W - g, np_y0 - g);
        draw_now_playing(g, np_y0, W - g, body_y1);
    }

    draw_titlebar(W, tb_h);
    draw_tooltip();
}

draw_titlebar :: (W: float, tb_h: float) {
    S := dpi_scale;
    cy := tb_h * 0.5;

    // App mark (same note-on-dark-square as the exe icon) and name.
    m := 24 * S;
    rounded(12 * S, cy - m * 0.5, 12 * S + m, cy + m * 0.5, radius() * 0.75, COL_PANEL);
    outline(12 * S, cy - m * 0.5, 12 * S + m, cy + m * 0.5, radius() * 0.75, line_w(), COL_BORDER);
    draw_icon(.NOTE, 12 * S + m * 0.5, cy, 15 * S, COL_ACCENT);
    text(APP_NAME, 44 * S, cy, 14, COL_TEXT);

    bw := CAPTION_BTN_W * S;
    maximized := w_IsZoomed(main_hwnd) != 0;
    codes := s32.[HT_MINBUTTON, HT_MAXBUTTON, HT_CLOSE];
    for i: 0..2 {
        code := codes[i];
        x0 := W - (3 - i) * bw;
        hovered := nc_hot == code;
        pressed := nc_pressed == code && hovered;
        hv := animate(ANIM_HOVER + 900 + i, ifx hovered then 1.0 else 0.0, 22);
        if hv > 0.01 {
            c := ifx code == HT_CLOSE then COL_CLOSE else Vector4.{1, 1, 1, 0.10};
            c.w *= ifx pressed then 0.7 else hv;
            fill(x0, 0, x0 + bw, tb_h, c);
        }
        cx := x0 + bw * 0.5;
        ic := ifx code == HT_CLOSE && hv > 0.5 then WHITE else lerp4(COL_DIM, WHITE, hv);
        t1 := line_w();
        if code == HT_MINBUTTON {
            fill(cx - 5 * S, cy, cx + 5 * S, cy + t1, ic);
        } else if code == HT_MAXBUTTON {
            box :: (l: float, tp: float, r: float, b: float, t: float, c: Vector4) {
                fill(l, tp, r, tp + t, c); fill(l, b - t, r, b, c);
                fill(l, tp + t, l + t, b - t, c);  fill(r - t, tp + t, r, b - t, c);
            }
            if maximized {
                box(cx - 5 * S, cy - 3 * S, cx + 3 * S, cy + 5 * S, t1, ic);
                fill(cx - 3 * S, cy - 5 * S, cx + 5 * S, cy - 5 * S + t1, ic);
                fill(cx + 5 * S - t1, cy - 5 * S + t1, cx + 5 * S, cy + 3 * S, ic);
            } else {
                box(cx - 5 * S, cy - 5 * S, cx + 5 * S, cy + 5 * S, t1, ic);
            }
        } else {
            line(cx - 5 * S, cy - 5 * S, cx + 5 * S, cy + 5 * S, t1, ic);
            line(cx - 5 * S, cy + 5 * S, cx + 5 * S, cy - 5 * S, t1, ic);
        }
    }
}

draw_sidebar :: (x0: float, y0: float, x1: float, y1: float) {
    S := dpi_scale;
    panel(x0, y0, x1, y1);

    pad := 12 * S;
    head_cy := y0 + 32 * S;
    text("Library", x0 + pad + 8 * S, head_cy, 13, COL_DIM);
    if icon_btn(ID_ADD_FOLDER, .FOLDER_PLUS, x1 - pad - 16 * S, head_cy, 32 * S, 18 * S, false, "Add a music folder", with_bg = true) want_add_folder = true;

    item_h := 38 * S;
    list_y0 := y0 + 58 * S;
    n := source_count();
    pending_remove: string;

    clip_y1 := y1 - 6 * S;
    gfx_set_scissor(cast(s32) x0, cast(s32) (y0 + 52 * S), cast(s32) x1, cast(s32) clip_y1);
    for i: 0..n-1 {
        s := get_source(i);
        if !s continue;
        iy := list_y0 + i * item_h;
        if iy > clip_y1 break;
        ih := item_h - 2 * S;
        cy := iy + ih * 0.5;
        removable := s.kind == .CUSTOM;
        right_limit := ifx removable then x1 - pad - 30 * S else x1 - pad;

        clicked, hovered, held := button(ID_SRC + i, x0 + pad, iy, right_limit, iy + ih);
        if clicked select_source(i);
        row_hover := hovered || in_box(x0 + pad, iy, x1 - pad, iy + ih);

        selected := i == view_src;
        if selected      rounded(x0 + pad, iy, x1 - pad, iy + ih, radius(), with_alpha(COL_ACCENT, 0.14));
        else if row_hover rounded(x0 + pad, iy, x1 - pad, iy + ih, radius(), COL_HOVER);

        playing_here := i == play_src && audio_state == .PLAYING;
        draw_icon(ifx s.kind == .OPENED then Icon.NOTE else Icon.FOLDER, x0 + pad + 20 * S, cy, 17 * S, ifx selected then COL_ACCENT else COL_DIM);

        count_s := tprint("%", s.tracks.count);
        cw := text_width(count_s, 12);
        name_right := right_limit - 12 * S;
        if removable {
            if row_hover {
                if icon_btn(ID_REMOVE + i, .CLOSE, x1 - pad - 17 * S, cy, 26 * S, 12 * S, false, "Remove this folder from the library") pending_remove = copy_string(s.path);
            }
            name_right = x1 - pad - 34 * S;
            if !row_hover { text(count_s, x1 - pad - 12 * S - cw, cy, 12, COL_DIM); name_right = x1 - pad - 24 * S - cw; }
        } else {
            text(count_s, x1 - pad - 12 * S - cw, cy, 12, COL_DIM);
            name_right = x1 - pad - 24 * S - cw;
        }
        name_x := x0 + pad + 40 * S;
        dot_room := ifx playing_here then 12.0 * S else 0.0;
        text(fit_text(s.name, name_right - name_x - dot_room, 14), name_x, cy, 14, COL_TEXT);
        if playing_here disc(name_right - 2 * S, cy, 2.4 * S, COL_ACCENT);
    }
    gfx_clear_scissor();

    if n == 0 {
        text_centered("No music found", (x0 + x1) * 0.5, y0 + 110 * S, 13, COL_DIM);
        text_centered("Add a folder with the button above", (x0 + x1) * 0.5, y0 + 134 * S, 12, COL_DIM);
    }

    if pending_remove.count {
        remove_custom_folder(pending_remove);
        free_str(pending_remove);
    }
}

// Narrow layout: the sidebar becomes a row of chips.
draw_chips :: (x0: float, y0: float, x1: float, y1: float) {
    S := dpi_scale;
    cy := (y0 + y1) * 0.5;
    n := source_count();

    add_w := y1 - y0;
    total: float = 0;
    for 0..n-1 { s := get_source(it); total += text_width(s.name, 13) + 28 * S + 6 * S; }
    list_x1 := x1 - add_w - 6 * S;
    if in_box(x0, y0, list_x1, y1) chip_scroll -= wheel_accum * 60 * S;
    chip_scroll = clamp(chip_scroll, 0, max(0.0, total - (list_x1 - x0)));

    gfx_set_scissor(cast(s32) x0, cast(s32) y0, cast(s32) list_x1, cast(s32) y1);
    x := x0 - chip_scroll;
    for i: 0..n-1 {
        s := get_source(i);
        if !s continue;
        w := text_width(s.name, 13) + 28 * S;
        clicked, hovered, held := button(ID_SRC + i, x, y0, x + w, y1);
        if clicked select_source(i);
        sel := i == view_src;
        rounded(x, y0, x + w, y1, radius(), ifx hovered then COL_HOVER else COL_PANEL);
        if sel rounded(x, y0, x + w, y1, radius(), with_alpha(COL_ACCENT, 0.16));
        outline(x, y0, x + w, y1, radius(), line_w(), ifx sel then COL_ACCENT else COL_BORDER);
        text_centered(s.name, x + w * 0.5, cy, 13, ifx sel then COL_ACCENT else COL_TEXT);
        x += w + 6 * S;
    }
    gfx_clear_scissor();

    if icon_btn(ID_ADD_FOLDER, .FOLDER_PLUS, x1 - add_w * 0.5, cy, add_w, 18 * S, false, "Add a music folder", with_bg = true) want_add_folder = true;
}

//
// Cover art of the playing track, loaded in the background by art.jai.
//
cover: Gfx_Image;
cover_path:   string;   // track the texture belongs to
cover_wanted: string;   // track whose cover was asked for last

request_cover :: (path: string) {
    if path == cover_wanted return;
    free_str(cover_wanted);
    cover_wanted = copy_string(path);
    art_request(path);
}

receive_cover :: () {
    a, ok := art_poll();
    if !ok return;
    defer art_free(*a);
    if a.path != cover_wanted return;   // a track we have already skipped past

    gfx_destroy_image(*cover);
    if a.pixels cover = gfx_create_image(a.pixels, a.w, a.h);
    free_str(cover_path);
    cover_path = copy_string(a.path);
    anim_set(ANIM_MISC + ID_COVER_FADE, 0);
    dirty = true;
}

have_cover :: () -> bool {
    t := current_track();
    return cover.srv != null && t != null && t.path == cover_path;
}

// One big rounded square: the cover art with the spectrum along its bottom, or just the spectrum
// (with a note when nothing is playing).
draw_cover :: (x0: float, y0: float, side: float, show_note: bool, bars: int) {
    S := dpi_scale;
    x1 := x0 + side;
    y1 := y0 + side;
    rounded(x0, y0, x1, y1, radius(), COL_BG);
    art := have_cover();
    if art {
        fade := animate(ANIM_MISC + ID_COVER_FADE, 1, 10);
        gfx_image_begin(cover, x0, y0, x1, y1);
        rounded(x0, y0, x1, y1, radius(), with_alpha(WHITE, fade));
        gfx_image_end();
    }
    outline(x0, y0, x1, y1, radius(), line_w(), COL_BORDER);

    inset := side * 0.09;
    base_y := y1 - inset;
    max_h := ifx art then side * 0.3 else side - inset * 2;
    bw := (side - inset * 2) / bars;
    for i: 0..bars-1 {
        v := viz_smooth[i * VIZ_BARS / bars];
        bx0 := x0 + inset + i * bw + bw * 0.16;
        bx1 := x0 + inset + i * bw + bw * 0.84;
        if art {
            // Over a picture: only bars that are moving, each with a soft dark edge.
            if v < 0.02 continue;
            hh := max(bw * 0.7, v * max_h);
            e := 1.5 * S;
            rounded(bx0 - e, base_y - hh - e, bx1 + e, base_y + e, bw * 0.3 + e, Vector4.{0, 0, 0, 0.35});
            rounded(bx0, base_y - hh, bx1, base_y, bw * 0.3, COL_ACCENT);
        } else {
            hh := max(bw * 0.7, v * max_h);
            rounded(bx0, base_y - hh, bx1, base_y, bw * 0.3, COL_ACCENT);
        }
    }
    if show_note && !art draw_icon(.NOTE, x0 + side * 0.5, y0 + side * 0.40, side * 0.2, COL_TRACK);
}

// shuffle, previous, play/pause, next, repeat, centered on cx.
draw_transport :: (cx: float, cy: float, avail_w: float, play_r: float) {
    S := dpi_scale;
    sp := min(54 * S, (avail_w - 2 * play_r) / 4.6 + play_r * 0.3);
    box := 34 * S;
    if icon_btn(ID_SHUF, .SHUFFLE, cx - 2 * sp, cy, box, 18 * S, shuffle, ifx shuffle then "Shuffle: on (S)" else "Shuffle: off (S)", dot = true) { shuffle = !shuffle; mark_settings(); }
    if icon_btn(ID_PREV, .PREV, cx - sp, cy, box, 18 * S, false, "Previous (Ctrl+Left)") prev_track();

    c, hov, held := button(ID_PLAY, cx - play_r, cy - play_r, cx + play_r, cy + play_r);
    k := animate(ANIM_HOVER + ID_PLAY, ifx hov then 1.0 else 0.0, 18);
    pr := animate(ANIM_PRESS + ID_PLAY, ifx held then 1.0 else 0.0, 30);
    rr := play_r * (1 + 0.06 * k - 0.07 * pr);
    disc(cx, cy, rr, COL_TEXT);
    if audio_state == .PLAYING draw_icon(.PAUSE, cx, cy, play_r * 0.95, COL_BG);
    else draw_icon(.PLAY, cx + play_r * 0.06, cy, play_r * 0.95, COL_BG);
    if hover_time(ID_PLAY, hov) > 0.5 { tip_text = ifx audio_state == .PLAYING then "Pause (Space)" else "Play (Space)"; tip_x = cx; tip_y = cy - play_r; }
    if c toggle_play();

    if icon_btn(ID_NEXT, .NEXT, cx + sp, cy, box, 18 * S, false, "Next (Ctrl+Right)") next_track();
    if icon_btn(ID_REP, .REPEAT, cx + 2 * sp, cy, box, 18 * S, repeat_all, ifx repeat_all then "Repeat: on (R)" else "Repeat: off (R)", dot = true) { repeat_all = !repeat_all; mark_settings(); }
}

// elapsed time, progress bar, total time.
draw_seek :: (x0: float, x1: float, cy: float) {
    S := dpi_scale;
    have := audio_state == .PLAYING || audio_state == .PAUSED || audio_state == .ENDED;
    duration := audio_duration;
    time_w := 50 * S;
    sx0 := x0 + time_w + 6 * S;
    sx1 := x1 - time_w - 6 * S;

    pos := audio_position();
    frac := ifx have && duration > 0 then cast(float) (pos / duration) else 0.0;
    value, dragging, released := slider(ID_SEEK, sx0, cy - 10 * S, sx1, cy + 10 * S, frac);
    if !have || duration <= 0 { dragging = false; released = false; }
    if dragging { frac = value; pos = value * duration; }
    if released audio_seek(value * duration);
    shown := animate(ANIM_MISC + ID_SEEK_POS, frac, 40);
    if dragging shown = frac;

    pos_s := ifx audio_state == .LOADING then "…" else format_time(pos);
    text(pos_s, x0, cy, 12, COL_DIM);
    dur_s := ifx have && duration > 0 then format_time(duration) else "-:--";
    text(dur_s, x1 - text_width(dur_s, 12), cy, 12, COL_DIM);

    hover_seek := have && duration > 0 && (dragging || in_box(sx0 - 6 * S, cy - 10 * S, sx1 + 6 * S, cy + 10 * S));
    draw_bar(ID_SEEK, sx0, sx1, cy, shown, hover_seek);
    if audio_state == .LOADING {
        sh := fmod_cycling(anim_time * 0.9, 1.0);
        sxm := sx0 + (sx1 - sx0) * sh;
        rounded(max(sx0, sxm - 30 * S), cy - 2 * S, min(sx1, sxm + 30 * S), cy + 2 * S, 2 * S, with_alpha(COL_ACCENT, 0.7));
    }
    if hover_seek {
        tip_t := ifx dragging then pos else clamp((mx - sx0) / (sx1 - sx0), 0, 1) * duration;
        tip_text = format_time(tip_t);
        tip_x = clamp(mx, sx0, sx1);
        tip_y = cy - 8 * S;
    }
}

// mute button and volume slider.
draw_volume :: (x0: float, x1: float, cy: float) {
    S := dpi_scale;
    if icon_btn(ID_MUTE, ifx muted || volume <= 0 then Icon.MUTE else Icon.VOLUME, x0 + 15 * S, cy, 30 * S, 18 * S, false, ifx muted then "Unmute (M)" else "Mute (M)") { muted = !muted; apply_volume(); }
    vx0 := x0 + 38 * S;
    shown_v := ifx muted then 0.0 else volume;
    v, vdrag, vrel := slider(ID_VOL, vx0, cy - 10 * S, x1, cy + 10 * S, shown_v);
    if vdrag { volume = v; muted = false; apply_volume(); }
    if vrel mark_settings();
    shown_v = animate(ANIM_MISC + ID_VOL_POS, ifx muted then 0.0 else volume, 30);
    draw_bar(ID_VOL, vx0, x1, cy, shown_v, vdrag || in_box(vx0 - 6 * S, cy - 10 * S, x1 + 6 * S, cy + 10 * S));
}

// The color scheme button at `cx`, with the "default player" button to its left.
header_buttons :: (cx: float, cy: float) {
    S := dpi_scale;
    tip := tprint("Color scheme: % (click to change)", THEMES[theme_index].name);
    if icon_btn(ID_THEME_BTN, .PALETTE, cx, cy, 32 * S, 17 * S, false, tip, with_bg = true) {
        theme_index = (theme_index + 1) % THEMES.count;
        apply_theme();
        mark_settings();
    }
    if icon_btn(ID_DEFAULT_APP, .DEFAULT_APP, cx - 34 * S, cy, 32 * S, 17 * S, false, "Make Nickel your default music player", with_bg = true) {
        open_default_apps_settings();
    }
}

// The player: cover/spectrum, track info, progress, transport and volume. In wide windows it is a
// column on the right; in narrow ones it docks at the bottom as a compact strip.
draw_now_playing :: (x0: float, y0: float, x1: float, y1: float) {
    S := dpi_scale;
    panel(x0, y0, x1, y1);
    t := current_track();
    w := x1 - x0;
    h := y1 - y0;
    fade := animate(ANIM_MISC + ID_TITLE_FADE, 1, 5);

    if w > h * 1.25 {
        // Compact: cover on the left; title, transport, progress (and volume) on the right.
        pad := 14 * S;
        side := h - 2 * pad;
        draw_cover(x0 + pad, y0 + pad, side, !t, 7);
        rx0 := x0 + pad + side + 18 * S;
        rx1 := x1 - pad;
        rw := rx1 - rx0;

        title_cy := y0 + pad + 11 * S;
        if t {
            text(fit_text(t.title, rw - 76 * S, 15), rx0, title_cy, 15, with_alpha(COL_TEXT, fade));
            sub := ifx t.artist.count then t.artist else t.album;
            if sub.count text(fit_text(sub, rw - 76 * S, 12.5), rx0, title_cy + 21 * S, 12.5, with_alpha(COL_DIM, fade));
        } else {
            text("Nothing playing", rx0, title_cy, 15, COL_TEXT);
        }
        header_buttons(rx1 - 16 * S, title_cy);

        vol_w := ifx rw > 420 * S then 140 * S else 0.0;
        trans_cy := y0 + h - pad - 50 * S;
        draw_transport(rx0 + (rw - vol_w) * 0.5, trans_cy, rw - vol_w, 17 * S);
        if vol_w > 0 draw_volume(rx1 - vol_w + 10 * S, rx1, trans_cy);
        draw_seek(rx0, rx1, y0 + h - pad - 12 * S);
        return;
    }

    pad := 22 * S;
    cx := (x0 + x1) * 0.5;
    inner := w - 2 * pad;
    head_cy := y0 + 32 * S;
    text("Now playing", x0 + pad, head_cy, 13, COL_DIM);
    header_buttons(x1 - pad - 14 * S, head_cy);

    // Stack from the bottom up so the cover gets whatever room is left.
    vol_cy := y1 - pad - 14 * S;
    trans_cy := vol_cy - 14 * S - 14 * S - 24 * S;
    seek_cy := trans_cy - 24 * S - 14 * S - 12 * S;
    info_top := seek_cy - 12 * S - 22 * S - 66 * S;      // title, artist, album block
    cover_y0 := y0 + 58 * S;
    cover_y1 := info_top - 8 * S;
    side := min(inner, cover_y1 - cover_y0);
    if side >= 90 * S {
        draw_cover(cx - side * 0.5, cover_y0 + (cover_y1 - cover_y0 - side) * 0.5, side, !t, 28);
    }

    ty := info_top + 12 * S;
    if t {
        text_centered(fit_text(t.title, inner, 19), cx, ty, 19, with_alpha(COL_TEXT, fade));
        sub := t.artist;
        if !sub.count sub = "Unknown artist";
        text_centered(fit_text(sub, inner, 14), cx, ty + 27 * S, 14, with_alpha(COL_DIM, fade));
        if t.album.count text_centered(fit_text(t.album, inner, 12.5), cx, ty + 49 * S, 12.5, with_alpha(COL_DIM, fade));
    } else {
        text_centered("Nothing playing", cx, ty, 19, COL_TEXT);
        text_centered("Pick a track from the library", cx, ty + 27 * S, 14, COL_DIM);
    }

    draw_seek(x0 + pad, x1 - pad, seek_cy);
    draw_transport(cx, trans_cy, inner, 21 * S);
    vw := min(inner, 260 * S);
    draw_volume(cx - vw * 0.5, cx + vw * 0.5, vol_cy);
}

draw_search_box :: (x0: float, y0: float, x1: float, y1: float) {
    S := dpi_scale;
    cy := (y0 + y1) * 0.5;
    has_text := search_text.count > 0;
    clear_w := 30 * S;

    clicked, hovered, held := button(ID_SEARCH, x0, y0, ifx has_text then x1 - clear_w else x1, y1);
    if clicked search_focused = true;
    if mouse_pressed && !in_box(x0, y0, x1, y1) search_focused = false;

    rounded(x0, y0, x1, y1, radius(), COL_BG);
    outline(x0, y0, x1, y1, radius(), line_w(), ifx search_focused then COL_ACCENT else (ifx hovered then COL_TRACK else COL_BORDER));
    draw_icon(.SEARCH, x0 + 17 * S, cy, 15 * S, ifx search_focused then COL_ACCENT else COL_DIM);

    tx0 := x0 + 32 * S;
    tx1 := x1 - ifx has_text then clear_w else 10 * S;
    if has_text {
        q := search_query();
        qw := text_width(q, 13.5);
        off := max(0.0, qw - (tx1 - tx0));
        gfx_set_scissor(cast(s32) tx0, cast(s32) y0, cast(s32) tx1, cast(s32) y1);
        text(q, tx0 - off, cy, 13.5, COL_TEXT);
        if search_focused && fmod_cycling(anim_time * 1.6, 1.0) < 0.6 {
            fill(tx0 - off + qw + 1 * S, cy - 8 * S, tx0 - off + qw + 1 * S + line_w(), cy + 8 * S, COL_TEXT);
        }
        gfx_clear_scissor();
        if icon_btn(ID_SEARCH_CLR, .CLOSE, x1 - clear_w * 0.5, cy, 24 * S, 11 * S, false, "Clear search (Esc)") {
            search_text.count = 0; search_dirty = true; search_focused = false;
        }
    } else {
        text("Search music", tx0, cy, 13.5, COL_DIM);
        if search_focused && fmod_cycling(anim_time * 1.6, 1.0) < 0.6 {
            fill(tx0, cy - 8 * S, tx0 + line_w(), cy + 8 * S, COL_TEXT);
        }
    }
}

draw_playlist :: (x0: float, y0: float, x1: float, y1: float) {
    S := dpi_scale;
    panel(x0, y0, x1, y1);

    src := get_source(view_src);
    pad := 20 * S;
    w := x1 - x0;
    two_rows := w < 560 * S;
    head_h := (ifx two_rows then 108.0 else 70.0) * S;
    row1_cy := y0 + 35 * S;
    is_search := searching();

    // Icon buttons on the right of the first header row.
    box := 32 * S;
    bx := x1 - pad - box * 0.5;
    if icon_btn(ID_OPEN, .FOLDER, bx, row1_cy, box, 18 * S, false, "Open files (O)", with_bg = true) want_open_dialog = true;
    bx -= box + 4 * S;
    if src && src.kind == .OPENED {
        if icon_btn(ID_CLEAR, .TRASH, bx, row1_cy, box, 18 * S, false, "Clear this list", with_bg = true) clear_opened();
    } else {
        if icon_btn(ID_REFRESH, .REFRESH, bx, row1_cy, box, 18 * S, scan_job.running, "Rescan library (F5)", with_bg = true) want_rescan = true;
    }
    icons_left := bx - box * 0.5 - 10 * S;

    // Search box: beside the title when there's room, otherwise on its own row.
    title_right: float;
    if two_rows {
        draw_search_box(x0 + pad, y0 + 62 * S, x1 - pad, y0 + 94 * S);
        title_right = icons_left;
    } else {
        sw := clamp(w * 0.34, 150 * S, 290 * S);
        draw_search_box(icons_left - sw, row1_cy - 16 * S, icons_left, row1_cy + 16 * S);
        title_right = icons_left - sw - 14 * S;
    }

    title := ifx is_search then "Search" else (ifx src then src.name else "Library");
    count := ifx is_search then search_hits.count else (ifx src then src.tracks.count else 0);
    text(fit_text(title, title_right - x0 - pad, 19), x0 + pad, row1_cy - 9 * S, 19, COL_TEXT);
    sub: string;
    sub_col := COL_DIM;
    if status_text.count { sub = status_text; sub_col = COL_WARN; }
    else if scan_job.running && source_count() == 0 sub = "Scanning your Music folder…";
    else if is_search sub = tprint("% % for \"%\"", count, ifx count == 1 then "match" else "matches", search_query());
    else sub = tprint("% tracks", count);
    text(fit_text(sub, title_right - x0 - pad, 12.5), x0 + pad, row1_cy + 13 * S, 12.5, sub_col);

    vp_y0 := y0 + head_h;
    vp_y1 := y1 - 8 * S;
    vp_h  := vp_y1 - vp_y0;
    fill(x0 + pad, vp_y0 - 2 * S, x1 - pad, vp_y0 - 2 * S + line_w(), COL_BORDER);

    n := ifx is_search then search_hits.count else (ifx src then src.tracks.count else 0);
    if n == 0 {
        cy := vp_y0 + vp_h * 0.5;
        if is_search {
            text_centered("No matches", (x0 + x1) * 0.5, cy - 10 * S, 17, COL_TEXT);
            text_centered("Try fewer or different letters", (x0 + x1) * 0.5, cy + 16 * S, 13, COL_DIM);
        } else {
            text_centered(ifx scan_job.running then "Looking for music…" else "Nothing here yet", (x0 + x1) * 0.5, cy - 10 * S, 17, COL_TEXT);
            text_centered("Drop audio files or folders on this window", (x0 + x1) * 0.5, cy + 16 * S, 13, COL_DIM);
        }
        return;
    }

    row_h := 52 * S;
    content_h := row_h * n;
    max_scroll := max(0.0, content_h - vp_h);

    if in_box(x0, vp_y0, x1, vp_y1)  scroll_target -= wheel_accum * row_h * 2.0;
    if scroll_to_current && !is_search && play_src == view_src && current >= 0 {
        top := row_h * current;
        if top < scroll_target  scroll_target = top;
        else if top + row_h > scroll_target + vp_h  scroll_target = top + row_h - vp_h;
        scroll_to_current = false;
    }

    // Scrollbar thumb (drag).
    sb_w := 10 * S;
    if max_scroll > 0 {
        thumb_h := max(36 * S, vp_h * vp_h / content_h);
        track_range := vp_h - thumb_h;
        thumb_y := vp_y0 + (scroll_y / max_scroll) * track_range;
        clicked, hovered, held := button(ID_SCROLL, x1 - sb_w - 3 * S, thumb_y, x1 - 3 * S, thumb_y + thumb_h);
        if held {
            if mouse_pressed scroll_grab = my - thumb_y;
            frac := clamp((my - scroll_grab - vp_y0) / track_range, 0, 1);
            scroll_target = frac * max_scroll;
            scroll_y = scroll_target;
        }
    }
    scroll_target = clamp(scroll_target, 0, max_scroll);
    if abs(scroll_target - scroll_y) > 0.5 {
        scroll_y += (scroll_target - scroll_y) * (1 - exp(-18 * frame_dt));
        animating = true;
    } else {
        scroll_y = scroll_target;
    }

    gfx_set_scissor(cast(s32) x0, cast(s32) vp_y0, cast(s32) x1, cast(s32) vp_y1);
    first := max(0, cast(int) (scroll_y / row_h));
    right_edge := ifx max_scroll > 0 then x1 - sb_w - 6 * S else x1 - 8 * S;
    playing_now := audio_state == .PLAYING;

    for i: first..n-1 {
        ry := vp_y0 + row_h * i - scroll_y;
        if ry > vp_y1 break;

        row_src := view_src;
        row_idx := i;
        if is_search { row_src = search_hits[i].src; row_idx = search_hits[i].idx; }
        row_source := get_source(row_src);
        if !row_source || row_idx >= row_source.tracks.count continue;
        tr := *row_source.tracks[row_idx];

        rx0 := x0 + 8 * S;
        rx1 := right_edge;
        visible := my >= vp_y0 && my < vp_y1;
        clicked, hovered, held := button(ID_ROW + i, rx0, ry, rx1, ry + row_h);
        if !visible { clicked = false; hovered = false; }
        if clicked play_track(row_src, row_idx);

        is_cur := row_src == play_src && row_idx == current;
        hv  := animate(ANIM_ROW + i, ifx hovered then 1.0 else 0.0, 22);
        cur := animate(ANIM_ROW + 200000 + i, ifx is_cur then 1.0 else 0.0, 14);

        rounded(rx0, ry + S, rx1, ry + row_h - S, radius(), with_alpha(COL_HOVER, hv * (1 - cur)));
        if cur > 0.01 rounded(rx0, ry + S, rx1, ry + row_h - S, radius(), with_alpha(COL_ACCENT, 0.13 * cur));

        cy := ry + row_h * 0.5;
        nx := rx0 + 26 * S;
        if is_cur && playing_now {
            for b: 0..2 {
                hh := (0.30 + 0.70 * abs(sin(anim_time * (3.1 + b * 1.7) + b * 1.3))) * 14 * S;
                bxx := nx - 9 * S + b * 6.5 * S;
                rounded(bxx, cy + 7 * S - hh, bxx + 3.5 * S, cy + 7 * S, 1.2 * S, COL_ACCENT);
            }
        } else if is_cur {
            draw_icon(.PLAY, nx, cy, 14 * S, COL_ACCENT);
        } else if hovered {
            draw_icon(.PLAY, nx, cy, 14 * S, COL_TEXT);
        } else {
            text_centered(tprint("%", i + 1), nx, cy, 13, COL_DIM);
        }

        name_x := rx0 + 54 * S;
        badge_w := text_width(tr.ext, 10.5) + 16 * S;
        text_w := rx1 - name_x - badge_w - 24 * S;
        sub := ifx tr.artist.count then tr.artist else tr.album;
        if !sub.count && is_search sub = row_source.name;
        text(fit_text(tr.title, text_w, 14.5), name_x, ifx sub.count then cy - 8 * S else cy, 14.5, lerp4(COL_TEXT, COL_ACCENT, cur));
        if sub.count text(fit_text(sub, text_w, 12), name_x, cy + 10 * S, 12, COL_DIM);

        // Format badge.
        bx1 := rx1 - 16 * S;
        outline(bx1 - badge_w, cy - 9 * S, bx1, cy + 9 * S, radius() * 0.6, line_w(), COL_BORDER);
        text_centered(tr.ext, bx1 - badge_w * 0.5, cy, 10.5, COL_DIM);
    }
    gfx_clear_scissor();

    if max_scroll > 0 {
        thumb_h := max(36 * S, vp_h * vp_h / content_h);
        thumb_y := vp_y0 + (scroll_y / max_scroll) * (vp_h - thumb_h);
        sx := x1 - sb_w;
        act := animate(ANIM_MISC + ID_SCROLL_THUMB, ifx active_id == ID_SCROLL then 1.0 else 0.0, 16);
        rounded(sx, thumb_y + 2 * S, sx + 4 * S, thumb_y + thumb_h - 2 * S, 2 * S, lerp4(COL_TRACK, COL_ACCENT, act));
    }
}

main :: () {
    args := get_command_line_arguments();
    paths: [..] string;
    for args {
        if it_index == 0 continue;
        if it == "--unregister" { unregister_file_types(); return; }
        array_add(*paths, it);
    }
    if forward_to_running_instance(paths) return;

    w_SetProcessDpiAwarenessContext(cast(*void) cast(s64) -4);  // per-monitor v2
    timeBeginPeriod(1);
    w_CoInitializeEx(null, 2);   // apartment-threaded: needed for the folder picker dialog

    load_settings();
    apply_theme();

    if !create_main_window() {
        log_error("Could not create the window.\n");
        exit(1);
    }

    if !gfx_init(main_hwnd, win_w, win_h) {
        log_error("Could not initialize Direct3D 11.\n");
        exit(1);
    }
    fp := tprint("%/%", font_dir, font_file);
    if !file_exists(fp) font_file = "arial.ttf";
    if !gfx_load_font(tprint("%/%", font_dir, font_file)) {
        log_error("Could not load font.\n");
        exit(1);
    }
    app_context = context;
    app_context_ready = true;
    gfx_ready = true;

    ns, ok := to_nanoseconds(current_time_monotonic());
    random_seed(cast(u64) ns);

    audio_start();
    art_start();
    apply_volume();
    want_rescan = true;
    last_scan_time = seconds_since_init();

    w_ShowWindow(main_hwnd, 5);

    register_file_types();
    for paths array_add(*shell_opened, copy_string(it));

    msg: MSG;
    while !quit {
        while w_PeekMessageW(*msg, null, 0, 0, 1) {
            if msg.message == K_WM_QUIT { quit = true; break; }
            w_TranslateMessage(*msg);
            w_DispatchMessageW(*msg);
        }
        if quit break;

        if want_open_dialog {
            want_open_dialog = false;
            open_file_dialog();
        }
        if want_add_folder {
            want_add_folder = false;
            f := pick_folder();
            if f.count { add_custom_folder(f); free_str(f); }
        }

        if settings_dirty && seconds_since_init() - settings_changed_at > 1.0 save_settings();

        tick();
        if dirty || animating {
            frame();
            w_MsgWaitForMultipleObjects(0, null, 0, 1, 0x4FF);    // QS_ALLINPUT
        } else {
            w_MsgWaitForMultipleObjects(0, null, 0, 100, 0x4FF);
        }
    }

    save_settings();
    audio_stop();
    audio_stop_thread();
    art_stop();
}
