#!/usr/bin/env python3
"""Exercise bounded Email classification without live mail or vault writes."""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from contextlib import closing
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
EMAIL_ROOT = REPO_ROOT / "Email"
SERVER = EMAIL_ROOT / "email_tool.py"
START_SCRIPT = REPO_ROOT / "scripts" / "start-email-classification-shadow.ps1"
FETCH_SCRIPT = REPO_ROOT / "scripts" / "start-email-fetch-shadow.ps1"
STOP_SCRIPT = REPO_ROOT / "scripts" / "stop-email-read.ps1"

sys.path.insert(0, str(EMAIL_ROOT))
sys.path.insert(0, str(REPO_ROOT / "tests"))

from email_fetch_shadow_smoke import (  # noqa: E402
    free_port,
    request_json,
    stop_process,
    wait_for_ping,
)
from email_tool import EmailTool, sha256_text  # noqa: E402


CLASSIFICATION_CAPABILITIES = {
    "unrestricted": False,
    "mailCount": True,
    "mailFetch": True,
    "messageTag": True,
    "oauthManage": False,
    "rulesApply": True,
    "rulesManage": True,
    "vaultExport": False,
}


def fixture_config(runtime_root: Path, vault: Path) -> dict[str, Any]:
    """Return a synthetic runtime configuration."""
    return {
        "runtimeRoot": str(runtime_root),
        "database": "email.db",
        "vaultRoot": str(vault),
        "emailVaultDir": "8. Emails",
        "accounts": [],
    }


def add_fixture_message(tool: EmailTool, uid: str = "1") -> str:
    """Insert one non-sensitive synthetic message and return its stable id."""
    sample = {
        "account_id": "fixture",
        "mailbox": "INBOX",
        "uid": uid,
        "message_id": f"<fixture-{uid}@example.test>",
        "thread_key": f"<fixture-{uid}@example.test>",
        "subject": "Synthetic classification message",
        "sender_name": "Fixture Sender",
        "sender_email": "fixture@example.test",
        "recipients": [{"name": "Fixture User", "email": "user@example.test"}],
        "cc": [],
        "sent_at": "2026-10-07T08:00:00+00:00",
        "headers": {},
        "body_text": "Synthetic classification body.",
        "body_markdown": "Synthetic classification body.",
        "body_hash": sha256_text("Synthetic classification body."),
        "attachment_count": 0,
        "size_bytes": 32,
    }
    assert tool.store_message(sample) == 1
    listed = tool.list_messages({"limit": ["10"]})
    assert listed["total"] == 1
    return str(listed["messages"][0]["id"])


def database_has_table(database: Path, table: str) -> bool:
    """Return whether a synthetic marker table exists."""
    with closing(sqlite3.connect(database)) as connection:
        row = connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            (table,),
        ).fetchone()
    return row is not None


def exercise_classification_api(base_url: str, database: Path, message_id: str) -> None:
    """Verify local classification mutations and denied external boundaries."""
    status, tagged = request_json(
        f"{base_url}/api/messages/tag",
        "POST",
        {"messageId": message_id, "tag": "synthetic-manual", "state": "included"},
    )
    assert status == 200 and tagged.get("ok") is True

    status, saved = request_json(
        f"{base_url}/api/rules",
        "POST",
        {
            "name": "Synthetic sender rule",
            "scope": "global",
            "field": "sender_domain",
            "operator": "equals",
            "pattern": "example.test",
            "action": "exclude",
            "tag": "synthetic-rule",
        },
    )
    assert status == 200 and saved.get("ok") is True
    rule_id = str(saved["id"])

    status, applied = request_json(f"{base_url}/api/rules/apply", "POST", {})
    assert status == 200 and applied.get("matches") == 1
    assert applied.get("changed") == 1

    with closing(sqlite3.connect(database)) as connection:
        state = connection.execute(
            "SELECT include_state, include_reason FROM messages WHERE id=?",
            (message_id,),
        ).fetchone()
        tags = {
            row[0]
            for row in connection.execute(
                "SELECT tag FROM message_tags WHERE message_id=?",
                (message_id,),
            )
        }
    assert state == ("excluded", f"rule:{rule_id}")
    assert tags == {"synthetic-manual", "synthetic-rule"}

    status, deleted = request_json(
        f"{base_url}/api/rules/delete",
        "POST",
        {"id": rule_id},
    )
    assert status == 200 and deleted.get("ok") is True

    denied_routes = {
        "/api/export": "vault.export",
        "/api/oauth/start": "oauth.manage",
        "/api/oauth/poll": "oauth.manage",
    }
    for route, capability in denied_routes.items():
        status, response = request_json(f"{base_url}{route}", "POST", {})
        assert status == 403, (route, status, response)
        assert response.get("capability") == capability


def direct_server_smoke() -> None:
    """Exercise the operation-specific capability boundary directly."""
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        vault = root / "vault"
        state = root / "state"
        component_state = state / "email"
        vault.mkdir()
        tool = EmailTool(fixture_config(component_state, vault))
        message_id = add_fixture_message(tool)
        port = free_port()
        env = os.environ.copy()
        env.update({
            "NICA_VAULT_ROOT": str(vault),
            "NICA_STATE_ROOT": str(state),
            "NICA_WRITE_ENABLED": "false",
            "NICA_EMAIL_CAPABILITIES": "mail.count,mail.fetch,message.tag,rules.apply,rules.manage",
            "EMAIL_HOST": "127.0.0.1",
            "EMAIL_PORT": str(port),
        })
        process = subprocess.Popen(
            [sys.executable, str(SERVER), "serve"],
            cwd=EMAIL_ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            base_url = f"http://127.0.0.1:{port}"
            health = wait_for_ping(f"{base_url}/api/ping")
            assert health["mode"] == "limited-write"
            assert health["writeCapabilities"] == CLASSIFICATION_CAPABILITIES
            exercise_classification_api(base_url, component_state / "email.db", message_id)
            assert not (vault / "8. Emails").exists()
        finally:
            stop_process(process)


def run_powershell(
    arguments: list[str],
    timeout: int = 30,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    """Run one launcher command without inheriting an interactive console."""
    if not capture:
        with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as stdout_file:
            with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as stderr_file:
                result = subprocess.run(
                    arguments,
                    stdin=subprocess.DEVNULL,
                    stdout=stdout_file,
                    stderr=stderr_file,
                    text=True,
                    timeout=timeout,
                    check=False,
                )
                stdout_file.seek(0)
                stderr_file.seek(0)
                result.stdout = stdout_file.read()
                result.stderr = stderr_file.read()
                return result
    return subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
        check=False,
    )


def launcher_and_rollback_smoke() -> None:
    """Exercise plan/apply/stop and rollback to the fetch-only profile."""
    powershell = shutil.which("powershell.exe") or shutil.which("powershell")
    if not powershell:
        print("Email classification launcher smoke skipped: Windows PowerShell unavailable")
        return

    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        vault = root / "vault"
        legacy_email = vault / "Tools" / "Email"
        state = root / "state"
        legacy_email.mkdir(parents=True)
        source_tool = EmailTool(fixture_config(legacy_email, vault))
        add_fixture_message(source_tool)
        source_config = legacy_email / "config.local.json"
        source_config.write_text(
            json.dumps({
                "database": "email.db",
                "accounts": [{
                    "id": "fixture",
                    "email": "fixture@example.test",
                    "server": "imap.example.test",
                    "enabled": False,
                }],
            }),
            encoding="utf-8",
        )
        candidate = state / "email"
        candidate.mkdir(parents=True)
        with closing(sqlite3.connect(legacy_email / "email.db")) as source_connection:
            with closing(sqlite3.connect(candidate / "email.db")) as candidate_connection:
                source_connection.backup(candidate_connection)
        shutil.copy2(source_config, candidate / "config.local.json")
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
            "-BackupCandidate",
        ]
        plan = run_powershell(common, timeout=20)
        assert plan.returncode == 0, plan.stderr
        assert '"component":  "email-classification-shadow"' in plan.stdout or '"component": "email-classification-shadow"' in plan.stdout
        assert '"rulesEnabled":  true' in plan.stdout or '"rulesEnabled": true' in plan.stdout
        rollback_database = candidate / "backups" / "email-before-classification.db"
        assert not rollback_database.exists()
        assert not (candidate / "email-read-process.json").exists()

        applied = run_powershell(common + ["-Apply"], capture=False)
        diagnostic_path = candidate / "email-classification.err.log"
        diagnostic = diagnostic_path.read_text(encoding="utf-8", errors="replace") if diagnostic_path.exists() else ""
        assert applied.returncode == 0, diagnostic
        assert rollback_database.is_file()
        with closing(sqlite3.connect(rollback_database)) as rollback_connection:
            assert rollback_connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
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
            assert health["writeCapabilities"] == CLASSIFICATION_CAPABILITIES
        finally:
            stopped = run_powershell(stop_arguments, timeout=20, capture=False)
        assert stopped.returncode == 0

        marker_table = "synthetic_post_classification_marker"
        with closing(sqlite3.connect(candidate / "email.db")) as candidate_connection:
            candidate_connection.execute(f"CREATE TABLE {marker_table} (value TEXT NOT NULL)")
            candidate_connection.execute(f"INSERT INTO {marker_table}(value) VALUES ('newer-state')")
        assert not database_has_table(rollback_database, marker_table)

        retain_plan = run_powershell(common, timeout=20)
        assert retain_plan.returncode == 0, retain_plan.stderr
        assert '"candidateBackupAction":  "retain-existing"' in retain_plan.stdout or '"candidateBackupAction": "retain-existing"' in retain_plan.stdout
        retained_restart = run_powershell(common + ["-Apply"], capture=False)
        assert retained_restart.returncode == 0, diagnostic
        try:
            retained_health = wait_for_ping(f"http://127.0.0.1:{port}/api/ping")
            assert retained_health["writeCapabilities"] == CLASSIFICATION_CAPABILITIES
        finally:
            retained_stop = run_powershell(stop_arguments, timeout=20, capture=False)
        assert retained_stop.returncode == 0
        assert not database_has_table(rollback_database, marker_table)

        original_rollback_database = candidate / "backups" / "email-before-classification.original.db"
        refresh_common = common[:-1] + ["-RefreshCandidateBackup"]
        refresh_plan = run_powershell(refresh_common, timeout=20)
        assert refresh_plan.returncode == 0, refresh_plan.stderr
        assert '"candidateBackupAction":  "preserve-original-and-refresh"' in refresh_plan.stdout or '"candidateBackupAction": "preserve-original-and-refresh"' in refresh_plan.stdout
        assert not original_rollback_database.exists()
        refreshed_restart = run_powershell(refresh_common + ["-Apply"], capture=False)
        assert refreshed_restart.returncode == 0, refreshed_restart.stderr + refreshed_restart.stdout + diagnostic
        try:
            refreshed_health = wait_for_ping(f"http://127.0.0.1:{port}/api/ping")
            assert refreshed_health["writeCapabilities"] == CLASSIFICATION_CAPABILITIES
        finally:
            refreshed_stop = run_powershell(stop_arguments, timeout=20, capture=False)
        assert refreshed_stop.returncode == 0
        assert original_rollback_database.is_file()
        assert not database_has_table(original_rollback_database, marker_table)
        assert database_has_table(rollback_database, marker_table)

        rollback = run_powershell([
            powershell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(FETCH_SCRIPT),
            "-VaultRoot",
            str(vault),
            "-StateRoot",
            str(state),
            "-Port",
            str(port),
            "-Apply",
        ], capture=False)
        fetch_diagnostic_path = candidate / "email-fetch.err.log"
        fetch_diagnostic = fetch_diagnostic_path.read_text(encoding="utf-8", errors="replace") if fetch_diagnostic_path.exists() else ""
        assert rollback.returncode == 0, fetch_diagnostic
        try:
            fetch_health = wait_for_ping(f"http://127.0.0.1:{port}/api/ping")
            assert fetch_health["writeCapabilities"]["mailFetch"] is True
            assert fetch_health["writeCapabilities"]["rulesManage"] is False
            assert fetch_health["writeCapabilities"]["messageTag"] is False
        finally:
            final_stop = run_powershell(stop_arguments, timeout=20, capture=False)
        assert final_stop.returncode == 0
        assert (candidate / "email.db").is_file()
        assert not (candidate / "email-read-process.json").exists()


def main() -> None:
    """Run bounded classification and rollback verification."""
    direct_server_smoke()
    launcher_and_rollback_smoke()
    print("Email bounded-classification capability smoke check passed")


if __name__ == "__main__":
    main()
