#!/usr/bin/env python3
"""Exercise Email capability gates without mail credentials or live data."""

from __future__ import annotations

import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
SERVER = REPO_ROOT / "Email" / "email_tool.py"
START_SCRIPT = REPO_ROOT / "scripts" / "start-email-fetch-shadow.ps1"
STOP_SCRIPT = REPO_ROOT / "scripts" / "stop-email-read.ps1"
START_STABLE_SCRIPT = REPO_ROOT / "scripts" / "start-email.ps1"
STOP_STABLE_SCRIPT = REPO_ROOT / "scripts" / "stop-email.ps1"


def free_port() -> int:
    """Reserve an available loopback port for the next test server."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def request_json(url: str, method: str = "GET", payload: dict[str, Any] | None = None) -> tuple[int, dict[str, Any]]:
    """Return an HTTP status and decoded JSON response."""
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, method=method)
    if body is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        content_type = error.headers.get_content_type()
        body_text = error.read().decode("utf-8")
        return error.code, json.loads(body_text) if content_type == "application/json" else {}


def wait_for_ping(url: str) -> dict[str, Any]:
    """Wait briefly for the synthetic server to become healthy."""
    for _attempt in range(40):
        try:
            status, payload = request_json(url)
            if status == 200 and payload.get("ok"):
                return payload
        except (OSError, ValueError):
            pass
        time.sleep(0.1)
    raise RuntimeError("Synthetic Email server did not become healthy")


def stop_process(process: subprocess.Popen[str]) -> None:
    """Stop a synthetic Email server and collect its pipes."""
    process.terminate()
    try:
        process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate(timeout=5)


def launcher_smoke() -> None:
    """Exercise plan/apply/stop with a fully synthetic legacy profile."""
    powershell = shutil.which("powershell.exe") or shutil.which("powershell")
    if not powershell:
        print("Email fetch launcher smoke skipped: Windows PowerShell unavailable")
        return

    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        vault = root / "vault"
        legacy_email = vault / "Tools" / "Email"
        state = root / "state"
        legacy_email.mkdir(parents=True)
        with sqlite3.connect(legacy_email / "email.db") as connection:
            connection.execute("CREATE TABLE synthetic_marker (value TEXT NOT NULL)")
            connection.execute("INSERT INTO synthetic_marker(value) VALUES ('fixture')")
        (legacy_email / "config.local.json").write_text(
            json.dumps({
                "database": "email.db",
                "accounts": [{
                    "id": "fixture",
                    "email": "fixture@example.test",
                    "server": "imap.example.test",
                    "passwordEnv": "SYNTHETIC_EMAIL_SECRET",
                    "enabled": False,
                }],
            }),
            encoding="utf-8",
        )
        (legacy_email / ".env").write_text("SYNTHETIC_EMAIL_SECRET=fixture-only\n", encoding="utf-8")
        port = free_port()
        common = [
            powershell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(START_SCRIPT),
            "-VaultRoot",
            str(vault),
            "-StateRoot",
            str(state),
            "-Port",
            str(port),
            "-RefreshSnapshot",
            "-PrepareFetchProfile",
        ]
        plan = subprocess.run(common, capture_output=True, text=True, timeout=20, check=False)
        assert plan.returncode == 0, plan.stderr
        assert '"mode":  "limited-write"' in plan.stdout or '"mode": "limited-write"' in plan.stdout
        assert not (state / "email").exists()

        applied = subprocess.run(
            common + ["-Apply"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )
        candidate = state / "email"
        synthetic_log = candidate / "email-fetch.err.log"
        diagnostic = synthetic_log.read_text(encoding="utf-8", errors="replace") if synthetic_log.exists() else ""
        assert applied.returncode == 0, diagnostic
        assert (candidate / "email.db").is_file()
        assert (candidate / "config.local.json").is_file()
        assert (candidate / ".env").is_file()
        health = wait_for_ping(f"http://127.0.0.1:{port}/api/ping")
        assert health["mode"] == "limited-write"
        assert health["writeCapabilities"]["mailFetch"] is True
        status, response = request_json(f"http://127.0.0.1:{port}/api/export", "POST", {})
        assert status == 403
        assert response.get("capability") == "vault.export"

        stopped = subprocess.run(
            [
                powershell,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(STOP_SCRIPT),
                "-StateRoot",
                str(state),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=20,
            check=False,
        )
        assert stopped.returncode == 0, stopped.stderr
        assert (candidate / "email.db").is_file()
        assert not (candidate / "email-read-process.json").exists()
        retained_plan = subprocess.run(
            common[:-2],
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
        assert retained_plan.returncode == 0, retained_plan.stderr
        assert (
            '"configuredAccountCount":  1' in retained_plan.stdout
            or '"configuredAccountCount": 1' in retained_plan.stdout
        )
        assert (
            '"credentialEnvironmentFileCount":  1' in retained_plan.stdout
            or '"credentialEnvironmentFileCount": 1' in retained_plan.stdout
        )


def fresh_database_launcher_smoke() -> None:
    """Start the stable runtime with an empty database and no legacy database."""
    powershell = shutil.which("powershell.exe") or shutil.which("powershell")
    if not powershell:
        print("Fresh Email launcher smoke skipped: Windows PowerShell unavailable")
        return

    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        vault = root / "vault"
        legacy_email = vault / "Tools" / "Email"
        state = root / "state"
        legacy_email.mkdir(parents=True)
        (legacy_email / "config.local.json").write_text(
            json.dumps({
                "database": "email.db",
                "accounts": [{
                    "id": "fixture",
                    "email": "fixture@example.test",
                    "server": "imap.example.test",
                    "passwordEnv": "SYNTHETIC_EMAIL_SECRET",
                    "enabled": False,
                }],
            }),
            encoding="utf-8",
        )
        (legacy_email / ".env").write_text("SYNTHETIC_EMAIL_SECRET=fixture-only\n", encoding="utf-8")
        port = free_port()
        oauth_port = free_port()
        common = [
            powershell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(START_STABLE_SCRIPT),
            "-VaultRoot",
            str(vault),
            "-StateRoot",
            str(state),
            "-Port",
            str(port),
            "-OAuthCallbackPort",
            str(oauth_port),
            "-PrepareProfileFromLegacy",
            "-InitializeFreshDatabase",
        ]
        plan = subprocess.run(common, capture_output=True, text=True, timeout=20, check=False)
        assert plan.returncode == 0, plan.stderr
        assert '"databaseAction":  "initialize-empty"' in plan.stdout or '"databaseAction": "initialize-empty"' in plan.stdout
        assert '"sourceDatabaseBytes":  null' in plan.stdout or '"sourceDatabaseBytes": null' in plan.stdout
        assert not state.exists()

        applied = subprocess.run(
            common + ["-Apply"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )
        candidate = state / "email"
        diagnostic_path = candidate / "email.err.log"
        diagnostic = diagnostic_path.read_text(encoding="utf-8", errors="replace") if diagnostic_path.exists() else ""
        assert applied.returncode == 0, diagnostic
        database = candidate / "email.db"
        assert database.is_file()
        with sqlite3.connect(database) as connection:
            assert connection.execute("SELECT COUNT(*) FROM messages").fetchone()[0] == 0
            assert connection.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 1
            marker = connection.execute(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='synthetic_marker'"
            ).fetchone()[0]
            assert marker == 0
        health = wait_for_ping(f"http://127.0.0.1:{port}/api/ping")
        assert health["mode"] == "limited-write"
        assert all(health["writeCapabilities"][name] is True for name in (
            "mailCount",
            "mailFetch",
            "messageTag",
            "oauthManage",
            "rulesApply",
            "rulesManage",
            "vaultExport",
        ))

        stopped = subprocess.run(
            [
                powershell,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(STOP_STABLE_SCRIPT),
                "-StateRoot",
                str(state),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=20,
            check=False,
        )
        assert stopped.returncode == 0, stopped.stderr
        original_bytes = database.read_bytes()

        refused = subprocess.run(common + ["-Apply"], capture_output=True, text=True, timeout=20, check=False)
        assert refused.returncode != 0
        assert "requires an empty database path" in refused.stderr
        assert database.read_bytes() == original_bytes

        restart = subprocess.run(
            [
                powershell,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(START_STABLE_SCRIPT),
                "-VaultRoot",
                str(vault),
                "-StateRoot",
                str(state),
                "-Port",
                str(port),
                "-OAuthCallbackPort",
                str(oauth_port),
                "-Apply",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )
        assert restart.returncode == 0
        assert wait_for_ping(f"http://127.0.0.1:{port}/api/ping")["ok"] is True
        subprocess.run(
            [
                powershell,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(STOP_STABLE_SCRIPT),
                "-StateRoot",
                str(state),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=20,
            check=True,
        )


def main() -> None:
    """Verify bounded fetch routing, health metadata, and fail-closed startup."""
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        vault = root / "vault"
        state = root / "state"
        vault.mkdir()
        port = free_port()
        env = os.environ.copy()
        env.update({
            "NICA_VAULT_ROOT": str(vault),
            "NICA_STATE_ROOT": str(state),
            "NICA_WRITE_ENABLED": "false",
            "NICA_EMAIL_CAPABILITIES": "mail.count,mail.fetch",
            "EMAIL_HOST": "127.0.0.1",
            "EMAIL_PORT": str(port),
        })
        process = subprocess.Popen(
            [sys.executable, str(SERVER), "serve"],
            cwd=SERVER.parent,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            base_url = f"http://127.0.0.1:{port}"
            health = wait_for_ping(f"{base_url}/api/ping")
            assert health["mode"] == "limited-write"
            assert health["writesEnabled"] is True
            assert health["writeCapabilities"] == {
                "unrestricted": False,
                "mailCount": True,
                "mailFetch": True,
                "messageTag": False,
                "oauthManage": False,
                "rulesApply": False,
                "rulesManage": False,
                "vaultExport": False,
            }

            for route in ("/api/count", "/api/count-all", "/api/fetch", "/api/fetch-new", "/api/fetch-new-all"):
                status, response = request_json(f"{base_url}{route}", "POST", {})
                assert status in {200, 400}, (route, status, response)
                assert response.get("code") != "NICA_CAPABILITY_DISABLED"

            denied_routes = {
                "/api/export": "vault.export",
                "/api/rules": "rules.manage",
                "/api/rules/delete": "rules.manage",
                "/api/rules/apply": "rules.apply",
                "/api/messages/tag": "message.tag",
                "/api/oauth/start": "oauth.manage",
                "/api/oauth/poll": "oauth.manage",
            }
            for route, capability in denied_routes.items():
                status, response = request_json(f"{base_url}{route}", "POST", {})
                assert status == 403, (route, status, response)
                assert response.get("code") == "NICA_CAPABILITY_DISABLED"
                assert response.get("capability") == capability

            status, _response = request_json(f"{base_url}/api/not-a-route", "POST", {})
            assert status == 404
        finally:
            stop_process(process)

        invalid_env = dict(env)
        invalid_env["NICA_STATE_ROOT"] = str(root / "invalid-state")
        invalid_env["NICA_EMAIL_CAPABILITIES"] = "mail.fetch,vault.destroy"
        invalid = subprocess.run(
            [sys.executable, str(SERVER), "serve"],
            cwd=SERVER.parent,
            env=invalid_env,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        assert invalid.returncode != 0
        assert "Unknown Email write capabilities" in invalid.stderr

    launcher_smoke()
    fresh_database_launcher_smoke()
    print("Email bounded-fetch capability smoke check passed")


if __name__ == "__main__":
    main()
