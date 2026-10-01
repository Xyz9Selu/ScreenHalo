#Requires AutoHotkey v2.0
#SingleInstance Off

; Neutral mock content for README screenshots, so no real desktop is ever captured.
; Covers every monitor (left to right: a coding-agent terminal, a browser showing a docs
; page, ...) with a borderless window and gives the keyboard focus to one of them.
; Sizes are defined in logical (100% scale) pixels and multiplied by each monitor's DPI
; scale, so text looks as dense as on a real screen. All text below is made up.
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

; One text control. bg = "" for transparent, else an RRGGBB fill behind the text.
Txt(g, x, y, w, h, text, color, px, font := "Segoe UI", bold := false, bg := "") {
    g.SetFont("s" Pt(px) " c" color (bold ? " Bold" : " Norm"), font)
    g.Add("Text", Format("x{} y{} w{} h{} {}", x, y, w, h, bg ? "Background" bg : "+BackgroundTrans"), text)
}

Rect(g, x, y, w, h, color) {
    g.Add("Text", Format("x{} y{} w{} h{} Background{}", x, y, w, h, color))
}

BuildWindow(i, m) {
    g := Gui("-Caption -DPIScale +AlwaysOnTop +ToolWindow", "ScreenHaloDemo" i)   ; raw pixels
    s := m.scale
    if (Mod(i, 2) = 1)
        BuildAgentTerminal(g, m, s)
    else
        BuildBrowser(g, m, s)
    g.Show(Format("x{} y{} w{} h{} NoActivate", m.l, m.t, m.w, m.h))
    return g
}

; ---------------------------------------------------------------- coding-agent terminal
BuildAgentTerminal(g, m, s) {
    g.BackColor := "1E1E1E"
    pad := Round(18 * s), barH := Round(32 * s), lh := Round(19 * s), px := 13 * s
    Rect(g, 0, 0, m.w, barH, "2D2D2D")
    Txt(g, pad, Round(7 * s), Round(500 * s), barH, "●  ●  ●      demo-service — agent", "BBBBBB", 12 * s)

    W := Min(m.w - 2 * pad, Round(1000 * s))
    box := "D97757", dim := "858585", plain := "D4D4D4", ok := "89D185", bad := "F48771"
    inner := 62
    top := "╭" StrRepeat("─", inner) "╮", bot := "╰" StrRepeat("─", inner) "╯"
    row := (t) => "│ " PadRight(t, inner - 1) "│"
    L := [[box, top], [box, row("✻ Welcome to Agent Code")], [box, row("")]
        , [box, row("  /help for help, /status for your current setup")], [box, row("")]
        , [box, row("  cwd: ~/projects/demo-service")], [box, bot], [plain, ""]
        , ["user", "> Add retry with exponential backoff to the HTTP client, and cover it with tests"], [plain, ""]
        , [plain, "● I'll start by finding where requests are sent."], [plain, ""]
        , [plain, "● Search(pattern: `"session.get`", path: `"src`")"]
        , [dim, "  ⎿  Found 3 files (ctrl+r to expand)"], [plain, ""]
        , [plain, "● Read(src/http/client.py)"], [dim, "  ⎿  Read 142 lines (ctrl+r to expand)"], [plain, ""]
        , [plain, "● Update(src/http/client.py)"]
        , [dim, "  ⎿  Updated src/http/client.py with 14 additions and 2 removals"]
        , ["ctx", "     38      def get(self, url, **kwargs):"]
        , ["del", "     39  -       return self.session.get(url, timeout=self.timeout)"]
        , ["add", "     39  +       delay = self.base_delay"]
        , ["add", "     40  +       for attempt in range(self.max_retries + 1):"]
        , ["add", "     41  +           try:"]
        , ["add", "     42  +               return self.session.get(url, timeout=self.timeout)"]
        , ["add", "     43  +           except TransientError:"]
        , ["add", "     44  +               if attempt == self.max_retries:"]
        , ["add", "     45  +                   raise"]
        , ["add", "     46  +               time.sleep(delay)"]
        , ["add", "     47  +               delay *= 2"], [plain, ""]
        , [plain, "● Now the tests."], [plain, ""]
        , [plain, "● Write(tests/test_client_retry.py)"], [dim, "  ⎿  Wrote 38 lines to tests/test_client_retry.py"], [plain, ""]
        , [plain, "● Bash(python -m pytest tests/test_client_retry.py -q)"]
        , [dim, "  ⎿  ...."], [dim, "     4 passed in 0.31s"], [plain, ""]
        , [plain, "● Retry with backoff is in place: failed requests are retried up to"]
        , [plain, "  `max_retries` times, doubling the delay each time. All four new tests pass."]]

    y := barH + Round(12 * s)
    limit := m.h - 7 * lh                       ; keep room for the input box
    for ln in L {
        if (y + lh > limit)
            break
        k := ln[1]
        if (k = "user")
            Txt(g, pad, y, W, lh, ln[2], "FFFFFF", px, "Consolas", false, "303030")
        else if (k = "add")
            Txt(g, pad, y, W, lh, ln[2], ok, px, "Consolas", false, "1F3A25")
        else if (k = "del")
            Txt(g, pad, y, W, lh, ln[2], bad, px, "Consolas", false, "3F1F1F")
        else if (k = "ctx")
            Txt(g, pad, y, W, lh, ln[2], dim, px, "Consolas")
        else
            Txt(g, pad, y, W, lh, ln[2], k, px, "Consolas")
        y += lh
    }
    y := m.h - 6 * lh                           ; input box + hint line
    iw := "╭" StrRepeat("─", 98) "╮", ib := "│ " PadRight("> Try `"fix lint errors`"", 97) "│", ie := "╰" StrRepeat("─", 98) "╯"
    Txt(g, pad, y, W, lh, iw, "888888", px, "Consolas")
    Txt(g, pad, y + lh, W, lh, ib, "888888", px, "Consolas")
    Txt(g, pad, y + 2 * lh, W, lh, ie, "888888", px, "Consolas")
    Txt(g, pad, y + 3 * lh, W, lh, "  ? for shortcuts", dim, px, "Consolas")
}

; ---------------------------------------------------------------- browser
BuildBrowser(g, m, s) {
    g.BackColor := "FFFFFF"
    tabH := Round(38 * s), addrH := Round(46 * s)
    Rect(g, 0, 0, m.w, tabH, "DEE1E6")                                   ; tab strip
    Rect(g, Round(8 * s), Round(6 * s), Round(240 * s), tabH - Round(6 * s), "FFFFFF")
    Txt(g, Round(18 * s), Round(12 * s), Round(220 * s), Round(22 * s), "HTTP caching explained", "202124", 13 * s)
    Txt(g, Round(262 * s), Round(12 * s), Round(200 * s), Round(22 * s), "cache-control — search", "5F6368", 13 * s)
    Txt(g, Round(476 * s), Round(12 * s), Round(200 * s), Round(22 * s), "Release notes", "5F6368", 13 * s)
    Txt(g, Round(690 * s), Round(10 * s), Round(40 * s), Round(26 * s), "+", "5F6368", 18 * s)
    Rect(g, 0, tabH, m.w, addrH, "FFFFFF")                               ; address row
    Txt(g, Round(16 * s), tabH + Round(10 * s), Round(150 * s), Round(26 * s), "←    →    ⟳", "5F6368", 16 * s)
    Rect(g, Round(150 * s), tabH + Round(8 * s), Round(m.w * 0.5), Round(30 * s), "F1F3F4")
    Txt(g, Round(166 * s), tabH + Round(13 * s), Round(m.w * 0.48), Round(22 * s), "docs.example.org/guides/http-caching", "202124", 14 * s)
    Rect(g, 0, tabH + addrH, m.w, Round(1 * s), "DADCE0")

    top := tabH + addrH + Round(1 * s)
    side := Round(260 * s), toc := Round(260 * s)
    Rect(g, 0, top, side, m.h - top, "F8F9FA")                           ; docs navigation
    ny := top + Round(24 * s), nh := Round(30 * s)
    for item in [["Getting started", 0], ["Networking", 1], ["    HTTP basics", 0], ["    Caching", 2], ["    Cookies", 0]
               , ["    CORS", 0], ["Security", 1], ["Deployment", 1], ["Reference", 1]] {
        col := item[2] = 2 ? "1A73E8" : (item[2] = 1 ? "202124" : "5F6368")
        Txt(g, Round(24 * s), ny, side - Round(32 * s), nh, item[1], col, 14 * s, "Segoe UI", item[2] != 0)
        ny += nh
    }
    tx := m.w - toc                                                        ; "on this page"
    Txt(g, tx, top + Round(40 * s), toc, Round(24 * s), "ON THIS PAGE", "5F6368", 12 * s, "Segoe UI", true)
    ty := top + Round(72 * s)
    for item in ["Freshness", "Cache-Control directives", "Revalidation", "Vary and keys", "Common pitfalls"] {
        Txt(g, tx, ty, toc - Round(24 * s), nh, item, "5F6368", 13 * s)
        ty += nh
    }

    x := side + Round(60 * s), w := m.w - side - toc - Round(120 * s)
    y := top + Round(36 * s), body := 16 * s, lh := Round(27 * s)
    Txt(g, x, y, w, Round(22 * s), "Guides  ›  Networking  ›  Caching", "5F6368", 13 * s)
    y += Round(34 * s)
    Txt(g, x, y, w, Round(52 * s), "HTTP caching explained", "202124", 36 * s, "Segoe UI", true)
    y += Round(76 * s)
    paras := [["p", "HTTP caching lets clients and intermediaries reuse earlier responses instead of asking the origin server again. Done well, it reduces latency, saves bandwidth, and keeps servers calm under load."]
            , ["p", "A response is stored together with the rules that govern its reuse. The most important rule is freshness: for as long as a stored response is fresh, a cache may serve it without contacting the server."]
            , ["h", "Cache-Control directives"]
            , ["b", "•  max-age=N: the response stays fresh for N seconds after it was generated."]
            , ["b", "•  no-cache: a cache must revalidate with the server before reusing the response."]
            , ["b", "•  no-store: nothing about the request or the response may be stored."]
            , ["b", "•  public / private: whether shared caches may store the response."]
            , ["c", "Cache-Control: public, max-age=3600`nETag: `"33a64df551425fcc`"`nVary: Accept-Encoding"]
            , ["h", "Revalidation"]
            , ["p", "When a response becomes stale, the cache can revalidate it using a validator such as an ETag. If nothing changed, the server answers 304 Not Modified and the cached body is reused."]
            , ["t", "Tip: send Cache-Control: no-cache when you want revalidation on every request without giving up caching entirely."]
            , ["p", "Responses that depend on request headers must say so with Vary, otherwise a cache may hand one client the variant that was meant for another."]
            , ["h", "Common pitfalls"]
            , ["b", "•  Caching personalised pages in a shared cache."]
            , ["b", "•  Forgetting to version the URLs of static assets."]]
    for p in paras {
        if (y > m.h - 2 * lh)
            break
        switch p[1] {
        case "h":
            y += Round(10 * s)
            Txt(g, x, y, w, Round(36 * s), p[2], "202124", 24 * s, "Segoe UI", true)
            y += Round(48 * s)
        case "c":
            Txt(g, x, y, w, 3 * Round(24 * s) + Round(16 * s), "`n" p[2], "24292F", 14 * s, "Consolas", false, "F6F8FA")
            y += 3 * Round(24 * s) + Round(36 * s)
        case "t":
            n := Ceil(StrLen(p[2]) * body * 0.5 / w)
            Txt(g, x, y, w, n * lh + Round(20 * s), p[2], "174EA6", body, "Segoe UI", false, "E8F0FE")
            y += n * lh + Round(20 * s) + Round(18 * s)
        case "b":
            Txt(g, x + Round(12 * s), y, w - Round(12 * s), lh, p[2], "3C4043", body)
            y += lh + Round(4 * s)
        default:
            n := Ceil(StrLen(p[2]) * body * 0.5 / w)
            Txt(g, x, y, w, n * lh, p[2], "3C4043", body)
            y += n * lh + Round(14 * s)
        }
    }
}

StrRepeat(str, n) {
    out := ""
    loop n
        out .= str
    return out
}

PadRight(str, n) {
    while (StrLen(str) < n)
        str .= " "
    return str
}
