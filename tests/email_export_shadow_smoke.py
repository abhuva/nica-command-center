#!/usr/bin/env python3
"""Exercise bounded Email vault export without live society data."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
EMAIL_ROOT = REPO_ROOT / "Email"
SERVER = EMAIL_ROOT / "email_tool.py"
START_SCRIPT = REPO_ROOT / "scripts" / "start-email-export-shadow.ps1"
OAUTH_SCRIPT = REPO_ROOT / "scripts" / "start-email-oauth-shadow.ps1"
STOP_SCRIPT = REPO_ROOT / "scripts" / "stop-email-read.ps1"

sys.path.insert(0, str(EMAIL_ROOT))
sys.path.insert(0, str(REPO_ROOT / "tests"))

import email_tool  # noqa: E402
from email_classification_shadow_smoke import run_powershell  # noqa: E402
from email_fetch_shadow_smoke import free_port, request_json, wait_for_ping  # noqa: E402


EXPORT_CAPABILITIES = {
    "unrestricted": False,
    "mailCount": True,
    "mailFetch": True,
    "messageTag": True,
    "oauthManage": True,
    "rulesApply": True,
    "rulesManage": True,
    "vaultExport": True,
}


def fixture_config(runtime_root: Path, vault: Path) -> dict[str, Any]:
    """Return isolated synthetic Email configuration."""
    return {
        "runtimeRoot": str(runtime_root),
        "database": "email.db",
        "vaultRoot": str(vault),
        "emailVaultDir": "8. Emails",
        "oauthCallbackPort": free_port(),
        "accounts": [],
    }


def add_message(tool: email_tool.EmailTool, uid: str, subject: str) -> str:
    """Insert and include one synthetic message."""
    sample = {
        "account_id": "fixture",
        "mailbox": "INBOX",
        "uid": uid,
        "message_id": f"<export-{uid}@example.test>",
        "thread_key": f"<export-{uid}@example.test>",
        "subject": subject,
        "sender_name": "Fixture Sender",
        "sender_email": "fixture@example.test",
        "recipients": [{"name": "Fixture Recipient", "email": "recipient@example.test"}],
        "cc": [],
        "sent_at": f"2026-02-{int(uid):02d}T12:00:00+00:00",
        "headers": {},
        "body_text": f"Synthetic export body {uid}.",
        "body_markdown": f"Synthetic export body {uid}.",
        "body_hash": email_tool.sha256_text(f"Synthetic export body {uid}."),
        "attachment_count": 0,
        "size_bytes": 64,
    }
    assert tool.store_message(sample) == 1
    listed = tool.list_messages({"limit": ["100"]})["messages"]
    message_id = next(item["id"] for item in listed if item["uid"] == uid)
    tool.tag_message({"messageId": message_id, "state": "included"})
    return message_id


def target_for(tool: email_tool.EmailTool, message_id: str) -> Path:
    """Return the expected synthetic export target."""
    message = tool.get_message(message_id)
    assert message is not None
    return tool.email_vault_root / tool.export_path_for(message)


def assert_not_exported(tool: email_tool.EmailTool, message_ids: list[str]) -> None:
    """Assert export metadata remains absent for selected messages."""
    placeholders = ",".join("?" for _item in message_ids)
    with tool.connect() as conn:
        rows = conn.execute(
            f"SELECT id, exported_path, exported_at, export_hash FROM messages WHERE id IN ({placeholders})",
            message_ids,
        ).fetchall()
        assert len(rows) == len(message_ids)
        assert all(row["exported_path"] is None for row in rows)
        assert conn.execute("SELECT COUNT(*) AS count FROM exports").fetchone()["count"] == 0


def plan_apply_smoke() -> None:
    """Verify preview, one-use apply, unchanged adoption, and conflict refusal."""
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        vault = root / "vault"
        runtime = root / "state" / "email"
        vault.mkdir()
        tool = email_tool.EmailTool(fixture_config(runtime, vault))
        message_id = add_message(tool, "1", "Synthetic bounded export")
        target = target_for(tool, message_id)

        plan = tool.plan_export({"state": "included", "accountId": "fixture"})
        assert plan["total"] == 1
        assert plan["create"] == 1
        assert plan["unchanged"] == 0
        assert plan["conflicts"] == 0
        assert plan["canApply"] is True
        assert plan["planToken"]
        assert not tool.email_vault_root.exists()
        assert_not_exported(tool, [message_id])

        try:
            tool.apply_export({})
            raise AssertionError("Export apply accepted a missing plan token")
        except ValueError as error:
            assert "token" in str(error)

        applied = tool.apply_export({"planToken": plan["planToken"]})
        assert applied == {
            "ok": True,
            "exported": 1,
            "created": 1,
            "unchanged": 0,
            "destination": "8. Emails",
        }
        original_bytes = target.read_bytes()
        original_mtime = target.stat().st_mtime_ns
        assert not list(target.parent.glob(f".{target.name}.stage-*"))
        with tool.connect() as conn:
            row = conn.execute(
                "SELECT exported_path, export_hash FROM messages WHERE id=?",
                (message_id,),
            ).fetchone()
            export_row = conn.execute(
                "SELECT status, content_hash FROM exports WHERE message_id=? AND profile='included'",
                (message_id,),
            ).fetchone()
        assert row["exported_path"].startswith("8. Emails/")
        assert row["export_hash"] == email_tool.sha256_file(target)
        assert export_row["status"] == "create"
        assert export_row["content_hash"] == row["export_hash"]

        try:
            tool.apply_export({"planToken": plan["planToken"]})
            raise AssertionError("Export plan token was reusable")
        except ValueError as error:
            assert "missing or expired" in str(error)

        unchanged_plan = tool.plan_export({"state": "included", "accountId": "fixture"})
        assert unchanged_plan["create"] == 0
        assert unchanged_plan["unchanged"] == 1
        unchanged = tool.apply_export({"planToken": unchanged_plan["planToken"]})
        assert unchanged["created"] == 0 and unchanged["unchanged"] == 1
        assert target.read_bytes() == original_bytes
        assert target.stat().st_mtime_ns == original_mtime

        changed_target_plan = tool.plan_export({"state": "included", "accountId": "fixture"})
        target.write_text("Human-edited synthetic file.\n", encoding="utf-8")
        try:
            tool.apply_export({"planToken": changed_target_plan["planToken"]})
            raise AssertionError("Export applied after its target changed")
        except ValueError as error:
            assert "stale" in str(error)
        assert target.read_text(encoding="utf-8") == "Human-edited synthetic file.\n"

        conflict = tool.plan_export({"state": "included", "accountId": "fixture"})
        assert conflict["conflicts"] == 1
        assert conflict["canApply"] is False
        assert conflict["planToken"] == ""
        assert target.read_text(encoding="utf-8") == "Human-edited synthetic file.\n"


def stale_and_rollback_smoke() -> None:
    """Reject stale plans and roll back a partially published batch."""
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        vault = root / "vault"
        runtime = root / "state" / "email"
        vault.mkdir()
        tool = email_tool.EmailTool(fixture_config(runtime, vault))
        first_id = add_message(tool, "2", "First rollback message")
        second_id = add_message(tool, "3", "Second rollback message")
        targets = [target_for(tool, first_id), target_for(tool, second_id)]

        stale_plan = tool.plan_export({"state": "included"})
        with tool.connect() as conn:
            conn.execute(
                "UPDATE messages SET body_markdown='Changed after preview' WHERE id=?",
                (first_id,),
            )
        try:
            tool.apply_export({"planToken": stale_plan["planToken"]})
            raise AssertionError("Export applied a stale database plan")
        except ValueError as error:
            assert "stale" in str(error)
        assert all(not target.exists() for target in targets)
        assert_not_exported(tool, [first_id, second_id])

        rollback_plan = tool.plan_export({"state": "included"})
        original_link = email_tool.os.link
        link_calls = 0

        def fail_second_link(source: Path, destination: Path) -> None:
            nonlocal link_calls
            link_calls += 1
            if link_calls == 2:
                raise OSError("synthetic publication failure")
            original_link(source, destination)

        email_tool.os.link = fail_second_link
        try:
            try:
                tool.apply_export({"planToken": rollback_plan["planToken"]})
                raise AssertionError("Synthetic publication failure was ignored")
            except OSError as error:
                assert "synthetic publication failure" in str(error)
        finally:
            email_tool.os.link = original_link
        assert all(not target.exists() for target in targets)
        assert not list(vault.rglob("*.stage-*"))
        assert not tool.email_vault_root.exists()
        assert_not_exported(tool, [first_id, second_id])


def launcher_and_rollback_smoke() -> None:
    """Exercise export plan/apply through the launcher and rollback to OAuth."""
    powershell = shutil.which("powershell.exe") or shutil.which("powershell")
    if not powershell:
        print("Email export launcher smoke skipped: Windows PowerShell unavailable")
        return

    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        vault = root / "vault"
        legacy_email = vault / "Tools" / "Email"
        state = root / "state"
        candidate = state / "email"
        legacy_email.mkdir(parents=True)
        candidate.mkdir(parents=True)
        source_tool = email_tool.EmailTool(fixture_config(legacy_email, vault))
        candidate_tool = email_tool.EmailTool(fixture_config(candidate, vault))
        message_id = add_message(candidate_tool, "4", "Launcher export message")
        target = target_for(candidate_tool, message_id)
        del source_tool, candidate_tool
        config = {"accounts": []}
        (legacy_email / "config.local.json").write_text(json.dumps(config), encoding="utf-8")
        (candidate / "config.local.json").write_text(json.dumps(config), encoding="utf-8")
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
        assert planned["component"] == "email-export-shadow"
        assert planned["vaultExportEnabled"] is True
        assert not target.exists()

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
            base_url = f"http://127.0.0.1:{port}"
            health = wait_for_ping(f"{base_url}/api/ping")
            assert health["writeCapabilities"] == EXPORT_CAPABILITIES
            status, direct = request_json(f"{base_url}/api/export", "POST", {})
            assert status == 409 and direct.get("code") == "NICA_EXPORT_PLAN_REQUIRED"
            status, preview = request_json(
                f"{base_url}/api/export/plan",
                "POST",
                {"state": "included", "accountId": "fixture"},
            )
            assert status == 200 and preview["canApply"] is True
            assert not target.exists()
            status, exported = request_json(
                f"{base_url}/api/export/apply",
                "POST",
                {"planToken": preview["planToken"]},
            )
            assert status == 200 and exported["created"] == 1
            assert target.is_file()
        finally:
            stopped = run_powershell(stop_arguments, timeout=20, capture=False)
        assert stopped.returncode == 0, stopped.stderr

        rollback = run_powershell([
            powershell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(OAUTH_SCRIPT),
            "-VaultRoot",
            str(vault),
            "-StateRoot",
            str(state),
            "-Port",
            str(port),
            "-OAuthCallbackPort",
            str(callback_port),
            "-Apply",
        ], capture=False)
        assert rollback.returncode == 0, rollback.stderr + rollback.stdout
        try:
            rollback_health = wait_for_ping(f"http://127.0.0.1:{port}/api/ping")
            assert rollback_health["writeCapabilities"]["oauthManage"] is True
            assert rollback_health["writeCapabilities"]["vaultExport"] is False
        finally:
            final_stop = run_powershell(stop_arguments, timeout=20, capture=False)
        assert final_stop.returncode == 0, final_stop.stderr


def serve_ui_fixture(port: int, callback_port: int) -> None:
    """Serve a disposable export UI fixture until interrupted."""
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        vault = root / "vault"
        state = root / "state"
        component = state / "email"
        vault.mkdir()
        component.mkdir(parents=True)
        (component / "config.local.json").write_text(json.dumps({"accounts": []}), encoding="utf-8")
        tool = email_tool.EmailTool(fixture_config(component, vault))
        add_message(tool, "5", "Browser export message")
        port_env = os.environ.copy()
        port_env.update({
            "NICA_VAULT_ROOT": str(vault),
            "NICA_STATE_ROOT": str(state),
            "NICA_WRITE_ENABLED": "false",
            "NICA_EMAIL_CAPABILITIES": "mail.count,mail.fetch,message.tag,oauth.manage,rules.apply,rules.manage,vault.export",
            "EMAIL_HOST": "127.0.0.1",
            "EMAIL_PORT": str(port),
            "EMAIL_OAUTH_CALLBACK_PORT": str(callback_port),
        })
        process = subprocess.Popen(
            [sys.executable, str(SERVER), "serve"],
            cwd=EMAIL_ROOT,
            env=port_env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            wait_for_ping(f"http://127.0.0.1:{port}/api/ping")
            print(f"Export UI fixture ready on http://127.0.0.1:{port}/email.html", flush=True)
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
    """Run bounded Email export verification."""
    plan_apply_smoke()
    stale_and_rollback_smoke()
    launcher_and_rollback_smoke()
    print("Email bounded-export capability smoke check passed")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--serve-ui":
        serve_ui_fixture(int(sys.argv[2]), int(sys.argv[3]))
    else:
        main()
