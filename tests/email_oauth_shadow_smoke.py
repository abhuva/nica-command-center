#!/usr/bin/env python3
"""Exercise bounded Email OAuth management without live credentials."""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import closing
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
EMAIL_ROOT = REPO_ROOT / "Email"
SERVER = EMAIL_ROOT / "email_tool.py"
START_SCRIPT = REPO_ROOT / "scripts" / "start-email-oauth-shadow.ps1"
CLASSIFICATION_SCRIPT = REPO_ROOT / "scripts" / "start-email-classification-shadow.ps1"
STOP_SCRIPT = REPO_ROOT / "scripts" / "stop-email-read.ps1"

sys.path.insert(0, str(EMAIL_ROOT))
sys.path.insert(0, str(REPO_ROOT / "tests"))

import email_tool  # noqa: E402
from email_classification_shadow_smoke import run_powershell  # noqa: E402
from email_fetch_shadow_smoke import free_port, request_json, wait_for_ping  # noqa: E402


OAUTH_CAPABILITIES = {
    "unrestricted": False,
    "mailCount": True,
    "mailFetch": True,
    "classificationLabel": True,
    "classificationRun": True,
    "messageTag": True,
    "oauthManage": True,
    "rulesApply": True,
    "rulesManage": True,
    "vaultExport": False,
}


def oauth_account() -> dict[str, Any]:
    """Return a disabled synthetic Microsoft OAuth account."""
    return {
        "id": "fixture-oauth",
        "email": "fixture@example.test",
        "username": "fixture@example.test",
        "server": "imap.example.test",
        "enabled": False,
        "auth": {"method": "oauth", "provider": "microsoft"},
        "oauthTokenPath": "oauth/fixture.json",
    }


def tool_config(runtime_root: Path, vault: Path) -> dict[str, Any]:
    """Return isolated synthetic Email configuration."""
    return {
        "runtimeRoot": str(runtime_root),
        "database": "email.db",
        "vaultRoot": str(vault),
        "emailVaultDir": "8. Emails",
        "oauthCallbackPort": free_port(),
        "accounts": [oauth_account()],
    }


def token_payload(access_token: str = "synthetic-old-access") -> dict[str, Any]:
    """Return non-sensitive synthetic token state."""
    return {
        "access_token": access_token,
        "refresh_token": "synthetic-old-refresh",
        "expires_at": "2099-01-01T00:00:00+00:00",
        "expires_in": 3600,
    }


def atomic_token_smoke() -> None:
    """Verify token exchange validates refresh state and publishes atomically."""
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        vault = root / "vault"
        runtime = root / "state" / "email"
        vault.mkdir()
        tool = email_tool.EmailTool(tool_config(runtime, vault))
        token_path = runtime / "oauth" / "fixture.json"
        email_tool.write_json_atomic(token_path, token_payload())
        tool.oauth_flows["fixture-oauth"] = {
            "account_id": "fixture-oauth",
            "provider": "microsoft",
            "token_url": "https://example.test/token",
            "client_id": "synthetic-client",
            "redirect_uri": "http://localhost/callback",
            "state": "synthetic-state",
            "created_at": time.time(),
            "expires_in": 900,
            "pending": False,
            "code": "synthetic-code",
        }
        original_exchange = email_tool.exchange_oauth_code
        email_tool.exchange_oauth_code = lambda _flow: {
            "access_token": "synthetic-new-access",
            "expires_in": 3600,
        }
        try:
            result = tool.poll_oauth_login({"accountId": "fixture-oauth"})
        finally:
            email_tool.exchange_oauth_code = original_exchange
        assert result == {"ok": True, "pending": False, "accountId": "fixture-oauth"}
        written = json.loads(token_path.read_text(encoding="utf-8"))
        assert written["access_token"] == "synthetic-new-access"
        assert written["refresh_token"] == "synthetic-old-refresh"
        assert not list(token_path.parent.glob(".fixture.json.stage-*"))

        token_path.write_text("{invalid-old-token-json", encoding="utf-8")
        tool.oauth_flows["fixture-oauth"] = {
            "account_id": "fixture-oauth",
            "provider": "microsoft",
            "token_url": "https://example.test/token",
            "client_id": "synthetic-client",
            "redirect_uri": "http://localhost/callback",
            "state": "synthetic-state-complete-response",
            "created_at": time.time(),
            "expires_in": 900,
            "pending": False,
            "code": "synthetic-code-complete-response",
        }
        email_tool.exchange_oauth_code = lambda _flow: {
            "access_token": "synthetic-complete-access",
            "refresh_token": "synthetic-complete-refresh",
            "expires_in": 3600,
        }
        try:
            result = tool.poll_oauth_login({"accountId": "fixture-oauth"})
        finally:
            email_tool.exchange_oauth_code = original_exchange
        assert result["ok"] is True
        written = json.loads(token_path.read_text(encoding="utf-8"))
        assert written["access_token"] == "synthetic-complete-access"
        assert written["refresh_token"] == "synthetic-complete-refresh"

        email_tool.write_json_atomic(token_path, token_payload())
        tool.oauth_flows["fixture-oauth"] = {
            "account_id": "fixture-oauth",
            "provider": "microsoft",
            "token_url": "https://example.test/token",
            "client_id": "synthetic-client",
            "redirect_uri": "http://localhost/callback",
            "state": "synthetic-state-concurrent-refresh",
            "created_at": time.time(),
            "expires_in": 900,
            "pending": False,
            "code": "synthetic-code-concurrent-refresh",
        }
        exchange_started = threading.Event()
        poll_result: dict[str, Any] = {}
        poll_errors: list[Exception] = []

        def exchange_without_refresh(_flow: dict[str, Any]) -> dict[str, Any]:
            exchange_started.set()
            return {"access_token": "synthetic-reauthorized-access", "expires_in": 3600}

        def poll_in_thread() -> None:
            try:
                poll_result.update(tool.poll_oauth_login({"accountId": "fixture-oauth"}))
            except Exception as error:  # pragma: no cover - asserted below
                poll_errors.append(error)

        email_tool.exchange_oauth_code = exchange_without_refresh
        poll_thread = threading.Thread(target=poll_in_thread)
        try:
            with tool._lock:
                poll_thread.start()
                assert exchange_started.wait(timeout=1)
                poll_thread.join(timeout=0.2)
                assert poll_thread.is_alive(), "OAuth publication did not wait for the fetch lock"
                email_tool.write_json_atomic(token_path, {
                    "access_token": "synthetic-fetch-access",
                    "refresh_token": "synthetic-fetch-refresh",
                    "expires_at": "2099-01-01T00:00:00+00:00",
                })
            poll_thread.join(timeout=2)
        finally:
            email_tool.exchange_oauth_code = original_exchange
        assert not poll_thread.is_alive()
        assert not poll_errors
        assert poll_result["ok"] is True
        written = json.loads(token_path.read_text(encoding="utf-8"))
        assert written["access_token"] == "synthetic-reauthorized-access"
        assert written["refresh_token"] == "synthetic-fetch-refresh"

        email_tool.write_json_atomic(token_path, {"access_token": "synthetic-unchanged"})
        original_bytes = token_path.read_bytes()
        tool.oauth_flows["fixture-oauth"] = {
            "account_id": "fixture-oauth",
            "provider": "microsoft",
            "token_url": "https://example.test/token",
            "client_id": "synthetic-client",
            "redirect_uri": "http://localhost/callback",
            "state": "synthetic-state-without-refresh",
            "created_at": time.time(),
            "expires_in": 900,
            "pending": False,
            "code": "synthetic-code-without-refresh",
        }
        email_tool.exchange_oauth_code = lambda _flow: {
            "access_token": "synthetic-rejected-access",
            "expires_in": 3600,
        }
        try:
            try:
                tool.poll_oauth_login({"accountId": "fixture-oauth"})
                raise AssertionError("OAuth login without any refresh token was accepted")
            except ValueError as error:
                assert "refresh token" in str(error)
        finally:
            email_tool.exchange_oauth_code = original_exchange
        assert token_path.read_bytes() == original_bytes
        assert not list(token_path.parent.glob(".fixture.json.stage-*"))


def callback_and_capability_smoke() -> None:
    """Verify OAuth routing, callback state checks, and query-free logging."""
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        vault = root / "vault"
        state = root / "state"
        component = state / "email"
        vault.mkdir()
        component.mkdir(parents=True)
        (component / "config.local.json").write_text(
            json.dumps({"accounts": [oauth_account()]}),
            encoding="utf-8",
        )
        (component / ".env").write_text("MS_CLIENT_ID=synthetic-client\n", encoding="utf-8")
        token_path = component / "oauth" / "fixture.json"
        email_tool.write_json_atomic(token_path, token_payload())
        port = free_port()
        callback_port = free_port()
        env = os.environ.copy()
        env.update({
            "NICA_VAULT_ROOT": str(vault),
            "NICA_STATE_ROOT": str(state),
            "NICA_WRITE_ENABLED": "false",
            "NICA_EMAIL_CAPABILITIES": "mail.count,mail.fetch,classification.label,classification.run,message.tag,oauth.manage,rules.apply,rules.manage",
            "EMAIL_HOST": "127.0.0.1",
            "EMAIL_PORT": str(port),
            "EMAIL_OAUTH_CALLBACK_PORT": str(callback_port),
        })
        process = subprocess.Popen(
            [sys.executable, str(SERVER), "serve"],
            cwd=EMAIL_ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        stderr = ""
        try:
            base_url = f"http://127.0.0.1:{port}"
            health = wait_for_ping(f"{base_url}/api/ping")
            assert health["writeCapabilities"] == OAUTH_CAPABILITIES
            assert health["oauthCallback"] == {"host": "127.0.0.1", "port": callback_port}

            status, started = request_json(
                f"{base_url}/api/oauth/start",
                "POST",
                {"accountId": "fixture-oauth"},
            )
            assert status == 200 and started.get("ok") is True
            authorization_url = urllib.parse.urlparse(str(started["authorizationUrl"]))
            query = urllib.parse.parse_qs(authorization_url.query)
            callback_state = query["state"][0]
            assert query["redirect_uri"] == [f"http://localhost:{callback_port}/callback"]

            status, pending = request_json(
                f"{base_url}/api/oauth/poll",
                "POST",
                {"accountId": "fixture-oauth"},
            )
            assert status == 200 and pending.get("pending") is True

            mismatch_url = f"http://127.0.0.1:{callback_port}/callback?state=wrong&code=do-not-log"
            try:
                urllib.request.urlopen(mismatch_url, timeout=2)
                raise AssertionError("OAuth callback accepted a mismatched state")
            except urllib.error.HTTPError as error:
                assert error.code == 400

            callback_url = (
                f"http://127.0.0.1:{callback_port}/callback?"
                + urllib.parse.urlencode({"state": callback_state, "code": "synthetic-secret-code"})
            )
            with urllib.request.urlopen(callback_url, timeout=2) as response:
                assert response.status == 200

            status, denied = request_json(f"{base_url}/api/export", "POST", {})
            assert status == 403 and denied.get("capability") == "vault.export"
            assert json.loads(token_path.read_text(encoding="utf-8"))["access_token"] == "synthetic-old-access"
        finally:
            process.terminate()
            try:
                _stdout, stderr = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                _stdout, stderr = process.communicate(timeout=5)
        assert "synthetic-secret-code" not in stderr
        assert callback_state not in stderr
        assert "do-not-log" not in stderr


def launcher_and_rollback_smoke() -> None:
    """Exercise OAuth plan/apply, immutable token backup, and classification rollback."""
    powershell = shutil.which("powershell.exe") or shutil.which("powershell")
    if not powershell:
        print("Email OAuth launcher smoke skipped: Windows PowerShell unavailable")
        return

    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        vault = root / "vault"
        legacy_email = vault / "Tools" / "Email"
        state = root / "state"
        candidate = state / "email"
        legacy_email.mkdir(parents=True)
        candidate.mkdir(parents=True)
        source_tool = email_tool.EmailTool(tool_config(legacy_email, vault))
        candidate_tool = email_tool.EmailTool(tool_config(candidate, vault))
        del source_tool, candidate_tool
        config = {"accounts": [oauth_account()]}
        (legacy_email / "config.local.json").write_text(json.dumps(config), encoding="utf-8")
        (candidate / "config.local.json").write_text(json.dumps(config), encoding="utf-8")
        (candidate / ".env").write_text("MS_CLIENT_ID=synthetic-client\n", encoding="utf-8")
        token_path = candidate / "oauth" / "fixture.json"
        email_tool.write_json_atomic(token_path, token_payload())
        port = free_port()
        callback_port = free_port()
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
            "-OAuthCallbackPort",
            str(callback_port),
        ]
        plan = run_powershell(common, timeout=20)
        assert plan.returncode == 0, plan.stderr
        planned = json.loads(plan.stdout.split("Plan only.", 1)[0])
        assert planned["component"] == "email-oauth-shadow"
        assert planned["oauthSetupEnabled"] is True
        assert planned["oauthTokenBackupAction"] == "create-missing"
        backup_path = candidate / "backups" / "oauth-before-management" / "oauth" / "fixture.json"
        assert not backup_path.exists()

        applied = run_powershell(common + ["-Apply"], capture=False)
        assert applied.returncode == 0, applied.stderr + applied.stdout
        stop_arguments = [
            powershell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(STOP_SCRIPT),
            "-StateRoot",
            str(state),
        ]
        try:
            health = wait_for_ping(f"http://127.0.0.1:{port}/api/ping")
            assert health["writeCapabilities"] == OAUTH_CAPABILITIES
            assert backup_path.read_text(encoding="utf-8") == token_path.read_text(encoding="utf-8")
        finally:
            stopped = run_powershell(stop_arguments, timeout=20, capture=False)
        assert stopped.returncode == 0, stopped.stderr

        email_tool.write_json_atomic(token_path, token_payload("synthetic-newer-access"))
        restarted = run_powershell(common + ["-Apply"], capture=False)
        assert restarted.returncode == 0, restarted.stderr + restarted.stdout
        try:
            wait_for_ping(f"http://127.0.0.1:{port}/api/ping")
        finally:
            restopped = run_powershell(stop_arguments, timeout=20, capture=False)
        assert restopped.returncode == 0, restopped.stderr
        assert json.loads(backup_path.read_text(encoding="utf-8"))["access_token"] == "synthetic-old-access"

        rollback = run_powershell([
            powershell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(CLASSIFICATION_SCRIPT),
            "-VaultRoot",
            str(vault),
            "-StateRoot",
            str(state),
            "-Port",
            str(port),
            "-Apply",
        ], capture=False)
        assert rollback.returncode == 0, rollback.stderr + rollback.stdout
        try:
            rollback_health = wait_for_ping(f"http://127.0.0.1:{port}/api/ping")
            assert rollback_health["writeCapabilities"]["oauthManage"] is False
            assert rollback_health["writeCapabilities"]["rulesManage"] is True
        finally:
            final_stop = run_powershell(stop_arguments, timeout=20, capture=False)
        assert final_stop.returncode == 0, final_stop.stderr

        first_time_account = oauth_account()
        first_time_account.update({
            "id": "fixture-first-time",
            "email": "first-time@example.test",
            "username": "first-time@example.test",
            "oauthTokenPath": "oauth/first-time.json",
        })
        config["accounts"].append(first_time_account)
        (candidate / "config.local.json").write_text(json.dumps(config), encoding="utf-8")
        first_time_token = candidate / "oauth" / "first-time.json"
        first_time_backup = candidate / "backups" / "oauth-before-management" / "oauth" / "first-time.json"
        assert not first_time_token.exists()
        assert not first_time_backup.exists()

        first_time_start = run_powershell(common + ["-Apply"], capture=False)
        assert first_time_start.returncode == 0, first_time_start.stderr + first_time_start.stdout
        try:
            first_time_health = wait_for_ping(f"http://127.0.0.1:{port}/api/ping")
            assert first_time_health["writeCapabilities"] == OAUTH_CAPABILITIES
            assert not first_time_token.exists()
            assert not first_time_backup.exists()
        finally:
            first_time_stop = run_powershell(stop_arguments, timeout=20, capture=False)
        assert first_time_stop.returncode == 0, first_time_stop.stderr


def serve_ui_fixture(port: int, callback_port: int) -> None:
    """Serve a disposable OAuth UI fixture until interrupted."""
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        vault = root / "vault"
        state = root / "state"
        component = state / "email"
        vault.mkdir()
        component.mkdir(parents=True)
        (component / "config.local.json").write_text(
            json.dumps({"accounts": [oauth_account()]}),
            encoding="utf-8",
        )
        (component / ".env").write_text("MS_CLIENT_ID=synthetic-client\n", encoding="utf-8")
        email_tool.write_json_atomic(component / "oauth" / "fixture.json", token_payload())
        env = os.environ.copy()
        env.update({
            "NICA_VAULT_ROOT": str(vault),
            "NICA_STATE_ROOT": str(state),
            "NICA_WRITE_ENABLED": "false",
            "NICA_EMAIL_CAPABILITIES": "mail.count,mail.fetch,classification.label,classification.run,message.tag,oauth.manage,rules.apply,rules.manage",
            "EMAIL_HOST": "127.0.0.1",
            "EMAIL_PORT": str(port),
            "EMAIL_OAUTH_CALLBACK_PORT": str(callback_port),
        })
        process = subprocess.Popen(
            [sys.executable, str(SERVER), "serve"],
            cwd=EMAIL_ROOT,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            wait_for_ping(f"http://127.0.0.1:{port}/api/ping")
            print(f"OAuth UI fixture ready on http://127.0.0.1:{port}/email.html", flush=True)
            process.wait()
        except KeyboardInterrupt:
            pass
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def main() -> None:
    """Run bounded OAuth management verification."""
    atomic_token_smoke()
    callback_and_capability_smoke()
    launcher_and_rollback_smoke()
    print("Email bounded-OAuth capability smoke check passed")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--serve-ui":
        serve_ui_fixture(int(sys.argv[2]), int(sys.argv[3]))
    else:
        main()
