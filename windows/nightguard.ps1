# nightguard — manage Night Guard on Windows (Windows PowerShell 5.1 / PowerShell 7+).
# Usage: nightguard [status [-Json]|install|uninstall|schedule|on|off|pause|log|test|help]
# Dot-sourced with $env:NG_CLI_LIB = '1' it only defines functions (used by the tray app and tests).
param([Parameter(Position = 0)][string]$Command = '', [switch]$Json, [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @())

$NgVersion = '1.1.0'
$NgPhrase = 'я осознанно работаю ночью'
$NgScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$NgHookSrc = Join-Path $NgScriptDir 'night-guard.ps1'
if (-not (Test-Path -LiteralPath $NgHookSrc)) { throw "nightguard: night-guard.ps1 not found next to $($MyInvocation.MyCommand.Path)" }

$env:NG_LIB_ONLY = '1'; . $NgHookSrc; Remove-Item Env:NG_LIB_ONLY
Read-NgConfig

function Initialize-NgCliPaths {
    $uh = Get-NgUserHome
    $script:HookPath = Join-Path $script:NgHome 'night-guard.ps1'
    $claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $uh '.claude' }
    $script:ClaudeSettings = Join-Path $claudeDir 'settings.json'
    $script:CodexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $uh '.codex' }
    $script:CodexHooks = Join-Path $script:CodexDir 'hooks.json'
    $script:BinDir = Join-Path $script:NgHome 'bin'
}
Initialize-NgCliPaths

$Utf8NoBom = New-Object Text.UTF8Encoding($false)

# ---------- state ----------
function Test-NgNightLocked { ($script:NgEnabled -eq 1) -and (Test-NgInWindow) -and ((Get-NgPauseLeft) -eq 0) }
function Assert-NgDay {
    if (Test-NgNightLocked) { throw "Сейчас ночь ($script:NgStart–$script:NgEnd): менять настройки нельзя. Это и есть смысл ограничителя." }
}
function Test-NgFileHasHook([string]$Path) {
    (Test-Path -LiteralPath $Path) -and ([IO.File]::ReadAllText($Path) -match '\.night-guard/night-guard\.ps1')
}
function Test-NgClaudeInstalled { Test-NgFileHasHook $script:ClaudeSettings }
function Test-NgCodexInstalled { Test-NgFileHasHook $script:CodexHooks }
function Get-NgBlocksToday {
    if (-not (Test-Path -LiteralPath $script:NgLog)) { return 0 }
    $today = Get-Date -Format 'yyyy-MM-dd'
    @([IO.File]::ReadAllLines($script:NgLog) | Where-Object { $_.StartsWith($today) -and $_ -notmatch ' pause ' }).Count
}

function Write-NgConfig {
    if (-not (Test-Path -LiteralPath $script:NgHome)) { New-Item -ItemType Directory -Path $script:NgHome -Force | Out-Null }
    $text = @"
# Night Guard config. Лучше менять через ``nightguard`` или значок в трее.
# Время — 24-часовой формат HH:MM, местное время.
NIGHT_START=$script:NgStart
NIGHT_END=$script:NgEnd
ENABLED=$script:NgEnabled
PAUSE_MAX_MINUTES=$script:NgPauseMax
"@
    $tmp = "$script:NgConf.tmp"
    [IO.File]::WriteAllText($tmp, $text.Replace("`r`n", "`n") + "`n", $Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $script:NgConf -Force
}

# ---------- JSON patching ----------
# The hook command must work whichever shell runs it (cmd, PowerShell, Git Bash), so it is a
# plain executable + arguments with a forward-slash path in double quotes.
function Get-NgHookCommand {
    $p = $script:HookPath.Replace('\', '/')
    "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$p`""
}

function Set-NgProp($Obj, [string]$Name, $Value) {
    if ($Obj.PSObject.Properties[$Name]) { $Obj.$Name = $Value }
    else { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Remove-NgGroups($Groups) {
    # Drop our hook handlers from a list of matcher groups; drop groups left empty.
    $out = New-Object System.Collections.ArrayList
    foreach ($g in @($Groups)) {
        if ($null -eq $g) { continue }
        $kept = @(@($g.hooks) | Where-Object { $null -ne $_ -and ("$($_.command)" -notmatch '\.night-guard/night-guard\.(ps1|sh)') })
        if ($kept.Count -gt 0) { Set-NgProp $g 'hooks' $kept; [void]$out.Add($g) }
    }
    return $out.ToArray()
}

function Read-NgJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return (New-Object PSObject) }
    $raw = [IO.File]::ReadAllText($Path)
    if (-not $raw.Trim()) { return (New-Object PSObject) }
    try { $obj = $raw | ConvertFrom-Json } catch { throw "$Path — невалидный JSON, не трогаю его." }
    if ($obj -isnot [PSCustomObject]) { throw "$Path — ожидался JSON-объект, не трогаю его." }
    return $obj
}

function Save-NgJson([string]$Path, $Obj) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath "$Path.night-guard.bak")) {
        Copy-Item -LiteralPath $Path -Destination "$Path.night-guard.bak"
    }
    $json = ConvertTo-Json -InputObject $Obj -Depth 32
    $null = $json | ConvertFrom-Json   # validate before writing
    $tmp = "$Path.ng.tmp"
    [IO.File]::WriteAllText($tmp, $json + "`n", $Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Add-NgHooks([string]$Path, [string]$Matcher) {
    $obj = Read-NgJson $Path
    if (-not $obj.PSObject.Properties['hooks'] -or $null -eq $obj.hooks) { Set-NgProp $obj 'hooks' (New-Object PSObject) }
    $handler = [PSCustomObject]@{ type = 'command'; command = (Get-NgHookCommand); timeout = 15 }
    $ups = @(Remove-NgGroups $obj.hooks.UserPromptSubmit) + @([PSCustomObject]@{ hooks = @($handler) })
    $ptu = @(Remove-NgGroups $obj.hooks.PreToolUse) + @([PSCustomObject]@{ matcher = $Matcher; hooks = @($handler) })
    Set-NgProp $obj.hooks 'UserPromptSubmit' $ups
    Set-NgProp $obj.hooks 'PreToolUse' $ptu
    Save-NgJson $Path $obj
}

function Remove-NgHooks([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $obj = Read-NgJson $Path
    if (-not $obj.PSObject.Properties['hooks'] -or $null -eq $obj.hooks) { return $false }
    foreach ($p in @($obj.hooks.PSObject.Properties)) {
        $left = @(Remove-NgGroups $p.Value)
        if ($left.Count -gt 0) { $obj.hooks.($p.Name) = $left } else { $obj.hooks.PSObject.Properties.Remove($p.Name) }
    }
    if (@($obj.hooks.PSObject.Properties).Count -eq 0) { $obj.PSObject.Properties.Remove('hooks') }
    Save-NgJson $Path $obj
    return $true
}

# ---------- commands ----------
function Install-NgFiles {
    foreach ($d in @($script:NgHome, $script:BinDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $src = (Resolve-Path -LiteralPath $NgScriptDir).Path.TrimEnd('\', '/')
    $dst = (Resolve-Path -LiteralPath $script:NgHome).Path.TrimEnd('\', '/')
    if ($src -ne $dst) {
        foreach ($f in @('night-guard.ps1', 'nightguard.ps1', 'tray.ps1')) {
            $from = Join-Path $NgScriptDir $f
            if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $script:NgHome $f) -Force }
        }
    }
    # `nightguard` command for cmd / PowerShell
    $cmdShim = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%USERPROFILE%\.night-guard\nightguard.ps1`" %*`r`n"
    if ($env:NIGHT_GUARD_HOME) { $cmdShim = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script:NgHome\nightguard.ps1`" %*`r`n" }
    [IO.File]::WriteAllText((Join-Path $script:BinDir 'nightguard.cmd'), $cmdShim, (New-Object Text.ASCIIEncoding))
    if (-not $env:NG_NO_PATH) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not (@($userPath -split ';') -contains $script:BinDir)) {
            [Environment]::SetEnvironmentVariable('Path', (@(@($userPath -split ';') | Where-Object { $_ }) + $script:BinDir) -join ';', 'User')
        }
    }
    Write-NgConfig
}

function Install-NightGuard([string]$Target = 'all') {
    $out = New-Object System.Collections.ArrayList
    Install-NgFiles
    [void]$out.Add("✓ Файлы установлены в $script:NgHome, команда: nightguard (откройте новый терминал)")
    if ($Target -in 'all', 'claude') {
        if (Test-Path -LiteralPath (Split-Path -Parent $script:ClaudeSettings)) {
            Add-NgHooks $script:ClaudeSettings '*'; [void]$out.Add("✓ Claude Code: хуки добавлены в $script:ClaudeSettings")
        } else { [void]$out.Add('• Claude Code не найден — пропускаю.') }
    }
    if ($Target -in 'all', 'codex') {
        if (Test-Path -LiteralPath $script:CodexDir) {
            Add-NgHooks $script:CodexHooks '.*'; [void]$out.Add("✓ Codex: хуки добавлены в $script:CodexHooks")
            [void]$out.Add('  ! Codex запускает хуки только после одобрения: откройте Codex → /hooks → доверьте хукам Night Guard.')
        } else { [void]$out.Add('• Codex не найден — пропускаю.') }
    }
    $out
}

function Uninstall-NightGuard([string]$Target = 'all', [string]$Phrase = $env:NG_PHRASE) {
    if (Test-NgNightLocked) { Assert-NgPhrase $Phrase 'удалить Night Guard ночью' }
    $out = New-Object System.Collections.ArrayList
    if ($Target -in 'all', 'claude') { if (Remove-NgHooks $script:ClaudeSettings) { [void]$out.Add('✓ Claude Code: хуки удалены') } }
    if ($Target -in 'all', 'codex') {
        if (Remove-NgHooks $script:CodexHooks) {
            if (([IO.File]::ReadAllText($script:CodexHooks) -replace '\s', '') -eq '{}') { Remove-Item -LiteralPath $script:CodexHooks -Force }
            [void]$out.Add('✓ Codex: хуки удалены')
        }
    }
    if ($Target -eq 'all') {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -and -not $env:NG_NO_PATH) {
            [Environment]::SetEnvironmentVariable('Path', (@($userPath -split ';') | Where-Object { $_ -and $_ -ne $script:BinDir }) -join ';', 'User')
        }
        foreach ($folder in @('Startup', 'Programs')) {
            $dir = [Environment]::GetFolderPath($folder)
            if ($dir) { $lnk = Join-Path $dir 'Night Guard.lnk'; if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force } }
        }
        [void]$out.Add("• Настройки и журнал оставлены в $script:NgHome (удалите папку вручную, если не нужны).")
    }
    $out
}

function Set-NgSchedule([string]$Start, [string]$End) {
    $s = ConvertTo-NgMinutes $Start; if ($null -eq $s) { throw "Неверное время: $Start (нужно HH:MM)" }
    $e = ConvertTo-NgMinutes $End; if ($null -eq $e) { throw "Неверное время: $End (нужно HH:MM)" }
    if ($s -eq $e) { throw 'Начало и конец совпадают — окно было бы пустым.' }
    Assert-NgDay
    $script:NgStart = Format-NgTime $s; $script:NgEnd = Format-NgTime $e
    Write-NgConfig
    "✓ Ночь теперь: $script:NgStart–$script:NgEnd"
}

function Enable-NightGuard { $script:NgEnabled = 1; Write-NgConfig; "✓ Night Guard включён ($script:NgStart–$script:NgEnd)." }
function Disable-NightGuard { Assert-NgDay; $script:NgEnabled = 0; Write-NgConfig; '✓ Night Guard выключен. Включить: nightguard on' }

function Assert-NgPhrase([string]$Phrase, [string]$What) {
    if (-not $Phrase) {
        if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
            Write-Host "Чтобы $What, напишите: $NgPhrase"
            $Phrase = Read-Host '>'
        } else { throw "Нужно подтверждение. Передайте NG_PHRASE=`"$NgPhrase`"." }
    }
    if ($Phrase.Trim() -ne $NgPhrase) { throw 'Фраза не совпала. Иди спать.' }
}

function Get-NgNightId {
    $s = ConvertTo-NgMinutes $script:NgStart
    if ((Get-NgNowMinutes) -lt $s) { return (Get-Date).AddDays(-1).ToString('yyyy-MM-dd') }
    (Get-Date).ToString('yyyy-MM-dd')
}

function Start-NgPause([string]$Minutes = '15', [string]$Phrase = $env:NG_PHRASE) {
    if ($Minutes -notmatch '^\d{1,2}$') { throw "Минуты: число от 1 до $script:NgPauseMax" }
    $min = [int]$Minutes
    if ($min -lt 1 -or $min -gt $script:NgPauseMax) { throw "Пауза: от 1 до $script:NgPauseMax минут." }
    if (-not ($script:NgEnabled -eq 1 -and (Test-NgInWindow))) { throw 'Сейчас не ночь — пауза не нужна.' }
    if ((Get-NgPauseLeft) -gt 0) { throw 'Пауза уже идёт.' }
    $lastFile = Join-Path $script:NgHome 'last_pause'
    if ((Test-Path -LiteralPath $lastFile) -and ([IO.File]::ReadAllText($lastFile).Trim() -eq (Get-NgNightId))) { throw 'Пауза уже была этой ночью. Одна за ночь.' }
    Assert-NgPhrase $Phrase "поставить паузу на $min мин"
    [IO.File]::WriteAllText($script:NgPauseFile, [string]((Get-NgEpoch) + $min * 60), $Utf8NoBom)
    [IO.File]::WriteAllText($lastFile, (Get-NgNightId), $Utf8NoBom)
    Write-NgLog "pause ${min}m"
    "✓ Пауза на $min мин. Потом блокировка вернётся сама."
}

function Get-NgStatus {
    [PSCustomObject]@{
        version = $NgVersion; enabled = ($script:NgEnabled -eq 1); start = $script:NgStart; end = $script:NgEnd
        now = (Get-Date -Format 'HH:mm'); in_window = [bool](Test-NgInWindow); blocking = [bool](Test-NgBlocking)
        pause_left = (Get-NgPauseLeft); pause_max = $script:NgPauseMax
        claude_present = (Test-Path -LiteralPath (Split-Path -Parent $script:ClaudeSettings)); claude_installed = [bool](Test-NgClaudeInstalled)
        codex_present = (Test-Path -LiteralPath $script:CodexDir); codex_installed = [bool](Test-NgCodexInstalled)
        blocks_today = (Get-NgBlocksToday)
    }
}

function Show-NgStatus {
    $s = Get-NgStatus
    Write-Host ''
    if (-not $s.enabled) { Write-Host '  ○ Night Guard выключен' -ForegroundColor Yellow }
    elseif ($s.blocking) { Write-Host "  Ночь — агенты заблокированы до $($s.end)" -ForegroundColor Magenta }
    elseif ($s.pause_left -gt 0) { Write-Host "  Пауза: осталось $([int][math]::Floor($s.pause_left / 60) + 1) мин" -ForegroundColor Yellow }
    else { Write-Host "  День — можно работать. Блокировка с $($s.start)" -ForegroundColor Green }
    Write-Host "  Сейчас $($s.now) · ночь $($s.start)–$($s.end) · блокировок сегодня: $($s.blocks_today)" -ForegroundColor DarkGray
    Write-Host ('  Claude Code: ' + $(if ($s.claude_installed) { 'подключён' } else { 'не подключён' }))
    Write-Host ('  Codex:       ' + $(if ($s.codex_installed) { 'подключён (не забудьте /hooks → trust)' } else { 'не подключён' }))
    Write-Host ''
}

function Test-NgHook {
    $exe = (Get-Process -Id $PID).Path
    $tmpHome = Join-Path ([IO.Path]::GetTempPath()) ('ng-test-' + [guid]::NewGuid())
    $old = @($env:NIGHT_GUARD_FORCE, $env:NIGHT_GUARD_HOME)
    try {
        $env:NIGHT_GUARD_FORCE = '1'; $env:NIGHT_GUARD_HOME = $tmpHome
        $o1 = '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' | & $exe -NoProfile -ExecutionPolicy Bypass -File $NgHookSrc | Out-String
        $o2 = '{"hook_event_name":"UserPromptSubmit","prompt":"x"}' | & $exe -NoProfile -ExecutionPolicy Bypass -File $NgHookSrc | Out-String
    } finally {
        $env:NIGHT_GUARD_FORCE = $old[0]; $env:NIGHT_GUARD_HOME = $old[1]
        Remove-Item -LiteralPath $tmpHome -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($o1 -notmatch '"permissionDecision":"deny"') { throw "Хук не сработал: $o1" }
    if ($o2 -notmatch '"decision":"block"') { throw "Хук не сработал: $o2" }
    '✓ Хук отвечает deny в ночном режиме.'
    '✓ Хук блокирует промпты в ночном режиме.'
}

function Show-NgUsage {
    @"
nightguard — ночной ограничитель для Claude Code и Codex (Windows)

  nightguard                   интерактивное меню
  nightguard status [-Json]    текущее состояние
  nightguard install [all|claude|codex]
  nightguard uninstall [all|claude|codex]
  nightguard schedule 23:00 07:00
  nightguard on | off          включить / выключить (выключить ночью нельзя)
  nightguard pause [мин]       пауза ночью: 1 раз за ночь, до $script:NgPauseMax мин, с подтверждением
  nightguard log [N]           последние блокировки
  nightguard test              проверить, что хук блокирует
"@
}

function Show-NgMenu {
    while ($true) {
        Read-NgConfig; Clear-Host
        Write-Host "  Night Guard v$NgVersion"; Show-NgStatus
        Write-Host '  1) Изменить расписание     4) Подключить к Claude/Codex'
        Write-Host '  2) Включить / выключить    5) Отключить от Claude/Codex'
        Write-Host '  3) Журнал блокировок       6) Пауза (только ночью, 1 раз)'
        Write-Host '  0) Выход'
        $ch = Read-Host '  >'
        try {
            switch ($ch) {
                '1' { $s = Read-Host "  Начало ночи (HH:MM) [$script:NgStart]"; $e = Read-Host "  Конец ночи (HH:MM) [$script:NgEnd]"
                      if (-not $s) { $s = $script:NgStart }; if (-not $e) { $e = $script:NgEnd }; Set-NgSchedule $s $e | Write-Host }
                '2' { if ($script:NgEnabled -eq 1) { Disable-NightGuard | Write-Host } else { Enable-NightGuard | Write-Host } }
                '3' { if (Test-Path -LiteralPath $script:NgLog) { Get-Content -LiteralPath $script:NgLog -Tail 30 -Encoding UTF8 | Write-Host } else { Write-Host '  Журнал пуст.' } }
                '4' { Install-NightGuard 'all' | Write-Host }
                '5' { Uninstall-NightGuard 'all' '' | Write-Host }
                '6' { $m = Read-Host '  На сколько минут? [15]'; if (-not $m) { $m = '15' }; Start-NgPause $m '' | Write-Host }
                default { return }
            }
        } catch { Write-Host "  ✗ $($_.Exception.Message)" -ForegroundColor Red }
        [void](Read-Host '  Enter — назад в меню')
    }
}

if ($env:NG_CLI_LIB) { return }

# ---------- dispatcher ----------
$utf8 = New-Object Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $utf8 } catch { }
try {
    switch ($Command) {
        '' { if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) { Show-NgMenu } else { Show-NgStatus } }
        'status' { if ($Json -or $Rest -contains '--json') { Get-NgStatus | ConvertTo-Json -Compress } else { Show-NgStatus } }
        'install' { Install-NightGuard $(if ($Rest.Count) { $Rest[0] } else { 'all' }) }
        'uninstall' { Uninstall-NightGuard $(if ($Rest.Count) { $Rest[0] } else { 'all' }) }
        'schedule' { if ($Rest.Count -ne 2) { throw 'Использование: nightguard schedule 23:00 07:00' }; Set-NgSchedule $Rest[0] $Rest[1] }
        { $_ -in 'on', 'enable' } { Enable-NightGuard }
        { $_ -in 'off', 'disable' } { Disable-NightGuard }
        'pause' { Start-NgPause $(if ($Rest.Count) { $Rest[0] } else { '15' }) }
        'log' { $n = if ($Rest.Count) { [int]$Rest[0] } else { 20 }; if (Test-Path -LiteralPath $script:NgLog) { Get-Content -LiteralPath $script:NgLog -Tail $n -Encoding UTF8 } else { '• Журнал пуст.' } }
        'test' { Test-NgHook }
        { $_ -in 'version', '--version', '-v' } { $NgVersion }
        { $_ -in 'help', '-h', '--help' } { Show-NgUsage }
        default { Show-NgUsage; exit 1 }
    }
} catch {
    [Console]::Error.WriteLine("✗ $($_.Exception.Message)")
    exit 1
}
