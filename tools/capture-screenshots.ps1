# Generates the README screenshots on neutral mock content (tools/demo.ahk), so no real
# desktop is ever captured. Needs AutoHotkey v2 and at least two monitors.
#
#   powershell -ExecutionPolicy Bypass -File tools\capture-screenshots.ps1 [-OutDir docs\img]
#
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

function Capture-Scene($file, $style, $focusIdx, $otherEdges = 'TBLR', $otherColor = '8A8A8A') {
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
    $bmp.Save($file, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Resize-Image($src, $dst, $width) {
    $b = [Drawing.Bitmap]::FromFile($src)
    $r = New-Object Drawing.Bitmap $width, ([int]($width * $b.Height / $b.Width))
    $g = [Drawing.Graphics]::FromImage($r); $g.InterpolationMode = 'HighQualityBicubic'
    $g.DrawImage($b, 0, 0, $r.Width, $r.Height)
    $b.Dispose(); $r.Save($dst, [Drawing.Imaging.ImageFormat]::Png); $r.Dispose()
}

$userRunning = [bool](Get-Process AutoHotkey64 -ErrorAction SilentlyContinue)
Stop-Process -Name AutoHotkey64 -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
$tmp = Join-Path $env:TEMP 'focusscreen-shots'
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    # 1. Focus on the right / left monitor (default glow)
    Capture-Scene "$tmp\focus-right.png" 'glow' 2
    Capture-Scene "$tmp\focus-left.png" 'glow' 1
    Resize-Image "$tmp\focus-right.png" "$OutDir\focus-right.png" 1600
    Resize-Image "$tmp\focus-left.png" "$OutDir\focus-left.png" 1600

    # 2. Facing edge for the other screen
    Capture-Scene "$tmp\facing.png" 'glow' 2 'AUTO' '00B8D4'    # cyan only so the demo is easy to see
    Resize-Image "$tmp\facing.png" "$OutDir\facing-edge.png" 1600

    # 3. Style gallery (2 x 3 contact sheet)
    $styles = 'glow', 'vignette', 'border', 'double', 'dashed', 'corners'
    $labels = 'Glow (default)', 'Vignette', 'Solid', 'Double', 'Dashed', 'Corners'
    $tw = 800
    $sheet = $null; $i = 0
    foreach ($st in $styles) {
        Capture-Scene "$tmp\s_$st.png" $st 2
        $b = [Drawing.Bitmap]::FromFile("$tmp\s_$st.png")
        $th = [int]($tw * $b.Height / $b.Width)
        if (-not $sheet) { $sheet = New-Object Drawing.Bitmap ($tw * 2 + 30), (($th + 10) * 3 + 10); $g = [Drawing.Graphics]::FromImage($sheet); $g.Clear([Drawing.Color]::FromArgb(24, 24, 24)); $g.InterpolationMode = 'HighQualityBicubic' }
        $cx = 10 + ($i % 2) * ($tw + 10); $cy = 10 + [math]::Floor($i / 2) * ($th + 10)
        $g.DrawImage($b, $cx, $cy, $tw, $th)
        $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(200, 0, 0, 0))), $cx, $cy, 120, 20)
        $g.DrawString($labels[$i], (New-Object Drawing.Font 'Segoe UI', 9), [Drawing.Brushes]::White, $cx + 5, $cy + 2)
        $b.Dispose(); $i++
    }
    $sheet.Save("$OutDir\styles.png", [Drawing.Imaging.ImageFormat]::Png)
}
finally {
    Stop-Process -Name AutoHotkey64 -Force -ErrorAction SilentlyContinue
    Remove-Item Env:FOCUSSCREEN_INI -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($userRunning) { Start-Process $ahk "`"$root\FocusScreen.ahk`"" }
}
Write-Host "Saved to $OutDir"
