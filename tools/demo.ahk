#Requires AutoHotkey v2.0
#SingleInstance Off

; Neutral mock content for README screenshots, so no real desktop is ever captured.
; Covers every monitor (left to right: dark terminal, light document, ...) with a
; borderless window and gives the keyboard focus to one of them.
; Sizes are defined in logical (100% scale) pixels and multiplied by each monitor's DPI
; scale, so text looks as dense as on a real screen.
;
;   demo.ahk <focusIndex> [seconds]     focusIndex: 1 = leftmost monitor.  Esc quits.

DllCall("User32\SetThreadDpiAwarenessContext", "ptr", -4, "ptr")   ; per-monitor v2, physical pixels
focusIdx := A_Args.Length >= 1 ? Integer(A_Args[1]) : 2
seconds  := A_Args.Length >= 2 ? Integer(A_Args[2]) : 20

mons := []
loop MonitorGetCount() {
    MonitorGet(A_Index, &l, &t, &r, &b)
    hMon := DllCall("User32\MonitorFromPoint", "int64", (t + 1 << 32) | ((l + 1) & 0xFFFFFFFF), "uint", 2, "ptr")
    dx := 0, dy := 0
    DllCall("Shcore\GetDpiForMonitor", "ptr", hMon, "int", 0, "uint*", &dx, "uint*", &dy)
    mons.Push({l: l, t: t, w: r - l, h: b - t, scale: (dx ? dx : 96) / 96})
}
loop mons.Length - 1                         ; sort left to right
    loop mons.Length - A_Index
        if (mons[A_Index].l > mons[A_Index + 1].l)
            tmp := mons[A_Index], mons[A_Index] := mons[A_Index + 1], mons[A_Index + 1] := tmp

wins := []
for i, m in mons
    wins.Push(BuildWindow(i, m))

focusIdx := Min(Max(focusIdx, 1), wins.Length)
WinActivate(wins[focusIdx].Hwnd)
Hotkey("Escape", (*) => ExitApp())
SetTimer(() => ExitApp(), -seconds * 1000)
return

; Font height in pixels -> AHK point size (AHK converts points using the system DPI).
Pt(px) => Max(6, Round(px * 72 / A_ScreenDPI))

BuildWindow(i, m) {
    s := m.scale
    dark := (Mod(i, 2) = 1)
    bg := dark ? "1E1E1E" : "FFFFFF"
    bar := dark ? "2D2D2D" : "F0F1F3"
    fg := dark ? "D4D4D4" : "333333"
    g := Gui("-Caption -DPIScale +AlwaysOnTop +ToolWindow", "FocusScreenDemo" i)   ; raw pixels, no system-DPI scaling
    g.BackColor := bg
    pad := Round(16 * s)
    barH := Round(32 * s)

    g.SetFont("s" Pt(12 * s) " c" fg, "Segoe UI")
    g.Add("Text", Format("x0 y0 w{} h{} Background{}", m.w, barH, bar))
    g.Add("Text", Format("x{} y{} w{} h{} +BackgroundTrans", pad, Round(7 * s), Round(400 * s), barH)
        , dark ? "●  ●  ●      Terminal" : "●  ●  ●      Notes")

    y := barH + Round(10 * s)
    if dark {
        lineH := Round(19 * s)
        g.SetFont("s" Pt(13 * s), "Consolas")
        lines := [["6A9955", "# build and run the demo project"]
                , ["4EC9B0", "$ make build"], ["D4D4D4", "cc -O2 -Wall -c src/main.c -o build/main.o"]
                , ["D4D4D4", "cc -O2 -Wall -c src/util.c -o build/util.o"], ["D4D4D4", "cc -O2 -Wall -c src/net.c  -o build/net.o"]
                , ["D4D4D4", "linking build/app ... done"], ["D4D4D4", ""]
                , ["4EC9B0", "$ ./build/app --verbose"]
                , ["CE9178", "[info] starting worker pool (4 threads)"], ["CE9178", "[info] listening on 127.0.0.1:8080"]
                , ["DCDCAA", "[warn] cache directory not found, creating"], ["CE9178", "[info] ready in 38 ms"]
                , ["CE9178", "[info] GET /health 200 1.2ms"], ["CE9178", "[info] GET /items?limit=20 200 4.8ms"]
                , ["CE9178", "[info] POST /items 201 6.1ms"], ["D4D4D4", ""]
                , ["4EC9B0", "$ git log --oneline -6"]
                , ["D4D4D4", "a1b2c3d fix off-by-one in parser"], ["D4D4D4", "e4f5a6b add retry with backoff"]
                , ["D4D4D4", "c7d8e9f update documentation"], ["D4D4D4", "0a1b2c3 refactor config loading"]
                , ["D4D4D4", "9f8e7d6 add unit tests for util"], ["D4D4D4", "5c4b3a2 initial commit"], ["D4D4D4", ""]
                , ["4EC9B0", "$ make test"], ["D4D4D4", "running 24 tests"]
                , ["6A9955", "ok   parser_basic"], ["6A9955", "ok   parser_errors"], ["6A9955", "ok   retry_backoff"]
                , ["6A9955", "ok   config_defaults"], ["DCDCAA", "skip net_integration (no network)"]
                , ["D4D4D4", "24 passed, 0 failed, 1 skipped"], ["D4D4D4", ""], ["4EC9B0", "$ _"]]
        n := 0
        while (y + lineH < m.h) {            ; fill the whole screen like a long terminal session
            ln := lines[Mod(n, lines.Length) + 1]
            g.SetFont("c" ln[1])
            g.Add("Text", Format("x{} y{} w{} h{}", pad, y, m.w - 2 * pad, lineH), ln[2])
            y += lineH, n += 1
        }
    } else {
        side := Round(240 * s)
        g.Add("Text", Format("x0 y{} w{} h{} Background{}", barH, side, m.h - barH, "F6F7F9"))
        g.SetFont("s" Pt(14 * s) " c555555", "Segoe UI")
        for name in ["Inbox", "Projects", "Ideas", "Reading list", "Meetings", "Journal", "Archive"]
            g.Add("Text", Format("x{} y{} w{} h{} +BackgroundTrans", pad, barH + Round(16 * s) + (A_Index - 1) * Round(34 * s), side - pad, Round(28 * s)), name)
        x := side + Round(48 * s), pw := m.w - x - Round(48 * s)
        g.SetFont("s" Pt(32 * s) " Bold c222222", "Segoe UI")
        g.Add("Text", Format("x{} y{} w{} h{} +BackgroundTrans", x, y + Round(6 * s), pw, Round(48 * s)), "Meeting notes")
        y += Round(80 * s)
        widths := [0.98, 0.95, 0.99, 0.92, 0.55, 0, 0.97, 0.94, 0.99, 0.96, 0.62, 0, 0.98, 0.93, 0.97, 0.90, 0.99, 0.48, 0]
        n := 0
        while (y + Round(20 * s) < m.h) {
            wf := widths[Mod(n, widths.Length) + 1]
            if (wf > 0)
                g.Add("Text", Format("x{} y{} w{} h{} Background{}", x, y + Round(5 * s), Round(pw * wf), Round(9 * s), "D5D8DE"))
            y += Round(22 * s), n += 1
        }
    }
    g.Show(Format("x{} y{} w{} h{} NoActivate", m.l, m.t, m.w, m.h))
    return g
}
