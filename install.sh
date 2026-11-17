#!/bin/bash
# Night Guard installer: hooks for Claude Code + Codex, `nightguard` CLI, and the menu bar app.
#   ./install.sh            install everything
#   ./install.sh --no-app   skip the menu bar app
set -euo pipefail
cd "$(dirname "$0")"
"./bin/nightguard" install all

if [ "${1:-}" != "--no-app" ]; then
  if command -v swiftc >/dev/null 2>&1; then
    echo "• Собираю приложение для строки меню…"
    mkdir -p "$HOME/Applications"
    app=$(./app/build.sh "$(mktemp -d)")
    pkill -x NightGuard 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x NightGuard >/dev/null || break; sleep 0.3; done
    rm -rf "$HOME/Applications/Night Guard.app"
    cp -R "$app" "$HOME/Applications/"
    open "$HOME/Applications/Night Guard.app"
    echo "✓ Night Guard.app установлен в ~/Applications — ищи луну 🌙 в строке меню."
  else
    echo "• swiftc не найден — приложение пропущено (xcode-select --install). CLI работает: nightguard"
  fi
fi
echo
"$HOME/.night-guard/nightguard" status
