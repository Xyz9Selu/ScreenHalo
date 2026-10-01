#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; FocusScreen - marks the monitor that owns the foreground window with a thin
; edge indicator, and optionally marks the other monitors with a subtler one.
; One click-through overlay per monitor, event driven (no polling).
; Settings are changed from the tray menu and stored in FocusScreen.ini.

; ---------------------------------------------------------------- Config
DEBUG := false            ; true = log to FocusScreen.log + OutputDebug
IniFile := EnvGet("FOCUSSCREEN_INI") || A_ScriptDir "\FocusScreen.ini"   ; env override: tools/capture-screenshots.ps1

; Defaults; overridden by FocusScreen.ini.  style: off | border | top
; The focused screen is the work screen: keep it calm (the pulse on focus change does
; the attention-grabbing). The other screens are auxiliary: make them easier to notice.
Defaults := Map(
    "focus", Map("style", "glow", "edges", "TBLR", "width", 4, "opacity", 70, "color", "FF9100", "pulse", 1),
    "other", Map("style", "glow", "edges", "TBLR", "width", 6, "opacity", 85, "color", "8A8A8A"),
)
Presets := Map(   ; name -> [focus width, focus opacity, other width, other opacity]
    "Subtle",   [3, 50, 4, 60],
    "Standard", [4, 70, 6, 85],
    "Strong",   [6, 90, 10, 100],
)
PulseDurationMs := 450
PulseExtraWidth := 8      ; extra 96-dpi pixels at the start of the pulse
ColorPresets := Map(
    "Orange", "FF9100", "Cyan", "00B8D4", "Magenta", "E040FB", "Green", "00E676",
    "Red", "FF5252", "White", "FFFFFF", "Gray", "8A8A8A",
)
; "Width" is the stroke width for line styles and the fade depth for glow/vignette.
; Edges: any of T B L R, or AUTO (other screens only: the edge facing the focused screen).
StyleChoices := ["glow", "vignette", "border", "double", "dashed", "corners", "off"]
LegacyEdges := Map("top", "T", "bottom", "B", "left", "L", "right", "R", "sides", "LR")   ; old styles
WidthChoices   := [1, 2, 3, 4, 6, 8, 10, 12]      ; in 96-dpi pixels, scaled per monitor
OpacityChoices := [15, 20, 30, 40, 50, 60, 80, 100]   ; percent

; ---------------------------------------------------------------- Win32 constants
DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 := -4
EVENT_SYSTEM_FOREGROUND  := 0x0003
EVENT_SYSTEM_MOVESIZEEND := 0x000B
WINEVENT_OUTOFCONTEXT    := 0x0000
WINEVENT_SKIPOWNPROCESS  := 0x0002
MONITOR_DEFAULTTONEAREST := 2
MDT_EFFECTIVE_DPI        := 0
WS_EX_NOACTIVATE         := 0x08000000
WS_EX_TRANSPARENT        := 0x00000020
HWND_TOPMOST             := -1
SWP_NOACTIVATE           := 0x0010
SWP_SHOWWINDOW           := 0x0040
SWP_NOOWNERZORDER        := 0x0200
SW_HIDE                  := 0
RGN_OR                   := 2
GWL_EXSTYLE              := -20
WS_EX_LAYERED            := 0x00080000
ULW_ALPHA                := 2
AC_SRC_ALPHA             := 1
WM_DISPLAYCHANGE         := 0x007E
WM_DPICHANGED            := 0x02E0

; Windows that take the foreground transiently (Alt+Tab UI etc.) and would
; make the indicator jump to the primary monitor.
IgnoredClasses := Map(
    "XamlExplorerHostIslandWindow", 1,
    "MultitaskingViewFrame", 1,
    "ForegroundStaging", 1,
    "TaskSwitcherWnd", 1,
    "TaskSwitcherOverlayWnd", 1,
    "Windows.UI.Core.CoreWindow", 1,
    "#32768", 1,                       ; popup/context menus (including our tray menu)
)

; ---------------------------------------------------------------- State
class State {
    static settings := Map()     ; role -> Map(style,width,opacity,color)
    static enabled := true
    static overlays := Map()     ; HMONITOR -> Overlay
    static focusMon := 0         ; HMONITOR owning the foreground window
    static hooks := []
    static callback := 0         ; CallbackCreate pointer (kept alive here)
    static pulse := 0            ; running pulse: {hMon, t0}
}

; One overlay window per monitor. Line styles are a window region over a solid
; colour (SetLayeredWindowAttributes); glow/vignette are a per-pixel-alpha bitmap
; (UpdateLayeredWindow) with the opacity applied as a constant alpha.
class Overlay {
    __New(hMon) {
        this.hMon := hMon
        this.sig := ""           ; geometry/look last drawn
        this.alpha := -1         ; last constant alpha (pixel mode)
        this.shown := false
        this.mode := "attr"      ; "attr" | "pixel"
        this.dc := 0, this.bmp := 0, this.oldBmp := 0, this.bits := 0
        this.x := 0, this.y := 0, this.w := 0, this.h := 0
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +E" WS_EX_NOACTIVATE " +E" WS_EX_TRANSPARENT, "FocusScreenOverlay")
        g.Show("NoActivate Hide w100 h100")
        this.gui := g
        this.hwnd := g.Hwnd
        WinSetTransparent(255, this.hwnd)    ; adds WS_EX_LAYERED
    }

    Apply(s, rect, dpi, quiet := false) {
        style := s["style"]
        if (style = "off")
            return this.Hide()
        x := rect.l, y := rect.t, w := rect.r - rect.l, h := rect.b - rect.t
        bw := Min(Max(1, Round(s["width"] * dpi / 96)), Min(w, h) // 2)
        changed := IsPixelStyle(style) ? this.ApplyPixel(s, x, y, w, h, bw) : this.ApplyLine(s, x, y, w, h, bw)
        if (changed && !quiet)
            Log("overlay monitor=" Format("0x{:X}", this.hMon) " rect=" x "," y "," x + w "," y + h
                " dpi=" Round(dpi * 100 / 96) "% style=" style)
    }

    ApplyLine(s, x, y, w, h, bw) {
        sig := x "," y "," w "," h "|" bw "|" s["style"] "|" s["edges"] "|" Round(s["opacity"]) "|" s["color"]
        if (sig = this.sig && this.shown)
            return false
        this.SetMode("attr")
        this.FreeBitmap()
        this.sig := sig
        this.gui.BackColor := s["color"]
        WinSetTransparent(Round(s["opacity"] * 255 / 100), this.hwnd)
        this.Place(x, y, w, h)
        ApplyRegion(this.hwnd, w, h, bw, s["style"], s["edges"])
        return true
    }

    ApplyPixel(s, x, y, w, h, bw) {
        geom := x "," y "," w "," h "|" bw "|" s["style"] "|" s["edges"] "|" s["color"]
        alpha := Round(s["opacity"] * 255 / 100)
        if (geom = this.sig && this.shown) {     ; only the opacity changed (e.g. pulse): cheap
            if (alpha = this.alpha)
                return false
            this.PushBitmap(alpha)
            return true
        }
        this.SetMode("pixel")
        this.sig := geom
        this.BuildBitmap(w, h, bw, s["style"], s["color"], s["edges"])
        DllCall("User32\SetWindowRgn", "ptr", this.hwnd, "ptr", 0, "int", true)
        this.Place(x, y, w, h)
        this.PushBitmap(alpha)
        return true
    }

    Place(x, y, w, h) {
        this.x := x, this.y := y, this.w := w, this.h := h
        flags := SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOOWNERZORDER
        ; First call moves onto the target monitor (may cross a DPI boundary),
        ; the second guarantees the final size.
        loop 2
            DllCall("User32\SetWindowPos", "ptr", this.hwnd, "ptr", HWND_TOPMOST
                , "int", x, "int", y, "int", w, "int", h, "uint", flags)
        this.shown := true
    }

    ; SetLayeredWindowAttributes and UpdateLayeredWindow exclude each other until
    ; the layered bit is cleared and set again.
    SetMode(mode) {
        if (this.mode = mode)
            return
        ex := DllCall("User32\GetWindowLongPtrW", "ptr", this.hwnd, "int", GWL_EXSTYLE, "ptr")
        DllCall("User32\SetWindowLongPtrW", "ptr", this.hwnd, "int", GWL_EXSTYLE, "ptr", ex & ~WS_EX_LAYERED, "ptr")
        DllCall("User32\SetWindowLongPtrW", "ptr", this.hwnd, "int", GWL_EXSTYLE, "ptr", ex | WS_EX_LAYERED, "ptr")
        this.mode := mode
    }

    ; Premultiplied-ARGB bitmap whose alpha falls off with the distance to the
    ; nearest selected edge. Built per row from two small profile templates, so it
    ; costs a few thousand memory copies rather than a per-pixel loop.
    BuildBitmap(w, h, bw, style, color, edges) {
        t0 := A_TickCount
        this.FreeBitmap()
        glow := (style = "glow")
        D := Max(1, Min(bw * (glow ? 4 : 20), Min(w, h) // 2))     ; fade depth in px
        expo := glow ? 2 : 1.6
        peak := glow ? 1.0 : 0.7
        rgb := Integer("0x" color)
        r := (rgb >> 16) & 0xFF, g := (rgb >> 8) & 0xFF, b := rgb & 0xFF
        tSel := InStr(edges, "T"), bSel := InStr(edges, "B"), lSel := InStr(edges, "L"), rSel := InStr(edges, "R")

        vals := [], lp := Buffer(D * 4), rp := Buffer(D * 4)
        loop D {
            i := A_Index - 1
            a := Round(255 * (1 - i / D) ** expo * peak)
            dw := (a << 24) | ((r * a // 255) << 16) | ((g * a // 255) << 8) | (b * a // 255)
            vals.Push(dw)
            NumPut("uint", dw, lp, i * 4)
            NumPut("uint", dw, rp, (D - 1 - i) * 4)
        }

        dc := DllCall("Gdi32\CreateCompatibleDC", "ptr", 0, "ptr")
        bmi := Buffer(40, 0)
        NumPut("uint", 40, "int", w, "int", -h, "ushort", 1, "ushort", 32, bmi)   ; top-down 32bpp
        bits := 0
        bmp := DllCall("Gdi32\CreateDIBSection", "ptr", dc, "ptr", bmi, "uint", 0, "ptr*", &bits, "ptr", 0, "uint", 0, "ptr")
        this.oldBmp := DllCall("Gdi32\SelectObject", "ptr", dc, "ptr", bmp, "ptr")
        this.dc := dc, this.bmp := bmp, this.bits := bits

        rowBytes := w * 4
        loop h {
            ry := A_Index - 1
            rowD := D                    ; distance to the nearest selected top/bottom edge (capped)
            if tSel
                rowD := Min(rowD, ry)
            if bSel
                rowD := Min(rowD, h - 1 - ry)
            base := bits + ry * rowBytes
            lenL := lSel ? rowD : 0      ; pixels whose nearest selected edge is the left/right one
            lenR := rSel ? rowD : 0
            if lenL
                DllCall("ntdll\RtlMoveMemory", "ptr", base, "ptr", lp.Ptr, "uptr", lenL * 4)
            if lenR
                DllCall("ntdll\RtlMoveMemory", "ptr", base + (w - lenR) * 4, "ptr", rp.Ptr + (D - lenR) * 4, "uptr", lenR * 4)
            if (rowD < D)
                FillDwords(base + lenL * 4, w - lenL - lenR, vals[rowD + 1])
        }
        Log("bitmap " w "x" h " depth=" D "px edges=" edges " built in " A_TickCount - t0 " ms")
    }

    PushBitmap(alpha) {
        pt := Buffer(8), sz := Buffer(8), src := Buffer(8, 0), bf := Buffer(4)
        NumPut("int", this.x, "int", this.y, pt)
        NumPut("int", this.w, "int", this.h, sz)
        NumPut("uchar", 0, "uchar", 0, "uchar", alpha, "uchar", AC_SRC_ALPHA, bf)   ; AC_SRC_OVER
        ok := DllCall("User32\UpdateLayeredWindow", "ptr", this.hwnd, "ptr", 0, "ptr", pt, "ptr", sz
            , "ptr", this.dc, "ptr", src, "uint", 0, "ptr", bf, "uint", ULW_ALPHA, "int")
        if !ok
            Log("UpdateLayeredWindow failed, error " A_LastError)
        this.alpha := alpha
    }

    FreeBitmap() {
        if !this.dc
            return
        DllCall("Gdi32\SelectObject", "ptr", this.dc, "ptr", this.oldBmp)
        DllCall("Gdi32\DeleteObject", "ptr", this.bmp)
        DllCall("Gdi32\DeleteDC", "ptr", this.dc)
        this.dc := 0, this.bmp := 0, this.bits := 0
    }

    Hide() {
        if this.shown
            DllCall("User32\ShowWindow", "ptr", this.hwnd, "int", SW_HIDE)
        this.shown := false
        this.sig := ""
        this.alpha := -1
        this.FreeBitmap()
    }

    Destroy() {
        this.FreeBitmap()
        this.gui.Destroy()
    }
}

IsPixelStyle(style) => (style = "glow" || style = "vignette")

; Fill `count` dwords at `ptr` with `value` by doubling memcpy (log2(count) calls).
FillDwords(ptr, count, value) {
    if (count <= 0)
        return
    NumPut("uint", value, ptr)
    done := 1
    while (done < count) {
        n := Min(done, count - done)
        DllCall("ntdll\RtlMoveMemory", "ptr", ptr + done * 4, "ptr", ptr, "uptr", n * 4)
        done += n
    }
}

LoadSettings()
InitializeDpiAwareness()
InstallForegroundHook()
OnMessage(WM_DISPLAYCHANGE, OnDisplayChange)
OnMessage(WM_DPICHANGED, (*) => 0)   ; we size overlays ourselves; suppress the auto-resize
OnExit(Cleanup)
BuildTrayMenu()
RebuildOverlays()
return

; ---------------------------------------------------------------- Init
InitializeDpiAwareness() {
    ; Must run before any window exists. The process-level call fails with
    ; ACCESS_DENIED when AHK's manifest already fixed the awareness, so fall
    ; back to the thread level (this script only has the one thread).
    ok := DllCall("User32\SetProcessDpiAwarenessContext", "ptr", DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, "int")
    err := A_LastError
    if !ok
        DllCall("User32\SetThreadDpiAwarenessContext", "ptr", DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, "ptr")
    ctx := DllCall("User32\GetThreadDpiAwarenessContext", "ptr")
    isV2 := DllCall("User32\AreDpiAwarenessContextsEqual", "ptr", ctx, "ptr", DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, "int")
    Log("dpiAwareness processSet=" ok " (err=" err ") threadPerMonitorV2=" isV2)
}

InstallForegroundHook() {
    State.callback := CallbackCreate(WinEventProc, "F", 7)
    flags := WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS
    for ev in [EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_MOVESIZEEND] {
        h := DllCall("User32\SetWinEventHook", "uint", ev, "uint", ev, "ptr", 0
            , "ptr", State.callback, "uint", 0, "uint", 0, "uint", flags, "ptr")
        if h
            State.hooks.Push(h)
        else
            Log("SetWinEventHook failed for event " ev)
    }
}

; ---------------------------------------------------------------- Events
WinEventProc(hHook, event, hwnd, idObject, idChild, thread, time) {
    ; Keep this tiny; real work happens outside the hook callback.
    if (idObject != 0)           ; OBJID_WINDOW only
        return
    SetTimer(UpdateFocusMonitor, -1)
}

OnDisplayChange(*) {
    ; Debounce: a reconfiguration sends several messages.
    SetTimer(RebuildOverlays, -300)
}

; ---------------------------------------------------------------- Core
; Display configuration changed (or startup): recreate one overlay per monitor.
RebuildOverlays() {
    Critical                     ; drawing must not be interrupted by another focus/menu thread
    InPerMonitorDpi(RebuildOverlaysCore)
}

RebuildOverlaysCore() {
    for , ov in State.overlays
        ov.Destroy()
    State.overlays := Map()
    for m in EnumMonitors()
        State.overlays[m.h] := Overlay(m.h)
    State.focusMon := 0
    UpdateFocusMonitor(true)
}

; Foreground window changed: find its monitor and restyle the overlays.
UpdateFocusMonitor(force := false) {
    hwnd := DllCall("User32\GetForegroundWindow", "ptr")
    if (hwnd && !IsIgnored(hwnd)) {
        hMon := DllCall("User32\MonitorFromWindow", "ptr", hwnd, "uint", MONITOR_DEFAULTTONEAREST, "ptr")
        if (hMon && hMon != State.focusMon) {
            Log("hwnd=" Format("0x{:X}", hwnd) " monitor=" Format("0x{:X}", hMon))
            hadFocus := State.focusMon != 0
            State.focusMon := hMon
            ApplyAll()
            if hadFocus
                StartPulse(hMon)
            return
        }
    }
    if force
        ApplyAll()
}

; Brief thicker/brighter flash on the newly focused monitor, easing back to the
; steady style. Motion is what peripheral vision notices; a timer runs only
; while the pulse is in progress.
StartPulse(hMon) {
    if (!State.enabled || !State.settings["focus"]["pulse"] || State.settings["focus"]["style"] = "off")
        return
    State.pulse := {hMon: hMon, t0: A_TickCount}
    SetTimer(PulseStep, 16)
}

PulseStep() {
    Critical
    InPerMonitorDpi(PulseStepCore)
}

PulseStepCore() {
    p := State.pulse
    if !p || !State.overlays.Has(p.hMon) {
        SetTimer(PulseStep, 0)
        return
    }
    t := (A_TickCount - p.t0) / PulseDurationMs
    base := State.settings["focus"]
    if (t >= 1) {
        SetTimer(PulseStep, 0)
        State.pulse := 0
        k := 0
    } else
        k := (1 - t) ** 2        ; ease-out
    s := base.Clone()
    if !IsPixelStyle(base["style"])      ; glow/vignette pulse by brightness only
        s["width"] := base["width"] + PulseExtraWidth * k
    s["opacity"] := base["opacity"] + (100 - base["opacity"]) * k
    for m in EnumMonitors()
        if (m.h = p.hMon)
            State.overlays[m.h].Apply(s, m, GetMonitorDpi(m.h), true)
}

; Style every overlay according to its role (focused / other / hidden).
ApplyAll() {
    Critical                     ; building a bitmap takes long enough for AHK to interrupt it
    InPerMonitorDpi(ApplyAllCore)
}

ApplyAllCore() {
    SetTimer(PulseStep, 0)
    State.pulse := 0
    mons := EnumMonitors()
    if (!State.enabled || mons.Length <= 1) {   ; nothing to disambiguate on one screen
        for , ov in State.overlays
            ov.Hide()
        return
    }
    focusRect := 0
    for m in mons
        if (m.h = State.focusMon)
            focusRect := m
    for m in mons {
        if !State.overlays.Has(m.h)
            continue
        role := (m.h = State.focusMon) ? "focus" : "other"
        st := State.settings[role]
        if (st["edges"] = "AUTO") {              ; the edge that faces the focused screen
            st := st.Clone()
            st["edges"] := focusRect ? FacingEdge(m, focusRect) : "TBLR"
        }
        State.overlays[m.h].Apply(st, m, GetMonitorDpi(m.h))
    }
}

; Which edge of monitor m faces monitor f (by virtual-desktop layout).
FacingEdge(m, f) {
    if (m.r <= f.l)
        return "R"
    if (f.r <= m.l)
        return "L"
    if (m.b <= f.t)
        return "B"
    if (f.b <= m.t)
        return "T"
    return "TBLR"                                ; overlapping monitors: no clear side
}

; Monitor rectangles and SetWindowPos coordinates depend on the calling thread's DPI
; awareness context, and Windows swaps that context while it dispatches messages of
; other windows (e.g. the tray menu). Without this, callbacks that run from the menu
; saw a DPI-virtualized layout and sized the overlays wrongly (spilling off-screen).
InPerMonitorDpi(fn) {
    prev := DllCall("User32\SetThreadDpiAwarenessContext", "ptr", DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, "ptr")
    try fn()
    finally DllCall("User32\SetThreadDpiAwarenessContext", "ptr", prev, "ptr")
}

IsIgnored(hwnd) {
    try cls := WinGetClass(hwnd)
    catch
        return true              ; window vanished
    if IgnoredClasses.Has(cls)
        return true
    ; Never treat our own windows (overlays, tray menu owner) as the foreground.
    try pid := WinGetPID(hwnd)
    catch
        return true
    return pid = DllCall("Kernel32\GetCurrentProcessId", "uint")
}

; Returns [{h, l, t, r, b}, ...] using rcMonitor (physical pixels, virtual-desktop coords).
EnumMonitors() {
    list := []
    cb := CallbackCreate(EnumProc, "F", 4)
    EnumProc(hMon, hdc, lprc, lparam) {
        mi := Buffer(40, 0)
        NumPut("uint", 40, mi, 0)
        if DllCall("User32\GetMonitorInfoW", "ptr", hMon, "ptr", mi)
            list.Push({h: hMon, l: NumGet(mi, 4, "int"), t: NumGet(mi, 8, "int")
                     , r: NumGet(mi, 12, "int"), b: NumGet(mi, 16, "int")})
        return 1
    }
    DllCall("User32\EnumDisplayMonitors", "ptr", 0, "ptr", 0, "ptr", cb, "ptr", 0)
    CallbackFree(cb)
    return list
}

GetMonitorDpi(hMon) {
    dx := 0, dy := 0
    hr := DllCall("Shcore\GetDpiForMonitor", "ptr", hMon, "int", MDT_EFFECTIVE_DPI, "uint*", &dx, "uint*", &dy, "int")
    return (hr = 0 && dx) ? dx : 96
}

ApplyRegion(hwnd, w, h, bw, style, edges) {
    ; Window-relative physical pixels. Only the drawn parts are in the region, so
    ; everything else neither draws nor hit-tests.
    T := InStr(edges, "T"), B := InStr(edges, "B"), L := InStr(edges, "L"), R := InStr(edges, "R")
    region := DllCall("Gdi32\CreateRectRgn", "int", 0, "int", 0, "int", 0, "int", 0, "ptr")
    add := (l, t, r, b) => AddRect(region, l, t, r, b)
    ; Solid bars on the selected edges, o px in from the monitor edge.
    bars := (o, n) => (T ? add(L ? o : 0, o, R ? w - o : w, o + n) : 0
                     , B ? add(L ? o : 0, h - o - n, R ? w - o : w, h - o) : 0
                     , L ? add(o, T ? o : 0, o + n, B ? h - o : h) : 0
                     , R ? add(w - o - n, T ? o : 0, w - o, B ? h - o : h) : 0)
    switch style {
    case "double":
        bars(0, bw), bars(Min(2 * bw, Min(w, h) // 2 - 1), bw)
    case "corners":
        arm := Max(4 * bw, Round(Min(w, h) * 0.08))
        for cx in [0, 1]
            for cy in [0, 1] {
                if (cy ? B : T) {                                    ; horizontal arm
                    x0 := cx ? w - arm : 0, y0 := cy ? h - bw : 0
                    add(x0, y0, x0 + arm, y0 + bw)
                }
                if (cx ? R : L) {                                    ; vertical arm
                    x1 := cx ? w - bw : 0, y1 := cy ? h - arm : 0
                    add(x1, y1, x1 + bw, y1 + arm)
                }
            }
    case "dashed":
        dash := bw * 6, gap := bw * 4
        x := 0
        while (x < w) {
            e := Min(x + dash, w)
            if T
                add(x, 0, e, bw)
            if B
                add(x, h - bw, e, h)
            x += dash + gap
        }
        y := 0
        while (y < h) {
            e := Min(y + dash, h)
            if L
                add(0, y, bw, e)
            if R
                add(w - bw, y, w, e)
            y += dash + gap
        }
    default: bars(0, bw)                                             ; "border"
    }
    ; The system owns the region after this call; do not delete it.
    DllCall("User32\SetWindowRgn", "ptr", hwnd, "ptr", region, "int", true)
}

AddRect(region, l, t, r, b) {
    tmp := DllCall("Gdi32\CreateRectRgn", "int", l, "int", t, "int", r, "int", b, "ptr")
    DllCall("Gdi32\CombineRgn", "ptr", region, "ptr", region, "ptr", tmp, "int", RGN_OR)
    DllCall("Gdi32\DeleteObject", "ptr", tmp)
}

; ---------------------------------------------------------------- Settings
LoadSettings() {
    for role, def in Defaults {
        s := Map()
        for key, val in def {
            v := IniRead(IniFile, role, key, val)
            s[key] := IsInteger(val) ? (IsInteger(v) ? Integer(v) : val) : v
        }
        if !RegExMatch(s["color"], "^[0-9A-Fa-f]{6}$")
            s["color"] := def["color"]
        if LegacyEdges.Has(s["style"]) {         ; old "top"/"sides"/... styles became style + edges
            s["edges"] := LegacyEdges[s["style"]]
            s["style"] := "border"
        }
        if !HasValue(StyleChoices, s["style"])
            s["style"] := def["style"]
        s["edges"] := StrUpper(s["edges"])
        if !RegExMatch(s["edges"], "^(AUTO|[TBLR]{1,4})$") || (role = "focus" && s["edges"] = "AUTO")
            s["edges"] := def["edges"]
        State.settings[role] := s
    }
    State.enabled := IniRead(IniFile, "general", "enabled", 1) != 0
}

SaveSettings() {
    for role, s in State.settings
        for key, val in s
            IniWrite(val, IniFile, role, key)
    IniWrite(State.enabled ? 1 : 0, IniFile, "general", "enabled")
}

SetOption(role, key, val, *) {
    State.settings[role][key] := val
    SaveSettings()
    BuildTrayMenu()
    ApplyAll()
}

HasValue(arr, val) {
    for v in arr
        if (v = val)
            return true
    return false
}

; Closure factory: AHK closures share loop variables, so bind values explicitly.
OptionHandler(role, key, val) => SetOption.Bind(role, key, val)

ApplyPreset(name, *) {
    v := Presets[name]
    State.settings["focus"]["width"] := v[1], State.settings["focus"]["opacity"] := v[2]
    State.settings["other"]["width"] := v[3], State.settings["other"]["opacity"] := v[4]
    SaveSettings()
    BuildTrayMenu()
    ApplyAll()
}

TogglePulse(*) {
    SetOption("focus", "pulse", State.settings["focus"]["pulse"] ? 0 : 1)
}

; Toggle one edge letter; at least one edge always stays selected.
EdgeToggle(role, letter, *) {
    cur := State.settings[role]["edges"]
    if (cur = "AUTO")
        cur := ""
    new := ""
    for c in StrSplit("TBLR")
        if ((c = letter) != InStr(cur, c) > 0)   ; flip the toggled letter, keep the rest
            new .= c
    if (new != "")
        SetOption(role, "edges", new)
}

ToggleEnabled(*) {
    State.enabled := !State.enabled
    SaveSettings()
    BuildTrayMenu()
    ApplyAll()
}

ToggleStartup(*) {
    lnk := A_Startup "\FocusScreen.lnk"
    if FileExist(lnk)
        FileDelete(lnk)
    else
        FileCreateShortcut(A_AhkPath, lnk, A_ScriptDir, '"' A_ScriptFullPath '"', "FocusScreen")
    BuildTrayMenu()
}

; ---------------------------------------------------------------- Tray menu
BuildTrayMenu() {
    tray := A_TrayMenu
    tray.Delete()
    A_IconTip := "FocusScreen"
    tray.Add("Enabled", ToggleEnabled)
    if State.enabled
        tray.Check("Enabled")
    tray.Add()
    presetMenu := Menu()
    for name in Presets
        presetMenu.Add(name, ApplyPreset.Bind(name))
    tray.Add("Preset", presetMenu)
    tray.Add("Focused screen", BuildRoleMenu("focus"))
    tray.Add("Other screens", BuildRoleMenu("other"))
    tray.Add()
    tray.Add("Start with Windows", ToggleStartup)
    if FileExist(A_Startup "\FocusScreen.lnk")
        tray.Check("Start with Windows")
    tray.Add("Reload", (*) => Reload())
    tray.Add("Exit", (*) => ExitApp())
}

BuildRoleMenu(role) {
    s := State.settings[role]
    m := Menu()

    sub := Menu()
    for st in StyleChoices {
        label := (st = "border") ? "Solid" : StrTitle(st)
        sub.Add(label, OptionHandler(role, "style", st))
        if (s["style"] = st)
            sub.Check(label)
    }
    m.Add("Style", sub)

    sub := Menu()
    if (role = "other") {
        sub.Add("Facing focused screen", OptionHandler(role, "edges", "AUTO"))
        if (s["edges"] = "AUTO")
            sub.Check("Facing focused screen")
        sub.Add()
    }
    for e in [["Top", "T"], ["Bottom", "B"], ["Left", "L"], ["Right", "R"]] {
        sub.Add(e[1], EdgeToggle.Bind(role, e[2]))
        if (s["edges"] != "AUTO" && InStr(s["edges"], e[2]))
            sub.Check(e[1])
    }
    sub.Add()
    sub.Add("All edges", OptionHandler(role, "edges", "TBLR"))
    m.Add("Edges", sub)

    sub := Menu()
    for wd in WidthChoices {
        sub.Add(wd " px", OptionHandler(role, "width", wd))
        if (s["width"] = wd)
            sub.Check(wd " px")
    }
    m.Add("Width", sub)

    sub := Menu()
    for op in OpacityChoices {
        sub.Add(op "%", OptionHandler(role, "opacity", op))
        if (s["opacity"] = op)
            sub.Check(op "%")
    }
    m.Add("Opacity", sub)

    sub := Menu()
    for name, hex in ColorPresets {
        sub.Add(name, OptionHandler(role, "color", hex))
        if (StrUpper(s["color"]) = hex)
            sub.Check(name)
    }
    m.Add("Color", sub)

    if (role = "focus") {
        m.Add("Pulse on focus change", TogglePulse)
        if s["pulse"]
            m.Check("Pulse on focus change")
    }
    return m
}

; ---------------------------------------------------------------- Cleanup
Cleanup(*) {
    for h in State.hooks
        DllCall("User32\UnhookWinEvent", "ptr", h)
    State.hooks := []
    if State.callback {
        CallbackFree(State.callback)
        State.callback := 0
    }
    for , ov in State.overlays
        ov.Destroy()
}

Log(msg) {
    if !DEBUG
        return
    line := FormatTime(, "HH:mm:ss") " [FocusScreen] " msg
    OutputDebug(line)
    try FileAppend(line "`n", A_ScriptDir "\FocusScreen.log")
}
