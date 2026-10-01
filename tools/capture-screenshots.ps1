# Generates the README screenshots on neutral mock content (tools/demo.ahk), so no real
# desktop is ever captured. Needs AutoHotkey v2 and at least two monitors.
#
#   powershell -ExecutionPolicy Bypass -File tools\capture-screenshots.ps1 [-OutDir docs\img]
#
# Each monitor is captured separately and scaled to the same 16:9 size, then placed side by
# side, so the pictures show two equal screens regardless of your real layout.
# While it runs, every monitor is covered by the demo windows for ~6 s per scene.
# It uses its own temporary config (FOCUSSCREEN_INI), so your FocusScreen.ini is untouched,
# and restarts your normal FocusScreen at the end.
param([string]$OutDir = (Join-Path $PSScriptRoot '..\docs\img'))
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$ahk = @("$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe", "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $ahk) { throw 'AutoHotkey v2 not found.' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System.Runtime.InteropServices;
public class Cap { [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr c);
                   [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i); }
'@
[Cap]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

function New-Ini($style, $otherEdges = 'TBLR', $otherColor = '8A8A8A') {
    $f = Join-Path $env:TEMP 'focusscreen-demo.ini'
    @"
[focus]
style=$style
edges=TBLR
width=4
opacity=70
color=FF9100
pulse=0
[other]
style=$style
edges=$otherEdges
width=6
opacity=85
color=$otherColor
[general]
enabled=1
"@ | Set-Content $f
    return $f
}

# Captures all monitors, then returns one picture with each monitor scaled to $tileW x ($tileW*9/16),
# left to right, flush with a thin gap.
function Capture-Pair($style, $focusIdx, $tileW, $otherEdges = 'TBLR', $otherColor = '8A8A8A') {
    $env:FOCUSSCREEN_INI = New-Ini $style $otherEdges $otherColor
    $demo = Start-Process $ahk "`"$PSScriptRoot\demo.ahk`" $focusIdx 15" -PassThru
    Start-Sleep 2
    $fs = Start-Process $ahk "`"$root\FocusScreen.ahk`"" -PassThru
    Start-Sleep 2.5                      # let any pulse finish
    $x = [Cap]::GetSystemMetrics(76); $y = [Cap]::GetSystemMetrics(77)
    $w = [Cap]::GetSystemMetrics(78); $h = [Cap]::GetSystemMetrics(79)
    $bmp = New-Object Drawing.Bitmap $w, $h
    [Drawing.Graphics]::FromImage($bmp).CopyFromScreen($x, $y, 0, 0, $bmp.Size)
    Stop-Process -Id $fs.Id, $demo.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    $rects = [Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X } | ForEach-Object { $_.Bounds }
    $tileH = [int]($tileW * 9 / 16); $gap = 6
    $pair = New-Object Drawing.Bitmap ($tileW * $rects.Count + $gap * ($rects.Count - 1)), $tileH
    $g = [Drawing.Graphics]::FromImage($pair)
    $g.Clear([Drawing.Color]::FromArgb(24, 24, 24))
    $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
    $i = 0
    foreach ($r in $rects) {
        $src = New-Object Drawing.Rectangle ($r.X - $x), ($r.Y - $y), $r.Width, $r.Height
        $dst = New-Object Drawing.Rectangle ($i * ($tileW + $gap)), 0, $tileW, $tileH
        $g.DrawImage($bmp, $dst, $src, [Drawing.GraphicsUnit]::Pixel)
        $i++
    }
    $g.Dispose(); $bmp.Dispose()
    return $pair
}

$userRunning = [bool](Get-Process AutoHotkey64 -ErrorAction SilentlyContinue)
Stop-Process -Name AutoHotkey64 -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
try {
    # 1. Focus on the right / left monitor (default glow)
    foreach ($case in @(@('focus-right', 2), @('focus-left', 1))) {
        $p = Capture-Pair 'glow' $case[1] 800
        $p.Save("$OutDir\$($case[0]).png", [Drawing.Imaging.ImageFormat]::Png); $p.Dispose()
    }

    # 2. Facing edge for the other screen (cyan only so the demo is easy to see)
    $p = Capture-Pair 'glow' 2 800 'AUTO' '00B8D4'
    $p.Save("$OutDir\facing-edge.png", [Drawing.Imaging.ImageFormat]::Png); $p.Dispose()

    # 3. Style gallery (2 x 3 contact sheet)
    $styles = 'glow', 'vignette', 'border', 'double', 'dashed', 'corners'
    $labels = 'Glow (default)', 'Vignette', 'Solid', 'Double', 'Dashed', 'Corners'
    $sheet = $null; $g = $null; $i = 0
    foreach ($st in $styles) {
        $b = Capture-Pair $st 2 400
        if (-not $sheet) {
            $sheet = New-Object Drawing.Bitmap ($b.Width * 2 + 30), (($b.Height + 10) * 3 + 10)
            $g = [Drawing.Graphics]::FromImage($sheet); $g.Clear([Drawing.Color]::FromArgb(40, 40, 40))
        }
        $cx = 10 + ($i % 2) * ($b.Width + 10); $cy = 10 + [math]::Floor($i / 2) * ($b.Height + 10)
        $g.DrawImage($b, $cx, $cy, $b.Width, $b.Height)
        $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(200, 0, 0, 0))), $cx, $cy, 120, 20)
        $g.DrawString($labels[$i], (New-Object Drawing.Font 'Segoe UI', 9), [Drawing.Brushes]::White, $cx + 5, $cy + 2)
        $b.Dispose(); $i++
    }
    $sheet.Save("$OutDir\styles.png", [Drawing.Imaging.ImageFormat]::Png)
}
finally {
    Stop-Process -Name AutoHotkey64 -Force -ErrorAction SilentlyContinue
    Remove-Item Env:FOCUSSCREEN_INI -ErrorAction SilentlyContinue
    if ($userRunning) { Start-Process $ahk "`"$root\FocusScreen.ahk`"" }
}
Write-Host "Saved to $OutDir"
