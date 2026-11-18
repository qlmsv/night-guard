# Night Guard — hook for Claude Code and Codex on Windows.
# Blocks prompts (UserPromptSubmit) and tool calls (PreToolUse) during the night window.
# Works in Windows PowerShell 5.1 and PowerShell 7+. No modules or dependencies.
# Dot-sourced with $env:NG_LIB_ONLY = '1' it only defines functions (used by nightguard.ps1 and the tray app).

function Get-NgUserHome {
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    return $env:HOME
}

function Initialize-NgPaths {
    $script:NgHome = if ($env:NIGHT_GUARD_HOME) { $env:NIGHT_GUARD_HOME } else { Join-Path (Get-NgUserHome) '.night-guard' }
    $script:NgConf = Join-Path $script:NgHome 'config'
    $script:NgLog = Join-Path $script:NgHome 'blocked.log'
    $script:NgPauseFile = Join-Path $script:NgHome 'pause_until'
    $script:NgLogMax = 2000
}

function ConvertTo-NgMinutes([string]$Value) {
    # "7", "07", "7:30", "07:30" -> minutes since midnight, or $null if invalid.
    if ($Value -notmatch '^(\d{1,2})(?::(\d{2}))?$') { return $null }
    $h = [int]$Matches[1]
    $m = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
    if ($h -gt 23 -or $m -gt 59) { return $null }
    return $h * 60 + $m
}

function Format-NgTime([int]$Minutes) { '{0:D2}:{1:D2}' -f [int][math]::Floor($Minutes / 60), ($Minutes % 60) }

function Read-NgConfig {
    # Parsed as data, never executed. Invalid values keep safe defaults.
    $script:NgStart = '23:00'; $script:NgEnd = '07:00'; $script:NgEnabled = 1; $script:NgPauseMax = 30
    if (-not (Test-Path -LiteralPath $script:NgConf)) { return }
    foreach ($line in [IO.File]::ReadAllLines($script:NgConf)) {
        $i = $line.IndexOf('=')
        if ($i -lt 1) { continue }
        $key = $line.Substring(0, $i).Trim()
        $val = $line.Substring($i + 1)
        $hash = $val.IndexOf('#'); if ($hash -ge 0) { $val = $val.Substring(0, $hash) }
        $val = ($val -replace '[\s"'']', '')
        switch ($key) {
            'NIGHT_START' { $v = ConvertTo-NgMinutes $val; if ($null -ne $v) { $script:NgStart = Format-NgTime $v } }
            'NIGHT_END'   { $v = ConvertTo-NgMinutes $val; if ($null -ne $v) { $script:NgEnd = Format-NgTime $v } }
            'ENABLED'     { if ($val -eq '0' -or $val -eq '1') { $script:NgEnabled = [int]$val } }
            'PAUSE_MAX_MINUTES' { if ($val -match '^\d{1,2}$') { $script:NgPauseMax = [int]$val } }
        }
    }
}

function Get-NgNowMinutes { $n = Get-Date; return $n.Hour * 60 + $n.Minute }
function Get-NgEpoch { [int64][Math]::Floor(([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds) }

function Test-NgInWindow([Nullable[int]]$Now = $null) {
    if ($null -eq $Now) { $Now = Get-NgNowMinutes }
    $s = ConvertTo-NgMinutes $script:NgStart; $e = ConvertTo-NgMinutes $script:NgEnd
    if ($s -eq $e) { return $false }
    if ($s -lt $e) { return ($Now -ge $s -and $Now -lt $e) }
    return ($Now -ge $s -or $Now -lt $e)
}

function Get-NgPauseLeft {
    # Seconds left in an active pause (0 if none). Ignores tampered/oversized values.
    if (-not (Test-Path -LiteralPath $script:NgPauseFile)) { return 0 }
    $raw = ([IO.File]::ReadAllText($script:NgPauseFile)) -replace '[^0-9]', ''
    if (-not $raw -or $raw.Length -gt 12) { return 0 }
    $left = [int64]$raw - (Get-NgEpoch)
    if ($left -le 0 -or $left -gt ($script:NgPauseMax * 60)) { return 0 }
    return [int]$left
}

function Test-NgBlocking {
    if ($env:NIGHT_GUARD_FORCE) { return $true }
    if ($script:NgEnabled -ne 1) { return $false }
    if (-not (Test-NgInWindow)) { return $false }
    return ((Get-NgPauseLeft) -eq 0)
}

function Write-NgLog([string]$Text) {
    try {
        if (-not (Test-Path -LiteralPath $script:NgHome)) { New-Item -ItemType Directory -Path $script:NgHome -Force | Out-Null }
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
        [IO.File]::AppendAllText($script:NgLog, $line + "`n", (New-Object Text.UTF8Encoding($false)))
        $lines = [IO.File]::ReadAllLines($script:NgLog)
        if ($lines.Count -gt $script:NgLogMax) {
            $keep = $lines[($lines.Count - [int]($script:NgLogMax / 2))..($lines.Count - 1)]
            [IO.File]::WriteAllLines($script:NgLog, $keep, (New-Object Text.UTF8Encoding($false)))
        }
    } catch { }
}

Initialize-NgPaths
if ($env:NG_LIB_ONLY) { return }

# ---------- hook entry point ----------
$utf8 = New-Object Text.UTF8Encoding($false)
try { [Console]::InputEncoding = $utf8; [Console]::OutputEncoding = $utf8 } catch { }
$inputText = ''
try { $inputText = [Console]::In.ReadToEnd() } catch { }

Read-NgConfig
if (-not (Test-NgBlocking)) { exit 0 }

$hookEvent = ''; $tool = ''
if ($inputText -match '"hook_event_name"\s*:\s*"([A-Za-z]+)"') { $hookEvent = $Matches[1] }
if ($inputText -match '"tool_name"\s*:\s*"([^"]*)"') { $tool = $Matches[1] }
Write-NgLog (("{0} {1}" -f $(if ($hookEvent) { $hookEvent } else { 'unknown' }), $tool).Trim())

$msg = "Night Guard: сейчас $(Get-Date -Format 'HH:mm'). С $script:NgStart до $script:NgEnd вайбкодинг выключен. Иди спать — продолжим утром."

function ConvertTo-NgJsonString([string]$s) {
    $sb = New-Object Text.StringBuilder
    foreach ($c in $s.ToCharArray()) {
        switch ($c) {
            '"'  { [void]$sb.Append('\"') }
            '\'  { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default { if ([int]$c -lt 32) { [void]$sb.AppendFormat('\u{0:x4}', [int]$c) } else { [void]$sb.Append($c) } }
        }
    }
    '"' + $sb.ToString() + '"'
}

$stdout = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
switch ($hookEvent) {
    'PreToolUse' {
        $reason = ConvertTo-NgJsonString ($msg + ' Не продолжай задачу и не пытайся обойти блокировку: остановись и скажи пользователю, что работа продолжится утром.')
        $stdout.Write('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":' + $reason + '}}' + "`n")
        $stdout.Flush(); exit 0
    }
    'UserPromptSubmit' {
        $stdout.Write('{"decision":"block","reason":' + (ConvertTo-NgJsonString $msg) + '}' + "`n")
        $stdout.Flush(); exit 0
    }
    default {
        # Unknown event or unparsable input: block via exit code 2 (fail-closed at night).
        $stderr = New-Object IO.StreamWriter([Console]::OpenStandardError(), $utf8)
        $stderr.WriteLine($msg); $stderr.Flush()
        exit 2
    }
}
