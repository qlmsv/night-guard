# 🌙 Night Guard

[![tests](https://github.com/qlmsv/night-guard/actions/workflows/tests.yml/badge.svg)](https://github.com/qlmsv/night-guard/actions/workflows/tests.yml)
**[Сайт](https://qlmsv.github.io/night-guard/) · [Презентация](https://qlmsv.github.io/night-guard/slides.html) · [English](#english)**

**Ночной ограничитель вайбкодинга для Claude Code и Codex.** С 23:00 до 07:00 (настраивается) агенты не принимают промпты и не выполняют действия — ни новые задачи, ни те, что уже бегут в фоне. macOS, Windows, Linux.

## Как это работает

Night Guard ставит официальный **хук** в оба агента:

| Событие | Что происходит ночью |
|---|---|
| `UserPromptSubmit` | промпт не отправляется, ты видишь «Иди спать — продолжим утром» |
| `PreToolUse` | действие агента запрещено — даже в задаче, запущенной вечером |

Хук — маленький скрипт без зависимостей: bash на macOS/Linux, PowerShell (5.1 и 7) на Windows. Конфиг читается как данные и никогда не исполняется. Если конфиг испорчен, включается расписание по умолчанию — защита не отключается молча.

## Установка

### macOS

```bash
git clone https://github.com/qlmsv/night-guard.git
cd night-guard && ./install.sh
```

Ставит хуки, команду `nightguard` (в `~/.local/bin`) и **Night Guard.app** — луну в строке меню. Приложение собирается из исходников, нужен `swiftc` (`xcode-select --install`); без него — `./install.sh --no-app`.

### Windows

```powershell
git clone https://github.com/qlmsv/night-guard.git
cd night-guard
powershell -ExecutionPolicy Bypass -File install.ps1
```

Без git: **Code → Download ZIP**, распакуйте и выполните последнюю команду в этой папке. Ставит хуки, команду `nightguard` (папка `%USERPROFILE%\.night-guard\bin` добавляется в PATH пользователя), **значок в трее** и ярлыки в «Автозагрузке» и меню «Пуск».

### Linux

```bash
git clone https://github.com/qlmsv/night-guard.git
cd night-guard && ./install.sh --no-app
```

Нужны `bash` и `jq`.

> **Codex** запускает пользовательские хуки только после одобрения. Один раз откройте Codex, выполните `/hooks` и доверьте хукам Night Guard. После обновления Night Guard может понадобиться одобрить снова.

Установщик меняет только свои записи в `~/.claude/settings.json` и `~/.codex/hooks.json`, остальное сохраняет и делает копию `*.night-guard.bak`. Повторная установка ничего не дублирует.

## Интерфейс

- **macOS** — луна в строке меню: статус, расписание, вкл/выкл, подключение Claude Code и Codex, экстренная пауза, журнал, автозапуск.
- **Windows** — значок в трее (клик — окно настроек, правый клик — меню) с теми же возможностями.
- **Терминал** — `nightguard` без аргументов открывает меню:

```
nightguard                     интерактивное меню
nightguard status [--json]     состояние   (Windows: -Json)
nightguard schedule 23:30 07:00
nightguard on | off
nightguard pause 15            экстренная пауза
nightguard log                 журнал блокировок
nightguard test                проверить, что хук блокирует
nightguard install | uninstall [all|claude|codex]
```

## Правила ночного режима

Это ограничитель для себя, поэтому ночью он упрямый:
- **нельзя** менять расписание и выключать Night Guard — в том числе во время паузы;
- отключить хуки можно только после ввода фразы «я осознанно работаю ночью»;
- **пауза** — один раз за ночь, максимум 30 минут, тоже с фразой; пауза лишь пускает агентов, но не открывает настройки. Потом блокировка возвращается сама.

Днём всё настраивается свободно. Это не замок от решительного человека (файлы можно поправить руками), а трение, которого хватает, чтобы закрыть ноутбук.

## Ограничения

- Работает для **локальных** Claude Code (терминал, приложение, IDE) и Codex (CLI, приложение). Облачные сессии и веб-чаты не затрагиваются.
- Codex: хостовые инструменты (например, встроенный веб-поиск) не проходят через `PreToolUse`, но новый промпт всё равно блокируется.
- Windows: если групповая политика запрещает скрипты PowerShell (ExecutionPolicy на уровне MachinePolicy/UserPolicy), хук не сможет запуститься — проверьте командой `nightguard test`. Каждый вызов инструмента днём добавляет ~0,3–0,5 с на старт PowerShell.
- Windows PowerShell 5.1 переформатирует `settings.json` при записи (содержимое сохраняется, есть резервная копия).
- Время — по часам компьютера.

## Удаление

```bash
nightguard uninstall      # убирает хуки, команду и автозапуск; конфиг и журнал остаются
```

Затем при желании удалите `~/.night-guard` (Windows: `%USERPROFILE%\.night-guard`) и `~/Applications/Night Guard.app`.

## Разработка

```bash
tests/run.sh                                       # macOS / Linux
powershell -ExecutionPolicy Bypass -File tests/run.ps1   # Windows (5.1 и 7)
app/build.sh                                       # собрать приложение для macOS
```

Тесты работают в изолированном временном профиле и не трогают реальные настройки. CI гоняет их на macOS, Linux и Windows (оба PowerShell), включая запуск хука через cmd, PowerShell и Git Bash — так, как его вызывают агенты.

---

## English

**Night Guard is a self-imposed night-time lock for AI coding agents.** From 11 pm to 7 am (configurable), Claude Code and OpenAI Codex refuse prompts (`UserPromptSubmit`) and every tool call (`PreToolUse`), including tasks already running. Works on macOS (menu bar app), Windows (tray app) and Linux (CLI).

**Install**: macOS/Linux: `./install.sh` (Linux: `--no-app`). Windows: `powershell -ExecutionPolicy Bypass -File install.ps1`. Then, in Codex, run `/hooks` once and trust the Night Guard hooks.

**Night rules**: at night you can't change the schedule or turn it off, even during a pause. Uninstalling requires typing a confirmation phrase. You get one emergency pause per night, up to 30 minutes. It's friction, not DRM.

See the [website](https://qlmsv.github.io/night-guard/?lang=en) and [slides](https://qlmsv.github.io/night-guard/slides.html?lang=en).

## License

MIT
