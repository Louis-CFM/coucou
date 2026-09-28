"""
Coucou Codex bridge — JSON-lines stdio sidecar using the official openai-codex SDK.

Never logs tokens, cookies, or sensitive auth URL query parameters.
Credentials stay inside the official Codex runtime / app-server.
"""

from __future__ import annotations

import json
import sys
import threading
import traceback
from typing import Any

# Pending interactive logins keyed by login_id
_pending: dict[str, Any] = {}
_pending_lock = threading.Lock()
_codex = None
_codex_lock = threading.Lock()


def log(msg: str) -> None:
    """Dev diagnostics to stderr only — never secrets."""
    sys.stderr.write(f"[Codex] {msg}\n")
    sys.stderr.flush()


def reply(req_id: str | None, **payload: Any) -> None:
    out = {"id": req_id, **payload}
    sys.stdout.write(json.dumps(out, default=str) + "\n")
    sys.stdout.flush()


def ensure_codex():
    global _codex
    with _codex_lock:
        if _codex is None:
            from openai_codex import Codex

            log("Runtime initialized")
            _codex = Codex()
            # Enter context so app-server starts
            _codex.__enter__()
        return _codex


def safe_account_label(account_resp: Any) -> str | None:
    """Extract a non-sensitive display label if the SDK exposes one."""
    try:
        acc = getattr(account_resp, "account", None) or account_resp
        if acc is None:
            return None
        for key in ("email", "email_address", "name", "plan_type", "account_id"):
            val = getattr(acc, key, None)
            if isinstance(val, str) and val and "sk-" not in val and len(val) < 200:
                if key == "account_id":
                    return f"account:{val[:8]}…"
                return val
        # dict-like
        if isinstance(acc, dict):
            for key in ("email", "email_address", "name", "planType"):
                val = acc.get(key)
                if isinstance(val, str) and val:
                    return val
    except Exception:
        return None
    return None


def handle_status(req_id: str | None) -> None:
    try:
        codex = ensure_codex()
        info = codex.account(refresh_token=False)
        label = safe_account_label(info)
        requires = getattr(info, "requires_openai_auth", None)
        authenticated = info.account is not None
        if authenticated:
            log("Existing session detected")
        else:
            log("No ChatGPT session (requires_openai_auth=%s)" % requires)
        reply(
            req_id,
            ok=True,
            authenticated=authenticated,
            accountLabel=label,
            provider="openai-codex",
            error=None,
        )
    except Exception as e:
        log(f"Status check failed: {type(e).__name__}")
        reply(
            req_id,
            ok=False,
            authenticated=False,
            accountLabel=None,
            provider="openai-codex",
            error="Codex runtime unavailable",
            detail=str(e)[:200],
        )


def handle_login_chatgpt(req_id: str | None) -> None:
    try:
        codex = ensure_codex()
        log("Starting ChatGPT authentication")
        login = codex.login_chatgpt()
        login_id = getattr(login, "login_id", None) or getattr(login, "loginId", None)
        auth_url = getattr(login, "auth_url", None) or getattr(login, "authUrl", None)
        if not auth_url:
            reply(req_id, ok=False, error="Could not obtain authentication URL")
            return
        with _pending_lock:
            _pending[str(login_id)] = login
        # Do not log full auth URL (may contain sensitive params)
        log("Authentication URL ready (browser)")
        reply(
            req_id,
            ok=True,
            mode="browser",
            loginId=str(login_id),
            authUrl=auth_url,
        )
    except Exception as e:
        log(f"login_chatgpt failed: {type(e).__name__}: {str(e)[:120]}")
        reply(req_id, ok=False, error="Codex runtime unavailable", detail=str(e)[:200])


def handle_login_device(req_id: str | None) -> None:
    try:
        codex = ensure_codex()
        log("Starting ChatGPT device-code authentication")
        login = codex.login_chatgpt_device_code()
        login_id = getattr(login, "login_id", None) or getattr(login, "loginId", None)
        verification_url = getattr(login, "verification_url", None) or getattr(
            login, "verificationUrl", None
        )
        user_code = getattr(login, "user_code", None) or getattr(login, "userCode", None)
        with _pending_lock:
            _pending[str(login_id)] = login
        log("Device code ready")
        reply(
            req_id,
            ok=True,
            mode="device_code",
            loginId=str(login_id),
            verificationUrl=verification_url,
            userCode=user_code,
        )
    except Exception as e:
        log(f"device-code failed: {type(e).__name__}")
        reply(req_id, ok=False, error="Device-code login unavailable", detail=str(e)[:200])


def handle_login_wait(req_id: str | None, login_id: str) -> None:
    with _pending_lock:
        login = _pending.get(login_id)
    if login is None:
        reply(req_id, ok=False, error="Unknown or expired login attempt")
        return

    def worker() -> None:
        try:
            result = login.wait()
            success = bool(getattr(result, "success", True))
            with _pending_lock:
                _pending.pop(login_id, None)
            if success:
                log("Authentication successful")
                try:
                    info = ensure_codex().account(refresh_token=False)
                    label = safe_account_label(info)
                except Exception:
                    label = None
                reply(
                    req_id,
                    ok=True,
                    authenticated=True,
                    accountLabel=label,
                    provider="openai-codex",
                )
            else:
                log("Authentication failed or cancelled")
                reply(req_id, ok=False, authenticated=False, error="Authentication cancelled")
        except Exception as e:
            with _pending_lock:
                _pending.pop(login_id, None)
            msg = str(e).lower()
            if "cancel" in msg:
                err = "Authentication cancelled"
            elif "timeout" in msg or "timed out" in msg:
                err = "Authentication timed out"
            else:
                err = "Authentication failed"
            log(f"login wait error: {type(e).__name__}")
            reply(req_id, ok=False, authenticated=False, error=err, detail=str(e)[:200])

    threading.Thread(target=worker, daemon=True).start()


def handle_login_cancel(req_id: str | None, login_id: str) -> None:
    with _pending_lock:
        login = _pending.pop(login_id, None)
    if login is None:
        reply(req_id, ok=True, cancelled=False)
        return
    try:
        login.cancel()
        log("Authentication cancelled by user")
        reply(req_id, ok=True, cancelled=True)
    except Exception as e:
        reply(req_id, ok=False, error=str(e)[:200])


def handle_logout(req_id: str | None) -> None:
    try:
        codex = ensure_codex()
        codex.logout()
        log("Logged out")
        reply(req_id, ok=True, authenticated=False)
    except Exception as e:
        reply(req_id, ok=False, error=str(e)[:200])


def handle_thread_run(req_id: str | None, prompt: str, cwd: str | None) -> None:
    """Run a single turn and stream normalized states via progress events."""
    try:
        from openai_codex import Sandbox

        codex = ensure_codex()
        kwargs = {}
        if cwd:
            kwargs["cwd"] = cwd
        thread = codex.thread_start(sandbox=Sandbox.workspace_write, **kwargs)
        reply(req_id, ok=True, phase="started", threadId=getattr(thread, "id", None), agentState="thinking")
        # Use turn handle for streaming when available
        try:
            turn = thread.turn(prompt)
            for notification in turn.stream():
                state = map_notification_to_state(notification)
                if state:
                    reply(None, event="agent_state", agentState=state, threadId=getattr(thread, "id", None))
            result = turn.run() if hasattr(turn, "run") else None
            if result is None:
                result = thread.run(prompt)
        except Exception:
            result = thread.run(prompt)

        final = getattr(result, "final_response", None) or ""
        status = str(getattr(result, "status", "completed"))
        agent_state = "success" if "fail" not in status.lower() and "error" not in status.lower() else "error"
        reply(
            req_id,
            ok=True,
            phase="completed",
            threadId=getattr(thread, "id", None),
            finalResponse=final[:8000] if isinstance(final, str) else None,
            agentState=agent_state,
        )
    except Exception as e:
        log(f"thread run failed: {type(e).__name__}")
        reply(req_id, ok=False, error=str(e)[:300], agentState="error")


def map_notification_to_state(notification: Any) -> str | None:
    """Map Codex notifications → companion agent states (no secrets)."""
    method = getattr(notification, "method", None) or ""
    payload = getattr(notification, "payload", None)
    text = f"{method} {payload}".lower()

    if "reasoning" in text or "thinking" in text:
        return "thinking"
    if "web_search" in text or "websearch" in text or "search" in text:
        return "searching"
    if "command" in text or "shell" in text or "terminal" in text:
        return "running_command"
    if "file_change" in text or "patch" in text or "write" in text or "edit" in text:
        return "editing"
    if "read" in text:
        return "reading"
    if "approval" in text or "waiting" in text or "user" in text:
        return "waiting_for_user"
    if "error" in text or "failed" in text:
        return "error"
    if "completed" in text or "success" in text:
        return "success"
    return "thinking"


def handle_shutdown(req_id: str | None) -> None:
    global _codex
    with _pending_lock:
        for lid, login in list(_pending.items()):
            try:
                login.cancel()
            except Exception:
                pass
        _pending.clear()
    with _codex_lock:
        if _codex is not None:
            try:
                _codex.__exit__(None, None, None)
            except Exception:
                pass
            _codex = None
    reply(req_id, ok=True)
    raise SystemExit(0)


def dispatch(msg: dict[str, Any]) -> None:
    req_id = msg.get("id")
    cmd = msg.get("cmd")
    if cmd == "status":
        handle_status(req_id)
    elif cmd == "login_chatgpt":
        handle_login_chatgpt(req_id)
    elif cmd == "login_device_code":
        handle_login_device(req_id)
    elif cmd == "login_wait":
        handle_login_wait(req_id, str(msg.get("loginId") or ""))
    elif cmd == "login_cancel":
        handle_login_cancel(req_id, str(msg.get("loginId") or ""))
    elif cmd == "logout":
        handle_logout(req_id)
    elif cmd == "thread_run":
        prompt = str(msg.get("prompt") or "")
        cwd = msg.get("cwd")
        threading.Thread(
            target=handle_thread_run,
            args=(req_id, prompt, cwd if isinstance(cwd, str) else None),
            daemon=True,
        ).start()
    elif cmd == "shutdown":
        handle_shutdown(req_id)
    elif cmd == "ping":
        reply(req_id, ok=True, pong=True)
    else:
        reply(req_id, ok=False, error=f"unknown cmd: {cmd}")


def main() -> None:
    log("Bridge starting")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            reply(None, ok=False, error="invalid JSON")
            continue
        try:
            dispatch(msg)
        except SystemExit:
            raise
        except Exception:
            log("Unhandled error")
            traceback.print_exc(file=sys.stderr)
            reply(msg.get("id"), ok=False, error="internal error")


if __name__ == "__main__":
    main()
