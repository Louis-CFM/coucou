# Coucou for agents on a remote machine (SSH)

Claude Code and Codex sessions that run on a server (VS Code Remote - SSH, an SSH
environment in the Claude app's Code tab, Codex on a dev box) can show up in Coucou on
your Mac like local ones, approvals and questions included, on the iPhone too. Their
hooks talk to a socket on the server, and an SSH tunnel opened by the Mac forwards that
socket to Coucou:

```
agent on the server → nb-hook → socket on the server ──ssh -R──▶ nb.sock on the Mac → Coucou
```

The server needs `python3` and an SSH server. Nothing listens on a network port, and the
server never has to reach the Mac: the Mac opens the connection.

## 1. The relay on the server

Copy the relay from the Mac. The GitHub build keeps it in
`~/Library/Application Support/NotchBuddy/`, the App Store build in `~/.claude/coucou/`:

```sh
ssh myserver 'mkdir -p ~/.coucou && chmod 700 ~/.coucou'
scp ~/Library/Application\ Support/NotchBuddy/nb-hook ~/Library/Application\ Support/NotchBuddy/nb-hook.py myserver:.coucou/
```

Copy both files again after updating Coucou: the relay changes with the app.

Off the Mac, `nb-hook` runs the `python3` in `PATH`. The relay looks for the socket where
Coucou keeps it on a Mac (`~/Library/Application Support/NotchBuddy/nb.sock` for the
GitHub relay, the container path for the App Store one), so the tunnel below forwards to
that path. To use another path, set `COUCOU_SOCKET`; Claude Code runs hook commands in a
shell, so it can go in the command: `COUCOU_SOCKET=/run/user/1000/coucou-mac.sock "$HOME/.coucou/nb-hook"`.

## 2. The hooks on the server

**Claude Code** — the server's `~/.claude/settings.json` gets the hooks Coucou adds on the
Mac, with the server's path. The simplest is to copy the entries whose command contains
`NotchBuddy` from the Mac's `~/.claude/settings.json` and change the path. Every event runs
`"$HOME/.coucou/nb-hook"` with a 10 s timeout (`SessionStart`, `SessionEnd`,
`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`,
`Stop`, `StopFailure`, `SubagentStart`, `SubagentStop`), `PermissionRequest` waits up to
120 s, and questions have their own `PreToolUse` entry:

```json
{
  "hooks": {
    "PermissionRequest": [
      { "hooks": [{ "type": "command", "command": "\"$HOME/.coucou/nb-hook\"", "timeout": 120 }] }
    ],
    "PreToolUse": [
      { "hooks": [{ "type": "command", "command": "\"$HOME/.coucou/nb-hook\"", "timeout": 10 }] },
      { "matcher": "AskUserQuestion",
        "hooks": [{ "type": "command", "command": "\"$HOME/.coucou/nb-hook\" --ask", "timeout": 130 }] }
    ]
  }
}
```

**Codex** — the server's `~/.codex/hooks.json` gets the entries Coucou adds on the Mac
(Settings → Codex → Install hooks), with `"$HOME/.coucou/nb-hook" --agent codex`. Codex
approvals in the notch need the GitHub build. Recent Codex versions only run hooks they
trust (`hooks.state` in `~/.codex/config.toml`): trust the new ones in Codex, and start a
new chat, since a running one keeps the hooks it started with.

## 3. The tunnel on the Mac

```sh
SERVER=myserver
LOCAL="$HOME/Library/Application Support/NotchBuddy/nb.sock"
# Creates the folder on the server, removes a socket left by an earlier connection, prints the path.
REMOTE=$(ssh "$SERVER" 'd="$HOME/Library/Application Support/NotchBuddy"; mkdir -p "$d" && chmod 700 "$d" && rm -f "$d/nb.sock" && printf %s "$d/nb.sock"')
ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -R "$REMOTE:$LOCAL" "$SERVER"
```

- **Remove the old socket first.** When a connection drops, sshd leaves the socket file
  behind, and the next `ssh -R` fails with `remote port forwarding failed for listen
  path` — unless the server's `sshd_config` says `StreamLocalBindUnlink yes`. The leftover
  file does no harm meanwhile: connecting to it fails at once, and the agent carries on.
- Use the absolute path on the server; its folder must exist (the first command does both).
- App Store build: `LOCAL` is `~/Library/Containers/fr.louisraille.Coucou/Data/nb.sock`.
- sshd creates the socket with mode `0600` (`StreamLocalBindMask`), so only your user on
  the server, and root, can reach it. Whoever can act as your user there can put cards in
  your notch and read your answers: keep that in mind on a shared machine.

To keep the tunnel up, put the two commands in a script, add `-o BatchMode=yes` (launchd
cannot type a password: the SSH key must work without a prompt), and let launchd restart
it, in `~/Library/LaunchAgents/local.coucou-tunnel.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.coucou-tunnel</string>
    <key>ProgramArguments</key>
    <array><string>/bin/sh</string><string>/Users/you/.coucou-tunnel.sh</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>20</integer>
</dict>
</plist>
```

```sh
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/local.coucou-tunnel.plist
```

Check it from the Mac: the Claude Desktop pill should appear, say "hello", finish and go.

```sh
ssh myserver 'for e in UserPromptSubmit Stop; do
    printf "{\"hook_event_name\":\"%s\",\"session_id\":\"t1\",\"prompt\":\"hello\"}" "$e" |
        CLAUDE_CODE_ENTRYPOINT=claude-desktop ~/.coucou/nb-hook; sleep 2; done'
```

## 4. When the Mac sleeps

A sleeping Mac does not close the connection, and sshd may keep it for a long time: the
socket still accepts connections, and a permission request waits its full two minutes
before the agent asks in its own window. Two ways around it:

- **On the server, in `sshd_config`** (if you may edit it): `ClientAliveInterval 15` and
  `ClientAliveCountMax 3`. sshd drops a silent connection after about 45 s; from then on
  the hooks fail at once and the agent asks itself.
- **A heartbeat**, when sshd is not yours. The tunnel's session sends a line every 10 s,
  the server touches a file, and a wrapper (next section) skips Coucou once the file is
  older than 30 s. On the Mac, instead of `ssh -N`:

```sh
while :; do echo; sleep 10; done | ssh -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 -R "$REMOTE:$LOCAL" "$SERVER" \
    'while read -r _; do touch ~/.coucou/alive; done; rm -f ~/.coucou/alive'
```

## 5. Which sessions show up

Claude Code says where a session runs in `CLAUDE_CODE_ENTRYPOINT`, and the relay uses it:

| `CLAUDE_CODE_ENTRYPOINT` | Session | In Coucou |
|---|---|---|
| `claude-desktop` | Code tab of the Claude app | Claude Desktop pill; approvals and questions stay in the app |
| `claude-vscode` | VS Code's Claude Code extension | VS Code pill, with approvals and questions in the notch and on the iPhone |
| `cli` | `claude` in a terminal over SSH | usually ignored: `TERM_PROGRAM` does not travel over SSH |
| `sdk-ts`, `sdk-py`, … | scripts and tools that run Claude Code | ignored |

Ignored sessions still open a connection for each event. To keep them, and anything else
that runs as your user on the server, off the tunnel, and to use the heartbeat above, call
a wrapper instead of `nb-hook` in the hook commands, `~/.coucou/hook`:

```sh
#!/bin/sh
# nb-hook for the sessions you want, and only while the Mac answers.
skip() { cat >/dev/null; exit 0; }
alive="$HOME/.coucou/alive"
[ $(( $(date +%s) - $(stat -c %Y "$alive" 2>/dev/null || echo 0) )) -le 30 ] || skip
case " $* " in
    *" --agent "*) ;;   # Codex and other agents
    *) case "$CLAUDE_CODE_ENTRYPOINT" in
           claude-desktop|claude-vscode) ;;
           *) skip ;;
       esac ;;
esac
exec "$HOME/.coucou/nb-hook" "$@"
```

(Drop the `alive` line if you use `ClientAliveInterval` instead of the heartbeat. Copilot
CLI expects an answer from its hook, so keep it out of this wrapper.)

## What stays on the Mac

The buttons that open a session's app, folder or terminal act on the Mac: they cannot
reach a session on the server.
