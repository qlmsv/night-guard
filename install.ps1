# Night Guard installer for Windows: hooks for Claude Code + Codex, `nightguard` command, tray app.
#   powershell -ExecutionPolicy Bypass -File install.ps1            install everything
#   powershell -ExecutionPolicy Bypass -File install.ps1 -NoTray    skip the tray app
param([switch]$NoTray)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }

& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'windows\nightguard.ps1') install all
if ($LASTEXITCODE -ne 0) { throw 'Установка не удалась.' }

if (-not $NoTray) {
    $ngHome = Join-Path $env:USERPROFILE '.night-guard'
    $tray = Join-Path $ngHome 'tray.ps1'
    $trayArgs = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tray`""
    # Autostart at login
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Night Guard.lnk'
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($lnkPath)
    $lnk.TargetPath = $ps; $lnk.Arguments = $trayArgs; $lnk.WindowStyle = 7; $lnk.Description = 'Night Guard'
    $lnk.Save()
    # Start Menu entry
    $menuLnk = $sh.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Night Guard.lnk'))
    $menuLnk.TargetPath = $ps; $menuLnk.Arguments = "$trayArgs -Open"; $menuLnk.WindowStyle = 7; $menuLnk.Description = 'Night Guard'
    $menuLnk.Save()
    Start-Process -FilePath $ps -ArgumentList "$trayArgs -Open" -WindowStyle Hidden
    Write-Host '✓ Значок Night Guard добавлен в трей (область уведомлений) и в автозагрузку.'
}
Write-Host ''
& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $env:USERPROFILE '.night-guard\nightguard.ps1') status
