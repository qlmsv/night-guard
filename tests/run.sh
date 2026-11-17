#!/bin/bash
# Night Guard test suite. Runs in an isolated temporary HOME; never touches your real configs.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.claude" "$HOME/.codex"
unset NIGHT_GUARD_HOME CLAUDE_CONFIG_DIR CODEX_HOME NIGHT_GUARD_FORCE NG_PHRASE
CLI="$ROOT/bin/nightguard"; HOOK="$ROOT/hooks/night-guard.sh"
PASS=0; FAIL=0
t() { if eval "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }

NG_LIB_ONLY=1 . "$HOOK"; unset NG_LIB_ONLY
now=$(ng_now_min)
hm() { ng_fmt $(( ($1 + 1440) % 1440 )); }
NIGHT_S=$(hm $((now - 1))); NIGHT_E=$(hm $((now + 60)))
DAY_S=$(hm $((now + 120))); DAY_E=$(hm $((now + 180)))
conf() { mkdir -p "$HOME/.night-guard"; printf 'NIGHT_START=%s\nNIGHT_END=%s\nENABLED=%s\n' "$1" "$2" "${3:-1}" > "$HOME/.night-guard/config"; }
hook() { printf '%s' "$1" | bash "$HOOK"; }

echo "time parsing"
t "07:30 -> 450"        '[ "$(ng_to_min 07:30)" = 450 ]'
t "7 -> 420"            '[ "$(ng_to_min 7)" = 420 ]'
t "24:00 invalid"       '! ng_to_min 24:00'
t "7:60 invalid"        '! ng_to_min 7:60'
t "garbage invalid"     '! ng_to_min "rm -rf"'

echo "window logic"
NG_START=23:00 NG_END=07:00
t "wrap: 23:00 inside"  'ng_in_window 1380'
t "wrap: 03:00 inside"  'ng_in_window 180'
t "wrap: 07:00 outside" '! ng_in_window 420'
t "wrap: 12:00 outside" '! ng_in_window 720'
NG_START=01:00 NG_END=05:30
t "plain: 05:29 inside" 'ng_in_window 329'
t "plain: 00:59 outside" '! ng_in_window 59'
NG_START=07:00 NG_END=07:00
t "equal start/end never blocks" '! ng_in_window 420'

echo "hook"
conf "$DAY_S" "$DAY_E"
t "day: allows silently" '[ -z "$(hook "{\"hook_event_name\":\"PreToolUse\"}")" ]'
conf "$NIGHT_S" "$NIGHT_E"
t "night: PreToolUse deny is valid JSON" 'hook "{\"hook_event_name\": \"PreToolUse\", \"tool_name\": \"Bash\"}" | jq -e ".hookSpecificOutput.permissionDecision == \"deny\""'
t "night: prompt blocked"   'hook "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\"}" | jq -e ".decision == \"block\""'
t "night: unknown event -> exit 2" '! hook "{}"'
t "night: blocks are logged" 'grep -q "PreToolUse Bash" "$HOME/.night-guard/blocked.log"'
conf "$NIGHT_S" "$NIGHT_E" 0
t "disabled: allows"        '[ -z "$(hook "{\"hook_event_name\":\"PreToolUse\"}")" ]'

echo "config safety"
printf 'NIGHT_START=%s\nNIGHT_END=%s\ntouch %s/pwned\n$(touch %s/pwned2)\n' "$NIGHT_S" "$NIGHT_E" "$T" "$T" > "$HOME/.night-guard/config"
hook '{"hook_event_name":"PreToolUse"}' >/dev/null
t "config is never executed" '[ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ]'
printf 'NIGHT_START=banana\nNIGHT_END=\n' > "$HOME/.night-guard/config"
NG_CONF="$HOME/.night-guard/config"; ng_load
t "invalid values fall back to 23:00-07:00 (fail-closed)" '[ "$NG_START" = 23:00 ] && [ "$NG_END" = 07:00 ]'
printf 'NIGHT_START=23   # comment\nNIGHT_END=7\n' > "$HOME/.night-guard/config"; ng_load
t "old v0 config format still parsed" '[ "$NG_START" = 23:00 ] && [ "$NG_END" = 07:00 ]'

echo "install / uninstall"
rm -rf "$HOME/.night-guard"
echo '{"permissions":{"allow":["Read(*)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo other"}]}]}}' > "$HOME/.claude/settings.json"
"$CLI" install >/dev/null 2>&1; "$CLI" install >/dev/null 2>&1
S="$HOME/.claude/settings.json"; X="$HOME/.codex/hooks.json"
t "files installed"              '[ -x "$HOME/.night-guard/night-guard.sh" ] && [ -L "$HOME/.local/bin/nightguard" ]'
t "claude: idempotent (1 entry each)" '[ "$(jq "[.hooks.PreToolUse[].hooks[] | select(.command|contains(\"night-guard\"))] | length" "$S")" = 1 ] && [ "$(jq ".hooks.UserPromptSubmit|length" "$S")" = 1 ]'
t "claude: other hooks kept"     'jq -e ".hooks.PreToolUse[] | select(.matcher==\"Bash\")" "$S"'
t "claude: other settings kept"  'jq -e ".permissions.allow[0]==\"Read(*)\"" "$S"'
t "codex: hooks.json created"    'jq -e ".hooks.PreToolUse[0].matcher==\".*\"" "$X"'
t "status --json valid"          '"$CLI" status --json | jq -e ".claude_installed and .codex_installed"'
t "installed CLI works"          '"$HOME/.local/bin/nightguard" test'
conf "$DAY_S" "$DAY_E"
"$CLI" uninstall >/dev/null 2>&1
t "claude: only our hooks removed" '! grep -q night-guard "$S" && jq -e ".hooks.PreToolUse[0].matcher==\"Bash\"" "$S"'
t "codex: empty hooks.json removed" '[ ! -e "$X" ]'
t "backup created"               '[ -f "$S.night-guard.bak" ]'

echo "night lock"
"$CLI" install >/dev/null 2>&1
conf "$NIGHT_S" "$NIGHT_E"
t "schedule refused at night"    '! "$CLI" schedule 01:00 02:00'
t "off refused at night"         '! "$CLI" off'
t "uninstall needs phrase at night" '! "$CLI" uninstall </dev/null'
t "pause: wrong phrase refused"  '! NG_PHRASE=nope "$CLI" pause 5'
t "pause: over max refused"      '! NG_PHRASE="я осознанно работаю ночью" "$CLI" pause 99'
t "pause: works with phrase"     'NG_PHRASE="я осознанно работаю ночью" "$CLI" pause 5'
t "pause: hook allows"           '[ -z "$(hook "{\"hook_event_name\":\"PreToolUse\"}")" ]'
t "pause: only once per night"   'rm "$HOME/.night-guard/pause_until"; ! NG_PHRASE="я осознанно работаю ночью" "$CLI" pause 5'
echo $(( $(date +%s) + 99999 )) > "$HOME/.night-guard/pause_until"
t "tampered pause file ignored"  'hook "{\"hook_event_name\":\"PreToolUse\"}" | grep -q deny'
conf "$DAY_S" "$DAY_E"
t "day: schedule allowed"        '"$CLI" schedule 23:30 06:45 && grep -q "NIGHT_START=23:30" "$HOME/.night-guard/config"'
t "schedule rejects bad time"    '! "$CLI" schedule 25:00 07:00'

echo; echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
