# Creates a shortcut to FocusScreen.ahk in the current user's Startup folder.
# A .lnk stores absolute paths, so it is generated per machine instead of being committed.
$ErrorActionPreference = 'Stop'

$script = Join-Path $PSScriptRoot '..\FocusScreen.ahk' | Resolve-Path | Select-Object -ExpandProperty Path
$ahk = @(
    "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
    "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $ahk) { throw 'AutoHotkey v2 not found. Install it first: winget install AutoHotkey.AutoHotkey' }

$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'FocusScreen.lnk'
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$s.TargetPath = $ahk
$s.Arguments = "`"$script`""
$s.WorkingDirectory = Split-Path $script
$s.Description = 'FocusScreen'
$s.Save()
Write-Host "Created $lnk"
