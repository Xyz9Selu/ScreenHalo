# Draws the ScreenHalo icon (a dark screen with a soft orange glow around its edge) and writes a
# multi-size .ico (16..256 px, PNG-compressed entries). Each size is drawn separately so small
# sizes stay crisp.
#
#   powershell -ExecutionPolicy Bypass -File tools\make-icon.ps1 [-Out assets\ScreenHalo.ico] [-Preview preview.png]
param(
    [string]$Out = (Join-Path $PSScriptRoot '..\assets\ScreenHalo.ico'),
    [string]$Preview
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-RoundedRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = [math]::Max(0.1, 2 * $r)
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Draw-Icon([int]$size) {
    $bmp = New-Object Drawing.Bitmap $size, $size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([Drawing.Color]::Transparent)

    $m = $size * 0.055                         # margin
    $w = $size - 2 * $m
    $r = $size * 0.20                          # corner radius
    # dark "screen" body
    $body = New-RoundedRect $m $m $w $w $r
    $grad = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.PointF]::new(0, $m)), ([Drawing.PointF]::new(0, $size - $m)), ([Drawing.Color]::FromArgb(255, 38, 42, 50)), ([Drawing.Color]::FromArgb(255, 20, 22, 27))
    $g.FillPath($grad, $body)

    # soft glow: concentric rounded outlines fading towards the centre, clipped to the body
    $g.SetClip($body)
    $depth = $size * 0.22
    $step = [math]::Max(0.5, $size / 256)
    for ($t = 0.0; $t -lt $depth; $t += $step) {
        $a = [int](255 * [math]::Pow(1 - $t / $depth, 1.7))
        $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb($a, 255, 145, 0)), ($step * 1.6)
        $p = New-RoundedRect ($m + $t) ($m + $t) ($w - 2 * $t) ($w - 2 * $t) ([math]::Max(0.5, $r - $t))
        $g.DrawPath($pen, $p)
        $pen.Dispose(); $p.Dispose()
    }
    $g.ResetClip()

    # crisp bright rim so it reads at 16 px
    $rimW = [math]::Max(1.2, $size * 0.045)
    $rim = New-RoundedRect ($m + $rimW / 2) ($m + $rimW / 2) ($w - $rimW) ($w - $rimW) ($r - $rimW / 2)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(255, 255, 183, 77)), $rimW
    $g.DrawPath($pen, $rim)

    # a small "window" hint in the middle, only where it stays legible
    if ($size -ge 32) {
        $c = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(70, 255, 255, 255))
        $bw = $w * 0.46; $bh = $w * 0.30
        $win = New-RoundedRect (($size - $bw) / 2) (($size - $bh) / 2) $bw $bh ($size * 0.04)
        $g.FillPath($c, $win)
        $bar = New-RoundedRect (($size - $bw) / 2) (($size - $bh) / 2) $bw ($bh * 0.22) ($size * 0.04)
        $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(70, 255, 255, 255))), $bar)
    }
    $g.Dispose()
    return $bmp
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = foreach ($s in $sizes) {
    $b = Draw-Icon $s
    $ms = New-Object IO.MemoryStream
    $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    [pscustomobject]@{ Size = $s; Bytes = $ms.ToArray(); Bitmap = $b }
}

# ICO container: ICONDIR + ICONDIRENTRY[] + PNG blobs
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$fs = [IO.File]::Create($Out); $bw = New-Object IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$pngs.Count)
$offset = 6 + 16 * $pngs.Count
foreach ($p in $pngs) {
    $dim = if ($p.Size -ge 256) { 0 } else { $p.Size }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$p.Bytes.Length); $bw.Write([uint32]$offset)
    $offset += $p.Bytes.Length
}
foreach ($p in $pngs) { $bw.Write($p.Bytes) }
$bw.Close(); $fs.Close()
Write-Host ("Wrote {0} ({1:N0} bytes, sizes: {2})" -f (Resolve-Path $Out), (Get-Item $Out).Length, ($sizes -join ', '))

if ($Preview) {   # contact sheet on light and dark backgrounds
    $show = 256, 128, 64, 48, 32, 24, 16
    $sheetW = [int](20 + ($show | Measure-Object -Sum).Sum + 14 * $show.Count)
    $sheet = New-Object Drawing.Bitmap $sheetW, 600
    $g = [Drawing.Graphics]::FromImage($sheet)
    $g.Clear([Drawing.Color]::White)
    $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(32, 32, 32))), 0, 300, $sheetW, 300)
    foreach ($row in 0, 1) {
        $x = 20
        foreach ($s in $show) {
            $p = $pngs | Where-Object Size -eq $s
            $g.DrawImage($p.Bitmap, $x, $row * 300 + 20 + (256 - $s) / 2, $s, $s)
            $x += $s + 14
        }
    }
    $sheet.Save($Preview, [Drawing.Imaging.ImageFormat]::Png)
    Write-Host "Preview: $Preview"
}
