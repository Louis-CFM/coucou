#!/bin/sh
# Relays Claude Code hooks from WSL to Coucou for Windows.
#
# WSL interop runs coucou-hook.exe as a Windows process under your account, so it
# reaches Coucou's named pipe exactly as it would from a Windows terminal.
# Never blocking: if the relay is missing or fails, we exit 0 and say nothing.
#
# Coucou installs this for you: Settings… → WSL. To do it by hand, copy it to
# ~/.claude/hooks/, chmod +x, and point each hook command at
# `$HOME/.claude/hooks/coucou-hook-wsl.sh <EventName>` in ~/.claude/settings.json.
# EXE is the relay's WSL path; Coucou rewrites this line with the right one
# when it installs the script. By hand, put your own Windows user name in it.
EXE=/mnt/c/Users/YOUR_WINDOWS_USER/AppData/Local/Coucou/bin/coucou-hook.exe
[ -f "$EXE" ] || exit 0
# Coucou's own Claude Code runs (Mochi's chat) are not sessions to show.
[ -n "$COUCOU_INTERNAL" ] && exit 0
# Tells the relay which distro the session lives in.
WSLENV="${WSLENV:+$WSLENV:}WSL_DISTRO_NAME" "$EXE" "$@"
exit 0
