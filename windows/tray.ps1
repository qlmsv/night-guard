# Night Guard — Windows tray app (system tray icon + settings window).
# Run: powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File tray.ps1
# Pure PowerShell + WinForms: nothing to compile or install.

$ErrorActionPreference = 'Stop'
$script:OpenAtStart = $args -contains '-Open'   # read before dot-sourcing replaces $args
$env:NG_NO_PROMPT = '1'                          # never block the UI thread on Read-Host
$Inv = [Globalization.CultureInfo]::InvariantCulture
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Single instance
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\NightGuardTray', [ref]$createdNew)
if (-not $createdNew) { exit 0 }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:NG_CLI_LIB = '1'; . (Join-Path $here 'nightguard.ps1'); Remove-Item Env:NG_CLI_LIB

# ---------- icons (drawn, no image files) ----------
$script:IconCache = @{}
function Get-NgIcon([string]$State) {
    if ($script:IconCache.ContainsKey($State)) { return $script:IconCache[$State] }
    $color = switch ($State) {
        'night' { [System.Drawing.Color]::FromArgb(255, 124, 108, 255) }
        'pause' { [System.Drawing.Color]::FromArgb(255, 245, 158, 11) }
        'off'   { [System.Drawing.Color]::FromArgb(255, 140, 140, 150) }
        default { [System.Drawing.Color]::FromArgb(255, 250, 204, 21) }
    }
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $color
    if ($State -eq 'day') {
        $g.FillEllipse($brush, 8, 8, 16, 16)                                     # sun
        $pen = New-Object System.Drawing.Pen($color, 2.5)
        for ($a = 0; $a -lt 360; $a += 45) {
            $r = $a * [math]::PI / 180
            $g.DrawLine($pen, 16 + 11 * [math]::Cos($r), 16 + 11 * [math]::Sin($r), 16 + 15 * [math]::Cos($r), 16 + 15 * [math]::Sin($r))
        }
    } else {
        $g.FillEllipse($brush, 2, 2, 28, 28)                                     # crescent moon
        $g.CompositingMode = 'SourceCopy'
        $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Transparent)), 11, -3, 26, 26)
    }
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $script:IconCache[$State] = $icon
    return $icon
}

function Get-NgState($s) {
    if (-not $s.enabled) { return 'off' }
    if ($s.blocking) { return 'night' }
    if ($s.pause_left -gt 0) { return 'pause' }
    return 'day'
}

function Get-NgStateText($s) {
    switch (Get-NgState $s) {
        'off'   { 'Night Guard выключен' }
        'night' { "Ночь — агенты спят до $($s.end)" }
        'pause' { "Пауза · ещё $([int][math]::Floor($s.pause_left / 60) + 1) мин" }
        default { "День — можно работать. Ночь с $($s.start)" }
    }
}

# ---------- autostart ----------
$script:StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Night Guard.lnk'
function Set-NgAutostart([bool]$On) {
    if ($On) {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($script:StartupLnk)
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $here 'tray.ps1')`""
        $lnk.WindowStyle = 7
        $lnk.Description = 'Night Guard'
        $lnk.Save()
    } elseif (Test-Path -LiteralPath $script:StartupLnk) { Remove-Item -LiteralPath $script:StartupLnk -Force }
}

# ---------- settings window ----------
$font = New-Object System.Drawing.Font('Segoe UI', 9)
$bold = New-Object System.Drawing.Font('Segoe UI Semibold', 11)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Night Guard'
$form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
$form.StartPosition = 'Manual'; $form.ShowInTaskbar = $false; $form.TopMost = $true
$form.ClientSize = New-Object System.Drawing.Size(360, 430); $form.Font = $font
$form.Icon = Get-NgIcon 'night'

function New-NgLabel($text, $x, $y, $w = 320, $h = 20) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, $h)
    $form.Controls.Add($l); return $l
}
function New-NgButton($text, $x, $y, $w = 110) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 26)
    $form.Controls.Add($b); return $b
}
function New-NgTimePicker($x, $y) {
    $p = New-Object System.Windows.Forms.DateTimePicker
    $p.Format = 'Custom'; $p.CustomFormat = 'HH:mm'; $p.ShowUpDown = $true
    $p.Location = New-Object System.Drawing.Point($x, $y); $p.Size = New-Object System.Drawing.Size(70, 24)
    $form.Controls.Add($p); return $p
}

$picIcon = New-Object System.Windows.Forms.PictureBox
$picIcon.Location = New-Object System.Drawing.Point(16, 14); $picIcon.Size = New-Object System.Drawing.Size(32, 32)
$form.Controls.Add($picIcon)
$lblState = New-NgLabel '' 58 12 290 22; $lblState.Font = $bold
$lblSub = New-NgLabel '' 58 34 290 18; $lblSub.ForeColor = [System.Drawing.Color]::DimGray

New-NgLabel 'Расписание' 16 70 | ForEach-Object { $_.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9) }
$chkEnabled = New-Object System.Windows.Forms.CheckBox
$chkEnabled.Text = 'Включён'; $chkEnabled.Location = New-Object System.Drawing.Point(250, 68); $chkEnabled.AutoSize = $true
$form.Controls.Add($chkEnabled)
New-NgLabel 'С' 16 99 16 | Out-Null
$dtStart = New-NgTimePicker 34 96
New-NgLabel 'до' 112 99 24 | Out-Null
$dtEnd = New-NgTimePicker 138 96
$btnSave = New-NgButton 'Сохранить' 230 95
$lblLock = New-NgLabel '' 16 126 330 18; $lblLock.ForeColor = [System.Drawing.Color]::DimGray

New-NgLabel 'Агенты' 16 156 | ForEach-Object { $_.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9) }
$lblClaude = New-NgLabel 'Claude Code' 16 184 200
$btnClaude = New-NgButton '' 230 180
$lblCodex = New-NgLabel 'Codex' 16 216 200
$btnCodex = New-NgButton '' 230 212
$lblCodexNote = New-NgLabel 'В Codex один раз выполните /hooks и доверьте хукам Night Guard.' 16 244 330 32
$lblCodexNote.ForeColor = [System.Drawing.Color]::DimGray

$grpPause = New-Object System.Windows.Forms.GroupBox
$grpPause.Text = 'Экстренная пауза (один раз за ночь)'; $grpPause.Location = New-Object System.Drawing.Point(16, 280); $grpPause.Size = New-Object System.Drawing.Size(328, 96)
$form.Controls.Add($grpPause)
$numPause = New-Object System.Windows.Forms.NumericUpDown
$numPause.Minimum = 1; $numPause.Maximum = 30; $numPause.Value = 15; $numPause.Location = New-Object System.Drawing.Point(10, 22); $numPause.Size = New-Object System.Drawing.Size(50, 24)
$grpPause.Controls.Add($numPause)
$lblPauseHint = New-Object System.Windows.Forms.Label
$lblPauseHint.Text = "мин · напишите: «$NgPhrase»"; $lblPauseHint.Location = New-Object System.Drawing.Point(66, 25); $lblPauseHint.Size = New-Object System.Drawing.Size(256, 18)
$grpPause.Controls.Add($lblPauseHint)
$txtPhrase = New-Object System.Windows.Forms.TextBox
$txtPhrase.Location = New-Object System.Drawing.Point(10, 56); $txtPhrase.Size = New-Object System.Drawing.Size(200, 24)
$grpPause.Controls.Add($txtPhrase)
$btnPause = New-Object System.Windows.Forms.Button
$btnPause.Text = 'Пауза'; $btnPause.Location = New-Object System.Drawing.Point(218, 54); $btnPause.Size = New-Object System.Drawing.Size(100, 26)
$grpPause.Controls.Add($btnPause)

$lblMsg = New-NgLabel '' 16 382 330 18
$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = 'Запускать при входе'; $chkAuto.Location = New-Object System.Drawing.Point(16, 402); $chkAuto.AutoSize = $true
$form.Controls.Add($chkAuto)
$btnLog = New-NgButton 'Журнал' 230 398 54
$btnQuit = New-NgButton 'Выход' 290 398 54

$script:Refreshing = $false
function Show-NgMessage([string]$Text, [bool]$IsError = $false) {
    $lblMsg.Text = $Text.TrimStart('✓', '✗', ' ')
    $lblMsg.ForeColor = $(if ($IsError) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DimGray })
}

function Update-NgUi {
    Read-NgConfig
    $s = Get-NgStatus
    $state = Get-NgState $s
    $tray.Icon = Get-NgIcon $state
    $tip = "Night Guard · $(Get-NgStateText $s)"
    $tray.Text = $(if ($tip.Length -gt 63) { $tip.Substring(0, 63) } else { $tip })
    $miStatus.Text = Get-NgStateText $s
    if (-not $form.Visible) { return }
    $script:Refreshing = $true
    try {
        $picIcon.Image = (Get-NgIcon $state).ToBitmap()
        $lblState.Text = Get-NgStateText $s
        $lblSub.Text = "Сейчас $($s.now) · блокировок сегодня: $($s.blocks_today)"
        $chkEnabled.Checked = $s.enabled
        $locked = $s.enabled -and $s.in_window   # pause never unlocks settings
        $chkEnabled.Enabled = -not $locked
        if (-not $script:ScheduleEdited) {
            $dtStart.Value = [datetime]::ParseExact($s.start, 'HH:mm', $Inv)
            $dtEnd.Value = [datetime]::ParseExact($s.end, 'HH:mm', $Inv)
        }
        foreach ($c in @($dtStart, $dtEnd, $btnSave)) { $c.Enabled = -not $locked }
        $lblLock.Text = $(if ($locked) { 'Ночью расписание менять нельзя.' } else { '' })
        $btnClaude.Text = $(if ($s.claude_installed) { 'Отключить' } else { 'Подключить' })
        $btnClaude.Enabled = $s.claude_present -and -not ($locked -and $s.claude_installed)
        $lblClaude.Text = 'Claude Code — ' + $(if (-not $s.claude_present) { 'не найден' } elseif ($s.claude_installed) { 'подключён' } else { 'не подключён' })
        $btnCodex.Text = $(if ($s.codex_installed) { 'Отключить' } else { 'Подключить' })
        $btnCodex.Enabled = $s.codex_present -and -not ($locked -and $s.codex_installed)
        $lblCodex.Text = 'Codex — ' + $(if (-not $s.codex_present) { 'не найден' } elseif ($s.codex_installed) { 'подключён' } else { 'не подключён' })
        $lblCodexNote.Visible = $s.codex_installed
        $grpPause.Visible = $s.blocking
        $numPause.Maximum = [math]::Max(1, $s.pause_max)
        $btnPause.Enabled = ($txtPhrase.Text.Trim() -eq $NgPhrase)
        $chkAuto.Checked = Test-Path -LiteralPath $script:StartupLnk
    } finally { $script:Refreshing = $false }
}

function Invoke-NgAction([scriptblock]$Action) {
    try {
        $out = @(& $Action)
        Show-NgMessage ([string]($out | Select-Object -First 1))
        $script:ScheduleEdited = $false
    } catch { Show-NgMessage $_.Exception.Message $true }
    Update-NgUi
}

$script:ScheduleEdited = $false
$dtStart.Add_ValueChanged({ if (-not $script:Refreshing) { $script:ScheduleEdited = $true } })
$dtEnd.Add_ValueChanged({ if (-not $script:Refreshing) { $script:ScheduleEdited = $true } })
$btnSave.Add_Click({ Invoke-NgAction { Set-NgSchedule $dtStart.Value.ToString('HH:mm', $Inv) $dtEnd.Value.ToString('HH:mm', $Inv) } })
$chkEnabled.Add_CheckedChanged({
    if ($script:Refreshing) { return }
    if ($chkEnabled.Checked) { Invoke-NgAction { Enable-NightGuard } } else { Invoke-NgAction { Disable-NightGuard } }
})
$btnClaude.Add_Click({ if ((Get-NgStatus).claude_installed) { Invoke-NgAction { Uninstall-NightGuard 'claude' } } else { Invoke-NgAction { Install-NightGuard 'claude' } } })
$btnCodex.Add_Click({ if ((Get-NgStatus).codex_installed) { Invoke-NgAction { Uninstall-NightGuard 'codex' } } else { Invoke-NgAction { Install-NightGuard 'codex' } } })
$txtPhrase.Add_TextChanged({ $btnPause.Enabled = ($txtPhrase.Text.Trim() -eq $NgPhrase) })
$btnPause.Add_Click({ $p = $txtPhrase.Text; $txtPhrase.Text = ''; Invoke-NgAction { Start-NgPause ([string][int]$numPause.Value) $p } })
$chkAuto.Add_CheckedChanged({
    if ($script:Refreshing) { return }
    try { Set-NgAutostart $chkAuto.Checked; Show-NgMessage '' } catch { Show-NgMessage "Автозапуск: $($_.Exception.Message)" $true }
})
$btnLog.Add_Click({
    if (Test-Path -LiteralPath $script:NgLog) { Start-Process notepad.exe -ArgumentList "`"$script:NgLog`"" }
    else { Show-NgMessage 'Журнал пока пуст — ни одной блокировки.' }
})
$btnQuit.Add_Click({ $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$form.Add_FormClosing({ param($s, $e) if ($e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; $form.Hide() } })

function Show-NgWindow {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(($wa.Right - $form.Width - 12), ($wa.Bottom - $form.Height - 12))
    $lblMsg.Text = ''
    $form.Show(); $form.Activate()
    Update-NgUi
}

# ---------- tray icon ----------
$tray = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miStatus = $menu.Items.Add('…'); $miStatus.Enabled = $false
[void]$menu.Items.Add('-')
$miOpen = $menu.Items.Add('Настройки…'); $miOpen.Add_Click({ Show-NgWindow })
$miLog = $menu.Items.Add('Журнал'); $miLog.Add_Click({ $btnLog.PerformClick() })
[void]$menu.Items.Add('-')
$miQuit = $menu.Items.Add('Выход'); $miQuit.Add_Click({ $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { if ($form.Visible) { $form.Hide() } else { Show-NgWindow } } })
$tray.Visible = $true

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 20000
$timer.Add_Tick({ try { Update-NgUi } catch { } })
$timer.Start()
Update-NgUi

if ($script:OpenAtStart) { Show-NgWindow }
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
$script:Mutex.ReleaseMutex()
