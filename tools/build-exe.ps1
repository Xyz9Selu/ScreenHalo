# Builds dist\ScreenHalo.exe from ScreenHalo.ahk with Ahk2Exe (the AutoHotkey script compiler).
#
#   powershell -ExecutionPolicy Bypass -File tools\build-exe.ps1 [-Ahk2Exe <path to Ahk2Exe.exe>]
#
# Ahk2Exe is not included with the winget AutoHotkey package; download it from
# https://github.com/AutoHotkey/Ahk2Exe/releases and pass its path, or put it in one of the
# default locations searched below. The version comes from the ;@Ahk2Exe-SetVersion line in
# ScreenHalo.ahk (keep it in sync with VERSION).
param([string]$Ahk2Exe)
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$candidates = @($Ahk2Exe,
    "$env:LOCALAPPDATA\Programs\AutoHotkey\Compiler\Ahk2Exe.exe",
    "$env:ProgramFiles\AutoHotkey\Compiler\Ahk2Exe.exe",
    "$env:TEMP\ahk2exe\x\Ahk2Exe.exe") | Where-Object { $_ -and (Test-Path $_) }
$compiler = $candidates | Select-Object -First 1
if (-not $compiler) { throw 'Ahk2Exe.exe not found. Download it from https://github.com/AutoHotkey/Ahk2Exe/releases and pass -Ahk2Exe <path>.' }

$base = @("$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe", "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $base) { throw 'AutoHotkey v2 (AutoHotkey64.exe) not found.' }

$out = Join-Path $root 'dist\ScreenHalo.exe'
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
Remove-Item $out -ErrorAction SilentlyContinue
# Ahk2Exe is a GUI-subsystem program: Start-Process -Wait is needed to wait for it to finish.
Start-Process $compiler -Wait -NoNewWindow -ArgumentList "/in `"$(Join-Path $root 'ScreenHalo.ahk')`" /out `"$out`" /base `"$base`" /silent verbose"
if (-not (Test-Path $out)) { throw 'Build failed.' }
$item = Get-Item $out
Write-Host ("Built {0} ({1:N0} bytes), version {2}" -f $item.FullName, $item.Length, $item.VersionInfo.FileVersion)
Write-Host ("SHA256 {0}" -f (Get-FileHash $out -Algorithm SHA256).Hash.ToLower())
