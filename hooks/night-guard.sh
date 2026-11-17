#!/bin/bash
# Night Guard — hook for Claude Code and Codex.
# Blocks prompts (UserPromptSubmit) and tool calls (PreToolUse) during the night window.
#
# No dependencies beyond macOS /bin/bash 3.2 and coreutils.
# Sourced with NG_LIB_ONLY=1 it only defines functions (used by the `nightguard` CLI).

NG_HOME="${NIGHT_GUARD_HOME:-$HOME/.night-guard}"
NG_CONF="$NG_HOME/config"
NG_LOG="$NG_HOME/blocked.log"
NG_PAUSE="$NG_HOME/pause_until"
NG_LOG_MAX=2000

ng_defaults() {
  NG_START="23:00"; NG_END="07:00"; NG_ENABLED=1; NG_PAUSE_MAX=30
}

# "7", "07", "7:30", "07:30" -> minutes since midnight. Returns 1 if invalid.
ng_to_min() {
  local v="$1" h m
  case "$v" in
    [0-9]|[0-9][0-9]) h=$v; m=0 ;;
    [0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9]) h=${v%%:*}; m=${v#*:} ;;
    *) return 1 ;;
  esac
  h=$((10#$h)); m=$((10#$m))
  [ "$h" -le 23 ] && [ "$m" -le 59 ] || return 1
  echo $((h * 60 + m))
}

ng_fmt() { # minutes -> HH:MM
  printf '%02d:%02d' $(($1 / 60)) $(($1 % 60))
}

# Parse config as data (never executed). Invalid values keep safe defaults.
ng_load() {
  ng_defaults
  [ -f "$NG_CONF" ] || return 0
  local key val
  while IFS='=' read -r key val || [ -n "$key" ]; do
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    val=${val%%#*}
    val=$(printf '%s' "$val" | tr -d "[:space:]\"'")
    case "$key" in
      NIGHT_START) ng_to_min "$val" >/dev/null && NG_START=$(ng_fmt "$(ng_to_min "$val")") ;;
      NIGHT_END)   ng_to_min "$val" >/dev/null && NG_END=$(ng_fmt "$(ng_to_min "$val")") ;;
      ENABLED)     case "$val" in 0|1) NG_ENABLED=$val ;; esac ;;
      PAUSE_MAX_MINUTES) case "$val" in [0-9]|[0-9][0-9]) NG_PAUSE_MAX=$((10#$val)) ;; esac ;;
    esac
  done < "$NG_CONF"
}

ng_now_min() {
  # shellcheck disable=SC2046
  set -- $(date '+%H %M')
  echo $((10#$1 * 60 + 10#$2))
}

# Is minute-of-day $1 (default: now) inside the night window?
ng_in_window() {
  local n="${1:-$(ng_now_min)}" s e
  s=$(ng_to_min "$NG_START"); e=$(ng_to_min "$NG_END")
  [ "$s" = "$e" ] && return 1
  if [ "$s" -lt "$e" ]; then
    [ "$n" -ge "$s" ] && [ "$n" -lt "$e" ]
  else
    [ "$n" -ge "$s" ] || [ "$n" -lt "$e" ]
  fi
}

# Seconds left in an active pause (0 if none). Ignores tampered/oversized values.
ng_pause_left() {
  local until now left
  [ -f "$NG_PAUSE" ] || { echo 0; return; }
  until=$(tr -cd '0-9' < "$NG_PAUSE")
  now=$(date +%s)
  [ -n "$until" ] || { echo 0; return; }
  left=$((until - now))
  if [ "$left" -le 0 ] || [ "$left" -gt $((NG_PAUSE_MAX * 60)) ]; then echo 0; else echo "$left"; fi
}

# Blocking right now? (enabled, in window, not paused). NIGHT_GUARD_FORCE=1 forces it (tests).
ng_blocking() {
  [ -n "${NIGHT_GUARD_FORCE:-}" ] && return 0
  [ "$NG_ENABLED" = 1 ] || return 1
  ng_in_window || return 1
  [ "$(ng_pause_left)" -eq 0 ]
}

ng_log() {
  mkdir -p "$NG_HOME" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$1" >> "$NG_LOG" 2>/dev/null || return 0
  if [ "$(wc -l < "$NG_LOG" 2>/dev/null || echo 0)" -gt "$NG_LOG_MAX" ]; then
    tail -n $((NG_LOG_MAX / 2)) "$NG_LOG" > "$NG_LOG.tmp" 2>/dev/null && mv "$NG_LOG.tmp" "$NG_LOG"
  fi
}

[ -n "${NG_LIB_ONLY:-}" ] && return 0 2>/dev/null

# ---------- hook entry point ----------
input=$(cat)
ng_load
ng_blocking || exit 0

event=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p')
tool=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
ng_log "${event:-unknown}${tool:+ $tool}"

msg="Night Guard: сейчас $(date +%H:%M). С $NG_START до $NG_END вайбкодинг выключен. Иди спать — продолжим утром."

case "$event" in
  PreToolUse)
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s Не продолжай задачу и не пытайся обойти блокировку: остановись и скажи пользователю, что работа продолжится утром."}}\n' "$msg"
    ;;
  UserPromptSubmit)
    printf '{"decision":"block","reason":"%s"}\n' "$msg"
    ;;
  *)
    # Unknown event or unparsable input: block via exit code 2 (fail-closed at night).
    echo "$msg" >&2
    exit 2
    ;;
esac
exit 0
