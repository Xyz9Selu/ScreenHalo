#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; FocusScreen - shows a thin edge indicator on the monitor that owns the
; foreground window. One overlay, event driven (no polling).

; ---------------------------------------------------------------- Config
BorderColor := "FFD54F"   ; RRGGBB
BorderWidth := 4          ; in DIPs (96-dpi pixels); scaled by the monitor's DPI
Opacity     := 160        ; 0-255
Mode        := "border"   ; "border" | "top"
UseWorkArea := false      ; false = whole monitor (rcMonitor)
HideOnSingleMonitor := true  ; no indicator when only one monitor is attached
DEBUG       := false      ; true = log to FocusScreen.log + OutputDebug

; ---------------------------------------------------------------- Win32 constants
DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 := -4
EVENT_SYSTEM_FOREGROUND  := 0x0003
EVENT_SYSTEM_MOVESIZEEND := 0x000B
WINEVENT_OUTOFCONTEXT    := 0x0000
WINEVENT_SKIPOWNPROCESS  := 0x0002
MONITOR_DEFAULTTONEAREST := 2
SM_CMONITORS             := 80
SW_HIDE                  := 0
MDT_EFFECTIVE_DPI        := 0
WS_EX_NOACTIVATE         := 0x08000000
WS_EX_TRANSPARENT        := 0x00000020
HWND_TOPMOST             := -1
SWP_NOACTIVATE           := 0x0010
SWP_SHOWWINDOW           := 0x0040
SWP_NOOWNERZORDER        := 0x0200
RGN_DIFF                 := 4
RGN_OR                   := 2
WM_DISPLAYCHANGE         := 0x007E
WM_DPICHANGED            := 0x02E0

; Windows that take the foreground transiently (Alt+Tab UI etc.) and would
; make the overlay flicker over to the primary monitor.
IgnoredClasses := Map(
    "XamlExplorerHostIslandWindow", 1,
    "MultitaskingViewFrame", 1,
    "ForegroundStaging", 1,
    "TaskSwitcherWnd", 1,
    "TaskSwitcherOverlayWnd", 1,
    "Windows.UI.Core.CoreWindow", 1,
)

; ---------------------------------------------------------------- State
class State {
    static overlay := 0          ; Gui
    static hwnd := 0             ; overlay HWND
    static hooks := []           ; HWINEVENTHOOK handles
    static callback := 0         ; CallbackCreate pointer (kept alive here)
    static hMonitor := 0         ; monitor currently marked
    static rect := ""            ; "l,t,r,b" currently applied
}

InitializeDpiAwareness()
InitializeOverlay()
InstallForegroundHook()
OnMessage(WM_DISPLAYCHANGE, OnDisplayChange)
OnMessage(WM_DPICHANGED, (*) => 0)   ; we size the overlay ourselves; suppress the auto-resize
OnExit(Cleanup)
UpdateActiveMonitor(true)
return

; ---------------------------------------------------------------- Init
InitializeDpiAwareness() {
    ; Must run before any window exists. May fail with ERROR_ACCESS_DENIED if the
    ; process already has an awareness level (e.g. from the AHK manifest); the log
    ; reports the resulting context so that case is visible.
    ok := DllCall("User32\SetProcessDpiAwarenessContext", "ptr", DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, "int")
    err := A_LastError
    if !ok   ; process level already fixed (access denied): fall back to the thread level
        DllCall("User32\SetThreadDpiAwarenessContext", "ptr", DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, "ptr")
    ctx := DllCall("User32\GetThreadDpiAwarenessContext", "ptr")
    isV2 := DllCall("User32\AreDpiAwarenessContextsEqual", "ptr", ctx, "ptr", DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, "int")
    Log("dpiAwareness processSet=" ok " (err=" err ") threadPerMonitorV2=" isV2)
}

InitializeOverlay() {
    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E" WS_EX_NOACTIVATE " +E" WS_EX_TRANSPARENT, "FocusScreenOverlay")
    g.BackColor := BorderColor
    g.Show("NoActivate Hide w100 h100")
    State.overlay := g
    State.hwnd := g.Hwnd
    WinSetTransparent(Opacity, State.hwnd)   ; adds WS_EX_LAYERED
}

InstallForegroundHook() {
    State.callback := CallbackCreate(WinEventProc, "F", 7)
    flags := WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS
    for ev in [EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_MOVESIZEEND] {
        h := DllCall("User32\SetWinEventHook", "uint", ev, "uint", ev, "ptr", 0
            , "ptr", State.callback, "uint", 0, "uint", 0, "uint", flags, "ptr")
        if !h
            Log("SetWinEventHook failed for event " ev)
        else
            State.hooks.Push(h)
    }
}

; ---------------------------------------------------------------- Events
WinEventProc(hHook, event, hwnd, idObject, idChild, thread, time) {
    ; Keep this tiny; real work happens outside the hook callback.
    if (idObject != 0)           ; OBJID_WINDOW only
        return
    SetTimer(UpdateActiveMonitor, -1)
}

OnDisplayChange(*) {
    ; Debounce: a reconfiguration sends several messages.
    SetTimer(() => UpdateActiveMonitor(true), -300)
}

; ---------------------------------------------------------------- Core
UpdateActiveMonitor(force := false) {
    if HideOnSingleMonitor && DllCall("User32\GetSystemMetrics", "int", SM_CMONITORS, "int") <= 1 {
        if State.hMonitor {      ; was visible: hide and forget, so re-plugging redraws
            DllCall("User32\ShowWindow", "ptr", State.hwnd, "int", SW_HIDE)
            State.hMonitor := 0
            State.rect := ""
            Log("single monitor: overlay hidden")
        }
        return
    }
    hwnd := DllCall("User32\GetForegroundWindow", "ptr")
    if !hwnd || hwnd = State.hwnd || IsIgnored(hwnd)
        return

    hMon := DllCall("User32\MonitorFromWindow", "ptr", hwnd, "uint", MONITOR_DEFAULTTONEAREST, "ptr")
    if !hMon
        return

    rect := GetMonitorRect(hMon)
    if !rect
        return
    key := rect.l "," rect.t "," rect.r "," rect.b
    if !force && hMon = State.hMonitor && key = State.rect
        return

    State.hMonitor := hMon
    State.rect := key
    dpi := GetMonitorDpi(hMon)
    Log("hwnd=" Format("0x{:X}", hwnd) " monitor=" Format("0x{:X}", hMon)
        " rect=" key " dpi=" Round(dpi * 100 / 96) "%")
    MoveOverlayToMonitor(rect, dpi)
}

IsIgnored(hwnd) {
    try cls := WinGetClass(hwnd)
    catch
        return true              ; window vanished
    return IgnoredClasses.Has(cls)
}

GetMonitorRect(hMon) {
    mi := Buffer(40, 0)
    NumPut("uint", 40, mi, 0)
    if !DllCall("User32\GetMonitorInfoW", "ptr", hMon, "ptr", mi)
        return 0
    off := UseWorkArea ? 20 : 4  ; rcWork : rcMonitor
    return {l: NumGet(mi, off, "int"), t: NumGet(mi, off + 4, "int")
          , r: NumGet(mi, off + 8, "int"), b: NumGet(mi, off + 12, "int")}
}

GetMonitorDpi(hMon) {
    dx := 0, dy := 0
    hr := DllCall("Shcore\GetDpiForMonitor", "ptr", hMon, "int", MDT_EFFECTIVE_DPI, "uint*", &dx, "uint*", &dy, "int")
    return (hr = 0 && dx) ? dx : 96
}

MoveOverlayToMonitor(rect, dpi) {
    x := rect.l, y := rect.t
    w := rect.r - rect.l, h := rect.b - rect.t
    flags := SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOOWNERZORDER

    ; The first call moves the window onto the target monitor (which may trigger
    ; a DPI transition); the second makes sure the final size is exact.
    loop 2
        DllCall("User32\SetWindowPos", "ptr", State.hwnd, "ptr", HWND_TOPMOST
            , "int", x, "int", y, "int", w, "int", h, "uint", flags)

    ApplyRegion(w, h, Max(1, Round(BorderWidth * dpi / 96)))

    r := Buffer(16)
    DllCall("User32\GetWindowRect", "ptr", State.hwnd, "ptr", r)
    Log("overlay=" NumGet(r, 0, "int") "," NumGet(r, 4, "int") "," NumGet(r, 8, "int") "," NumGet(r, 12, "int")
        " expected=" x "," y "," x + w "," y + h)
}

ApplyRegion(w, h, bw) {
    ; Window-relative physical pixels. The hollow centre is removed from the
    ; region entirely, so it neither draws nor hit-tests.
    outer := DllCall("Gdi32\CreateRectRgn", "int", 0, "int", 0, "int", w, "int", h, "ptr")
    if (Mode = "top") {
        DllCall("Gdi32\SetRectRgn", "ptr", outer, "int", 0, "int", 0, "int", w, "int", Min(bw, h))
        region := outer
    } else {
        inner := DllCall("Gdi32\CreateRectRgn", "int", bw, "int", bw, "int", w - bw, "int", h - bw, "ptr")
        DllCall("Gdi32\CombineRgn", "ptr", outer, "ptr", outer, "ptr", inner, "int", RGN_DIFF)
        DllCall("Gdi32\DeleteObject", "ptr", inner)
        region := outer
    }
    ; The system owns the region after this call; do not delete it.
    DllCall("User32\SetWindowRgn", "ptr", State.hwnd, "ptr", region, "int", true)
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
    if State.overlay
        State.overlay.Destroy()
}

Log(msg) {
    if !DEBUG
        return
    line := FormatTime(, "HH:mm:ss") " [FocusScreen] " msg
    OutputDebug(line)
    try FileAppend(line "`n", A_ScriptDir "\FocusScreen.log")
}

