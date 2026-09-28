/// Embedded nb-hook Python script (installed to hook_script_path on startup).
pub const NB_HOOK_SCRIPT: &str = r#"#!/usr/bin/env python3
# nb-hook — Coucou hook relay for Claude Code (Linux)
import sys, json, os, socket

def main():
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return

    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    if not payload.get('term_program'):
        if any(k.startswith('CURSOR_') for k in env):
            payload['term_program'] = 'Cursor'
        else:
            argv0 = os.path.basename(sys.argv[0] or '')
            if 'cursor' in argv0.lower():
                payload['term_program'] = 'Cursor'
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()

    event = payload.get('hook_event_name', '')
    default_sock = os.path.expanduser('~/.local/share/coucou/nb.sock')
    socket_path = env.get('COUCOU_SOCK', default_sock)

    if event == 'PermissionRequest':
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response and 'permissionDecision' in response:
                sys.stdout.write(response + '\n')
                sys.stdout.flush()
                sys.exit(0)
        except Exception:
            pass
        sys.stdout.write('{"permissionDecision":"deny"}\n')
        sys.stdout.flush()
        sys.exit(0)

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\n').encode())
        s.close()
    except Exception:
        pass

main()
sys.exit(0)
"#;
