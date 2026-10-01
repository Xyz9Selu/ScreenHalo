# Removes the FocusScreen startup shortcut.
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'FocusScreen.lnk'
if (Test-Path $lnk) { Remove-Item $lnk; Write-Host "Removed $lnk" } else { Write-Host 'Not installed.' }
