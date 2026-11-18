# Night Guard test suite for Windows (runs under Windows PowerShell 5.1 and PowerShell 7).
# Uses an isolated temporary profile directory; never touches real configs or the user PATH.
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Win = Join-Path $Root 'windows'
$Hook = Join-Path $Win 'night-guard.ps1'
$Cli = Join-Path $Win 'nightguard.ps1'
$Exe = (Get-Process -Id $PID).Path
$Phrase = 'я осознанно работаю ночью'

$T = Join-Path ([IO.Path]::GetTempPath()) ('ng-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $T | Out-Null
$env:USERPROFILE = Join-Path $T 'home'
foreach ($d in @('.claude', '.codex')) { New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE $d) -Force | Out-Null }
foreach ($v in 'NIGHT_GUARD_HOME', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'NIGHT_GUARD_FORCE', 'NG_PHRASE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
$env:NG_NO_PATH = '1'
$NgDir = Join-Path $env:USERPROFILE '.night-guard'
$Utf8 = New-Object Text.UTF8Encoding($false)

$script:Pass = 0; $script:Fail = 0
function T([string]$Name, [scriptblock]$Check) {
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $ok = $false; $Name += "  ($($_.Exception.Message))" }
    if ($ok) { $script:Pass++; Write-Host "  ok   $Name" } else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
function Invoke-Hook([string]$Json) {
    $out = $Json | & $Exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Hook 2>$null
    [PSCustomObject]@{ Out = (@($out) -join "`n"); Code = $LASTEXITCODE }
}
function Invoke-Cli([string[]]$CliArgs) {
    $out = & $Exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Cli @CliArgs 2>&1
    [PSCustomObject]@{ Out = (@($out | ForEach-Object { "$_" }) -join "`n"); Code = $LASTEXITCODE }
}
function Set-Conf($s, $e, $en = 1) {
    New-Item -ItemType Directory -Path $NgDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $NgDir 'config'), "NIGHT_START=$s`nNIGHT_END=$e`nENABLED=$en`n", $Utf8)
}

$env:NG_LIB_ONLY = '1'; . $Hook; Remove-Item Env:NG_LIB_ONLY
$now = Get-NgNowMinutes
function HM([int]$m) { Format-NgTime ((($m % 1440) + 1440) % 1440) }
$NightS = HM ($now - 1); $NightE = HM ($now + 60); $DayS = HM ($now + 120); $DayE = HM ($now + 180)

Write-Host "PowerShell $($PSVersionTable.PSVersion) ($Exe)"
Write-Host 'files'
foreach ($f in Get-ChildItem -Path $Root -Filter *.ps1 -Recurse) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    T "$($f.Name) has UTF-8 BOM (needed by Windows PowerShell 5.1)" { $b.Length -gt 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF }
    $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    T "$($f.Name) parses without errors" { @($errs).Count -eq 0 }
}

Write-Host 'time parsing'
T '07:30 -> 450' { (ConvertTo-NgMinutes '07:30') -eq 450 }
T '7 -> 420' { (ConvertTo-NgMinutes '7') -eq 420 }
T '24:00 invalid' { $null -eq (ConvertTo-NgMinutes '24:00') }
T '7:60 invalid' { $null -eq (ConvertTo-NgMinutes '7:60') }
T 'garbage invalid' { $null -eq (ConvertTo-NgMinutes 'rm -rf') }

Write-Host 'window logic'
$script:NgStart = '23:00'; $script:NgEnd = '07:00'
T 'wrap: 23:00 inside' { Test-NgInWindow 1380 }
T 'wrap: 03:00 inside' { Test-NgInWindow 180 }
T 'wrap: 07:00 outside' { -not (Test-NgInWindow 420) }
T 'wrap: 12:00 outside' { -not (Test-NgInWindow 720) }
$script:NgStart = '01:00'; $script:NgEnd = '05:30'
T 'plain: 05:29 inside' { Test-NgInWindow 329 }
T 'plain: 00:59 outside' { -not (Test-NgInWindow 59) }
$script:NgStart = '07:00'; $script:NgEnd = '07:00'
T 'equal start/end never blocks' { -not (Test-NgInWindow 420) }

Write-Host 'hook'
Set-Conf $DayS $DayE
T 'day: allows silently' { $r = Invoke-Hook '{"hook_event_name":"PreToolUse"}'; $r.Code -eq 0 -and -not $r.Out.Trim() }
Set-Conf $NightS $NightE
T 'night: PreToolUse deny is valid JSON' { ((Invoke-Hook '{"hook_event_name": "PreToolUse", "tool_name": "Bash"}').Out | ConvertFrom-Json).hookSpecificOutput.permissionDecision -eq 'deny' }
T 'night: prompt blocked' { ((Invoke-Hook '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}').Out | ConvertFrom-Json).decision -eq 'block' }
T 'night: Cyrillic message survives encoding' { ((Invoke-Hook '{"hook_event_name":"UserPromptSubmit"}').Out | ConvertFrom-Json).reason -match 'вайбкодинг' }
T 'night: unknown event -> exit 2' { (Invoke-Hook '{}').Code -eq 2 }
T 'night: blocks are logged' { [IO.File]::ReadAllText((Join-Path $NgDir 'blocked.log')) -match 'PreToolUse Bash' }
Set-Conf $NightS $NightE 0
T 'disabled: allows' { -not (Invoke-Hook '{"hook_event_name":"PreToolUse"}').Out.Trim() }

Write-Host 'config safety'
$pw = Join-Path $T 'pwned'
[IO.File]::WriteAllText((Join-Path $NgDir 'config'), "NIGHT_START=$NightS`nNIGHT_END=$NightE`n`$(New-Item '$pw')`nNew-Item '$pw'`n", $Utf8)
[void](Invoke-Hook '{"hook_event_name":"PreToolUse"}')
T 'config is never executed' { -not (Test-Path -LiteralPath $pw) }
[IO.File]::WriteAllText((Join-Path $NgDir 'config'), "NIGHT_START=banana`nNIGHT_END=`n", $Utf8)
Initialize-NgPaths; Read-NgConfig
T 'invalid values fall back to 23:00-07:00 (fail-closed)' { $script:NgStart -eq '23:00' -and $script:NgEnd -eq '07:00' }
[IO.File]::WriteAllText((Join-Path $NgDir 'config'), "NIGHT_START=23   # comment`r`nNIGHT_END=7`r`n", $Utf8)
Read-NgConfig
T 'CRLF + old format parsed' { $script:NgStart -eq '23:00' -and $script:NgEnd -eq '07:00' }

Write-Host 'install / uninstall'
Remove-Item -LiteralPath $NgDir -Recurse -Force
$S = Join-Path $env:USERPROFILE '.claude\settings.json'; $X = Join-Path $env:USERPROFILE '.codex\hooks.json'
[IO.File]::WriteAllText($S, '{"permissions":{"allow":["Read(*)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo other"}]}]}}', $Utf8)
$r1 = Invoke-Cli @('install'); $r2 = Invoke-Cli @('install')
T 'install exits 0' { $r1.Code -eq 0 -and $r2.Code -eq 0 }
T 'files installed' { (Test-Path (Join-Path $NgDir 'night-guard.ps1')) -and (Test-Path (Join-Path $NgDir 'tray.ps1')) -and (Test-Path (Join-Path $NgDir 'bin\nightguard.cmd')) }
$sj = [IO.File]::ReadAllText($S) | ConvertFrom-Json
T 'claude: idempotent (1 entry each)' { @($sj.hooks.PreToolUse | ForEach-Object { $_.hooks } | Where-Object { $_.command -match 'night-guard' }).Count -eq 1 -and @($sj.hooks.UserPromptSubmit).Count -eq 1 }
T 'claude: other hooks kept' { @($sj.hooks.PreToolUse | Where-Object { $_.matcher -eq 'Bash' }).Count -eq 1 }
T 'claude: other settings kept' { $sj.permissions.allow[0] -eq 'Read(*)' }
T 'claude: hooks are real JSON arrays (raw text)' { ([IO.File]::ReadAllText($S) -match '"PreToolUse":\s*\[') -and ([IO.File]::ReadAllText($S) -match '"hooks":\s*\[\s*\{\s*"type"') -and -not ([IO.File]::ReadAllText($S) -match '\[\s*\[') }
T 'codex: hooks.json created' { (@(([IO.File]::ReadAllText($X) | ConvertFrom-Json).hooks.PreToolUse)[0]).matcher -eq '.*' }
T 'status -Json valid' { $j = (Invoke-Cli @('status', '-Json')).Out | ConvertFrom-Json; $j.claude_installed -and $j.codex_installed }
T 'installed CLI self-test' { (& $Exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $NgDir 'nightguard.ps1') test 2>&1 | Out-String) -match 'deny' }

Write-Host 'hook command runs under every shell an agent may use'
Set-Conf $NightS $NightE
$cmdLine = @($sj.hooks.UserPromptSubmit)[0].hooks[0].command
$payload = '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
T 'via cmd.exe' { (($payload | cmd.exe /d /c $cmdLine) -join '') -match '"deny"' }
T 'via PowerShell' { (($payload | & $Exe -NoProfile -Command $cmdLine) -join '') -match '"deny"' }
$gitBash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($gitBash) { T 'via Git Bash' { (($payload | & $gitBash -c $cmdLine) -join '') -match '"deny"' } } else { Write-Host '  skip Git Bash (not installed)' }

Set-Conf $DayS $DayE
$r = Invoke-Cli @('uninstall')
if ($r.Code -ne 0) { Write-Host "       > $($r.Out)" }
$sj = [IO.File]::ReadAllText($S) | ConvertFrom-Json
T 'uninstall exits 0' { $r.Code -eq 0 }
T 'claude: only our hooks removed' { ([IO.File]::ReadAllText($S) -notmatch 'night-guard') -and (@($sj.hooks.PreToolUse)[0].matcher -eq 'Bash') }
T 'codex: empty hooks.json removed' { -not (Test-Path $X) }
T 'backup created' { Test-Path "$S.night-guard.bak" }

Write-Host 'night lock'
[void](Invoke-Cli @('install'))
Set-Conf $NightS $NightE
T 'schedule refused at night' { (Invoke-Cli @('schedule', '01:00', '02:00')).Code -ne 0 }
T 'off refused at night' { (Invoke-Cli @('off')).Code -ne 0 }
T 'uninstall needs phrase at night' { (Invoke-Cli @('uninstall')).Code -ne 0 -and ([IO.File]::ReadAllText($S) -match 'night-guard') }
$env:NG_PHRASE = 'nope'
T 'pause: wrong phrase refused' { (Invoke-Cli @('pause', '5')).Code -ne 0 }
$env:NG_PHRASE = $Phrase
T 'pause: over max refused' { (Invoke-Cli @('pause', '99')).Code -ne 0 }
T 'pause: works with phrase' { (Invoke-Cli @('pause', '5')).Code -eq 0 }
T 'pause: hook allows' { -not (Invoke-Hook '{"hook_event_name":"PreToolUse"}').Out.Trim() }
Remove-Item (Join-Path $NgDir 'pause_until')
T 'pause: only once per night' { (Invoke-Cli @('pause', '5')).Code -ne 0 }
Remove-Item Env:NG_PHRASE
[IO.File]::WriteAllText((Join-Path $NgDir 'pause_until'), [string]((Get-NgEpoch) + 99999), $Utf8)
T 'tampered pause file ignored' { (Invoke-Hook '{"hook_event_name":"PreToolUse"}').Out -match 'deny' }
Set-Conf $DayS $DayE
T 'day: schedule allowed' { (Invoke-Cli @('schedule', '23:30', '06:45')).Code -eq 0 -and ([IO.File]::ReadAllText((Join-Path $NgDir 'config')) -match 'NIGHT_START=23:30') }
T 'schedule rejects bad time' { (Invoke-Cli @('schedule', '25:00', '07:00')).Code -ne 0 }

Write-Host 'audit regressions'
Set-Conf $NightS $NightE
foreach ($f in 'last_pause', 'pause_until') { Remove-Item (Join-Path $NgDir $f) -ErrorAction SilentlyContinue }
$env:NG_PHRASE = $Phrase; [void](Invoke-Cli @('pause', '5')); Remove-Item Env:NG_PHRASE
T 'pause active (precondition)' { Test-Path (Join-Path $NgDir 'pause_until') }
T 'during pause: off still refused' { (Invoke-Cli @('off')).Code -ne 0 -and ([IO.File]::ReadAllText((Join-Path $NgDir 'config')) -match 'ENABLED=1') }
T 'during pause: schedule still refused' { (Invoke-Cli @('schedule', '01:00', '02:00')).Code -ne 0 }
T 'during pause: uninstall needs phrase' { (Invoke-Cli @('uninstall')).Code -ne 0 -and ([IO.File]::ReadAllText($S) -match 'night-guard') }
T 'status -Json reports in_window during pause' { $j = (Invoke-Cli @('status', '-Json')).Out | ConvertFrom-Json; $j.in_window -and -not $j.blocking }
T 'no Read-Host hang without console (NG_NO_PROMPT)' {
    $env:NG_NO_PROMPT = '1'; $env:NG_CLI_LIB = '1'
    try { . $Cli; Uninstall-NightGuard 'claude' ''; $false } catch { $_.Exception.Message -match 'NG_PHRASE' } finally { Remove-Item Env:NG_NO_PROMPT, Env:NG_CLI_LIB -ErrorAction SilentlyContinue }
}
Remove-Item (Join-Path $NgDir 'pause_until') -ErrorAction SilentlyContinue

$SpHome = Join-Path $T 'with space'
New-Item -ItemType Directory -Path (Join-Path $SpHome '.claude') -Force | Out-Null
$saved = $env:USERPROFILE; $env:USERPROFILE = $SpHome
[void](Invoke-Cli @('install', 'claude'))
$env:USERPROFILE = $saved
$spCmd = @((([IO.File]::ReadAllText((Join-Path $SpHome '.claude\settings.json'))) | ConvertFrom-Json).hooks.PreToolUse)[-1].hooks[0].command
$env:NIGHT_GUARD_FORCE = '1'
T 'profile path with a space: hook still runs via cmd.exe' { (($payload | cmd.exe /d /c $spCmd) -join '') -match '"deny"' }
Remove-Item Env:NIGHT_GUARD_FORCE

Set-Conf $DayS $DayE
[IO.File]::WriteAllText($S, '{"hooks":{"Notification":[{"matcher":"x"}],"Stop":[]}}', $Utf8)
[void](Invoke-Cli @('install', 'claude')); [void](Invoke-Cli @('uninstall', 'claude'))
$raw = [IO.File]::ReadAllText($S)
T 'uninstall keeps groups without hooks + empty events' { ($raw -notmatch 'night-guard') -and ($raw -match '"matcher":\s*"x"') -and ($raw -match '"Stop"') }
[IO.File]::WriteAllText($S, '', $Utf8)
T 'empty settings.json is treated as {}' { (Invoke-Cli @('install', 'claude')).Code -eq 0 -and ([IO.File]::ReadAllText($S) -match 'PreToolUse') }
T 'hook timeout is generous (60s) for cold PowerShell starts' { ([IO.File]::ReadAllText($S) | ConvertFrom-Json).hooks.PreToolUse[-1].hooks[0].timeout -eq 60 }
$prev = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = 'fi-FI'
    T 'fi-FI culture: time stays HH:mm' { (Get-Date -Format 'HH\:mm') -match '^\d\d:\d\d$' }
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $prev }

Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "passed: $script:Pass  failed: $script:Fail"
if ($script:Fail -gt 0) { exit 1 }
