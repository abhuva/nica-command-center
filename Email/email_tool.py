#!/usr/bin/env python3
"""Database-first email bridge for the Obsidian Tools workspace."""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import email
import email.policy
import hashlib
import html
import imaplib
import json
import os
import re
import secrets
import sqlite3
import ssl
import sys
import threading
import time
import unicodedata
import urllib.parse
import urllib.request
import urllib.error
from dataclasses import dataclass
from email.header import decode_header
from email.utils import getaddresses, parsedate_to_datetime, parseaddr
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterable

from classification import MODEL_SPECS, available_models, classify_messages, message_text

ROOT = Path(__file__).resolve().parent
DEFAULT_CONFIG = {
    "host": "127.0.0.1",
    "port": 4176,
    "database": "email.db",
    "runtimeRoot": "",
    "vaultRoot": "",
    "emailVaultDir": "8. Emails",
    "oauthCallbackPort": 8080,
    "accounts": [],
}
MIME_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".ico": "image/x-icon",
}
EMAIL_WRITE_CAPABILITIES = frozenset({
    "mail.count",
    "mail.fetch",
    "classification.label",
    "classification.run",
    "message.tag",
    "oauth.manage",
    "rules.apply",
    "rules.manage",
    "vault.export",
})
EXPORT_PLAN_TTL_SECONDS = 300
LEGACY_EXPORT_NAME_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}-\d{6}) - .*\.md$", re.IGNORECASE)
POST_ROUTE_CAPABILITIES = {
    "/api/count": "mail.count",
    "/api/count-all": "mail.count",
    "/api/fetch": "mail.fetch",
    "/api/fetch-new": "mail.fetch",
    "/api/fetch-new-all": "mail.fetch",
    "/api/classification/run": "classification.run",
    "/api/classification/labels": "classification.label",
    "/api/classification/labels/import": "classification.label",
    "/api/export": "vault.export",
    "/api/export/plan": "vault.export",
    "/api/export/apply": "vault.export",
    "/api/rules": "rules.manage",
    "/api/rules/delete": "rules.manage",
    "/api/rules/apply": "rules.apply",
    "/api/messages/tag": "message.tag",
    "/api/oauth/start": "oauth.manage",
    "/api/oauth/poll": "oauth.manage",
}


class HtmlToText(HTMLParser):
    """Small HTML-to-text converter for email bodies."""

    BLOCK_TAGS = {"p", "div", "br", "li", "tr", "table", "section", "article", "header", "footer", "blockquote"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.skip_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        if tag in {"script", "style", "noscript"}:
            self.skip_depth += 1
            return
        if self.skip_depth:
            return
        if tag == "li":
            self.parts.append("\n- ")
        elif tag in self.BLOCK_TAGS:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag in {"script", "style", "noscript"} and self.skip_depth:
            self.skip_depth -= 1
            return
        if self.skip_depth:
            return
        if tag in self.BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if not self.skip_depth:
            self.parts.append(data)

    def text(self) -> str:
        raw = "".join(self.parts)
        raw = html.unescape(raw)
        raw = re.sub(r"[ \t]+", " ", raw)
        raw = re.sub(r"\n{3,}", "\n\n", raw)
        return raw.strip()


@dataclass
class EmailTool:
    """Main application service."""

    config: dict[str, Any]

    def __post_init__(self) -> None:
        self.root = Path(self.config.get("runtimeRoot") or ROOT).resolve()
        self.db_path = self.resolve_state_path(self.config.get("database", "email.db"))
        self.vault_root = Path(self.config.get("vaultRoot") or "").resolve()
        self.email_vault_dir = str(self.config.get("emailVaultDir", "8. Emails")).strip() or "8. Emails"
        self.email_vault_root = (self.vault_root / self.email_vault_dir).resolve()
        if self.email_vault_root != self.vault_root and self.vault_root not in self.email_vault_root.parents:
            raise ValueError("Email export path escaped the configured vault root")
        self.oauth_callback_port = int(self.config.get("oauthCallbackPort") or 8080)
        if self.oauth_callback_port < 1 or self.oauth_callback_port > 65535:
            raise ValueError("Email OAuth callback port must be between 1 and 65535")
        self._lock = threading.Lock()
        self._progress_lock = threading.Lock()
        self._export_lock = threading.Lock()
        self._classification_lock = threading.Lock()
        self.progress: dict[str, Any] = {"active": False, "phase": "idle", "message": "Idle", "updatedAt": iso_now()}
        self.oauth_flows: dict[str, dict[str, Any]] = {}
        self.export_plans: dict[str, dict[str, Any]] = {}
        self.oauth_callback_server: ThreadingHTTPServer | None = None
        self.init_db()

    def resolve_state_path(self, value: str | os.PathLike[str]) -> Path:
        """Resolve a local-state file and reject paths outside the runtime root."""
        path = Path(value)
        if not path.is_absolute():
            path = self.root / path
        resolved = path.resolve()
        if resolved != self.root and self.root not in resolved.parents:
            raise ValueError("Email local-state path escaped the runtime root")
        return resolved

    def connect(self) -> sqlite3.Connection:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        return conn

    def set_progress(self, **updates: Any) -> None:
        with self._progress_lock:
            self.progress.update(updates)
            self.progress["updatedAt"] = iso_now()

    def get_progress(self) -> dict[str, Any]:
        with self._progress_lock:
            return dict(self.progress)

    def init_db(self) -> None:
        with self.connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS accounts (
                  id TEXT PRIMARY KEY,
                  email TEXT NOT NULL,
                  provider TEXT DEFAULT '',
                  enabled INTEGER DEFAULT 1,
                  config_json TEXT NOT NULL,
                  last_sync_at TEXT,
                  last_error TEXT
                );
                CREATE TABLE IF NOT EXISTS messages (
                  id TEXT PRIMARY KEY,
                  account_id TEXT NOT NULL,
                  mailbox TEXT NOT NULL,
                  uid TEXT NOT NULL,
                  message_id TEXT,
                  thread_key TEXT,
                  subject TEXT,
                  sender_name TEXT,
                  sender_email TEXT,
                  recipients_json TEXT NOT NULL DEFAULT '[]',
                  cc_json TEXT NOT NULL DEFAULT '[]',
                  sent_at TEXT,
                  received_at TEXT,
                  raw_headers_json TEXT NOT NULL DEFAULT '{}',
                  body_text TEXT,
                  body_markdown TEXT,
                  body_hash TEXT,
                  attachment_count INTEGER DEFAULT 0,
                  size_bytes INTEGER DEFAULT 0,
                  fetched_at TEXT NOT NULL,
                  last_seen_at TEXT,
                  include_state TEXT NOT NULL DEFAULT 'candidate',
                  include_reason TEXT,
                  summary TEXT,
                  importance_score REAL,
                  spam_score REAL,
                  exported_path TEXT,
                  exported_at TEXT,
                  export_hash TEXT,
                  UNIQUE(account_id, mailbox, uid)
                );
                CREATE INDEX IF NOT EXISTS idx_messages_date ON messages(sent_at);
                CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_email);
                CREATE INDEX IF NOT EXISTS idx_messages_state ON messages(include_state);
                CREATE TABLE IF NOT EXISTS mailbox_sync (
                  account_id TEXT NOT NULL,
                  mailbox TEXT NOT NULL,
                  highest_uid INTEGER NOT NULL DEFAULT 0,
                  last_sync_at TEXT,
                  last_total INTEGER DEFAULT 0,
                  last_matched INTEGER DEFAULT 0,
                  last_error TEXT,
                  PRIMARY KEY(account_id, mailbox)
                );
                CREATE TABLE IF NOT EXISTS message_tags (
                  message_id TEXT NOT NULL,
                  tag TEXT NOT NULL,
                  source TEXT NOT NULL DEFAULT 'manual',
                  created_at TEXT NOT NULL,
                  PRIMARY KEY(message_id, tag, source),
                  FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS rules (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  enabled INTEGER NOT NULL DEFAULT 1,
                  scope TEXT NOT NULL DEFAULT 'global',
                  account_id TEXT,
                  field TEXT NOT NULL,
                  operator TEXT NOT NULL,
                  pattern TEXT NOT NULL,
                  action TEXT NOT NULL,
                  tag TEXT,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS rule_matches (
                  message_id TEXT NOT NULL,
                  rule_id TEXT NOT NULL,
                  matched_at TEXT NOT NULL,
                  result_json TEXT NOT NULL DEFAULT '{}',
                  PRIMARY KEY(message_id, rule_id),
                  FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE,
                  FOREIGN KEY(rule_id) REFERENCES rules(id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS exports (
                  message_id TEXT NOT NULL,
                  profile TEXT NOT NULL,
                  exported_path TEXT NOT NULL,
                  content_hash TEXT NOT NULL,
                  exported_at TEXT NOT NULL,
                  status TEXT NOT NULL DEFAULT 'written',
                  PRIMARY KEY(message_id, profile),
                  FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS classification_runs (
                  id TEXT PRIMARY KEY,
                  task TEXT NOT NULL,
                  model_id TEXT NOT NULL,
                  model_revision TEXT NOT NULL,
                  config_json TEXT NOT NULL DEFAULT '{}',
                  selection_json TEXT NOT NULL DEFAULT '{}',
                  status TEXT NOT NULL,
                  message_count INTEGER NOT NULL DEFAULT 0,
                  completed_count INTEGER NOT NULL DEFAULT 0,
                  error TEXT,
                  started_at TEXT NOT NULL,
                  completed_at TEXT
                );
                CREATE TABLE IF NOT EXISTS message_predictions (
                  run_id TEXT NOT NULL,
                  message_id TEXT NOT NULL,
                  task TEXT NOT NULL,
                  predicted_label TEXT NOT NULL,
                  score REAL,
                  scores_json TEXT NOT NULL DEFAULT '{}',
                  input_hash TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  PRIMARY KEY(run_id, message_id, task),
                  FOREIGN KEY(run_id) REFERENCES classification_runs(id) ON DELETE CASCADE,
                  FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_predictions_message ON message_predictions(message_id, task);
                CREATE TABLE IF NOT EXISTS message_labels (
                  message_id TEXT NOT NULL,
                  task TEXT NOT NULL,
                  label TEXT NOT NULL,
                  source TEXT NOT NULL,
                  review_mode TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  PRIMARY KEY(message_id, task),
                  FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_labels_task_label ON message_labels(task, label);
                CREATE TABLE IF NOT EXISTS label_events (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  message_id TEXT NOT NULL,
                  task TEXT NOT NULL,
                  label TEXT NOT NULL,
                  source TEXT NOT NULL,
                  review_mode TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
                );
                """
            )
            ensure_column(conn, "rules", "scope", "TEXT NOT NULL DEFAULT 'global'")
            ensure_column(conn, "rules", "account_id", "TEXT")
            conn.execute(
                """
                UPDATE classification_runs
                SET status='interrupted', error='Email service restarted before the run completed', completed_at=?
                WHERE status IN ('queued', 'running')
                """,
                (iso_now(),),
            )
            self.sync_accounts(conn)
            conn.execute(
                """
                INSERT OR IGNORE INTO mailbox_sync(account_id, mailbox, highest_uid, last_sync_at)
                SELECT account_id, mailbox, MAX(CAST(uid AS INTEGER)), ?
                FROM messages
                WHERE uid GLOB '[0-9]*'
                GROUP BY account_id, mailbox
                """,
                (iso_now(),),
            )

    def sync_accounts(self, conn: sqlite3.Connection) -> None:
        now = iso_now()
        for account in self.config.get("accounts", []):
            account_id = str(account.get("id", "")).strip()
            email_addr = str(account.get("email") or account.get("username") or "").strip()
            if not account_id or not email_addr:
                continue
            conn.execute(
                """
                INSERT INTO accounts(id, email, provider, enabled, config_json)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  email=excluded.email,
                  provider=excluded.provider,
                  enabled=excluded.enabled,
                  config_json=excluded.config_json
                """,
                (
                    account_id,
                    email_addr,
                    str(account.get("provider", "")),
                    1 if account.get("enabled", True) else 0,
                    json.dumps(account, ensure_ascii=False, sort_keys=True),
                ),
            )
        conn.execute("UPDATE accounts SET last_sync_at = COALESCE(last_sync_at, ?)", (now,))

    def accounts(self) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT a.id, a.email, a.provider, a.enabled, a.last_sync_at, a.last_error,
                       COUNT(m.id) AS message_count,
                       SUM(CASE WHEN m.include_state='candidate' THEN 1 ELSE 0 END) AS candidate_count,
                       SUM(CASE WHEN m.include_state='included' THEN 1 ELSE 0 END) AS included_count,
                       SUM(CASE WHEN m.include_state='excluded' THEN 1 ELSE 0 END) AS excluded_count,
                       SUM(CASE WHEN m.exported_path IS NOT NULL THEN 1 ELSE 0 END) AS exported_count
                FROM accounts a
                LEFT JOIN messages m ON m.account_id = a.id
                GROUP BY a.id
                ORDER BY a.id
                """
            ).fetchall()
            account_configs = {str(account.get("id") or ""): account for account in self.config.get("accounts", [])}
            sync_rows = conn.execute(
                """
                SELECT account_id,
                       SUM(last_total) AS server_total,
                       SUM(last_matched) AS server_matched,
                       MAX(last_sync_at) AS sync_last_at,
                       MAX(highest_uid) AS sync_highest_uid
                FROM mailbox_sync
                GROUP BY account_id
                """
            ).fetchall()
            sync_by_account = {row["account_id"]: dict(row) for row in sync_rows}
            result = []
            for row in rows:
                item = dict(row)
                sync = sync_by_account.get(item["id"], {})
                item["server_total"] = sync.get("server_total") or 0
                item["server_matched"] = sync.get("server_matched") or 0
                item["sync_last_at"] = sync.get("sync_last_at") or ""
                item["sync_highest_uid"] = sync.get("sync_highest_uid") or 0
                auth = account_configs.get(item["id"], {}).get("auth")
                if isinstance(auth, dict):
                    item["auth_method"] = str(auth.get("method") or "password")
                    item["auth_provider"] = str(auth.get("provider") or "")
                else:
                    item["auth_method"] = "password"
                    item["auth_provider"] = ""
                result.append(item)
            return result

    def stats(self) -> dict[str, Any]:
        with self.connect() as conn:
            row = conn.execute(
                """
                SELECT COUNT(*) AS total,
                       SUM(CASE WHEN include_state='candidate' THEN 1 ELSE 0 END) AS candidate,
                       SUM(CASE WHEN include_state='included' THEN 1 ELSE 0 END) AS included,
                       SUM(CASE WHEN include_state='excluded' THEN 1 ELSE 0 END) AS excluded,
                       SUM(CASE WHEN exported_path IS NOT NULL THEN 1 ELSE 0 END) AS exported
                FROM messages
                """
            ).fetchone()
            tags = conn.execute(
                "SELECT tag, COUNT(*) AS count FROM message_tags GROUP BY tag ORDER BY count DESC, tag LIMIT 30"
            ).fetchall()
            return {
                "database": str(self.db_path),
                "emailVaultDir": str((self.vault_root / self.email_vault_dir).resolve()),
                "messages": dict(row) if row else {},
                "accounts": self.accounts(),
                "topTags": [dict(tag) for tag in tags],
            }

    def dashboard(self, limit: int = 30) -> dict[str, Any]:
        accounts = self.accounts()
        stats = self.stats()
        recent = self.list_messages({"limit": [str(limit)], "state": ["active"]})["messages"]
        enabled_accounts = [account for account in accounts if account.get("enabled")]
        return {
            "ok": True,
            "stats": stats,
            "accounts": accounts,
            "recent": recent,
            "summary": {
                "accounts": len(accounts),
                "enabledAccounts": len(enabled_accounts),
                "serverTotal": sum(int(account.get("server_total") or 0) for account in accounts),
                "serverMatched": sum(int(account.get("server_matched") or 0) for account in accounts),
                "localTotal": int((stats.get("messages") or {}).get("total") or 0),
                "exported": int((stats.get("messages") or {}).get("exported") or 0),
            },
        }

    def list_messages(self, query: dict[str, list[str]]) -> dict[str, Any]:
        limit = clamp_int(first(query, "limit", "100"), 1, 500, 100)
        offset = clamp_int(first(query, "offset", "0"), 0, 1_000_000, 0)
        where = []
        args: list[Any] = []
        q = first(query, "q", "").strip()
        state = first(query, "state", "").strip()
        account = first(query, "account", "").strip()
        tag = first(query, "tag", "").strip()
        if q:
            like = f"%{q}%"
            where.append("(m.subject LIKE ? OR m.sender_email LIKE ? OR m.sender_name LIKE ? OR m.body_markdown LIKE ?)")
            args.extend([like, like, like, like])
        if state == "active":
            where.append("m.include_state IN ('candidate', 'included')")
        elif state:
            where.append("m.include_state = ?")
            args.append(state)
        if account:
            where.append("m.account_id = ?")
            args.append(account)
        if tag:
            where.append("EXISTS (SELECT 1 FROM message_tags mt WHERE mt.message_id=m.id AND mt.tag=?)")
            args.append(tag)
        where_sql = " WHERE " + " AND ".join(where) if where else ""
        with self.connect() as conn:
            total = conn.execute(f"SELECT COUNT(*) AS c FROM messages m{where_sql}", args).fetchone()["c"]
            rows = conn.execute(
                f"""
                SELECT m.id, m.account_id, m.mailbox, m.uid, m.message_id, m.subject,
                       m.sender_name, m.sender_email, m.sent_at, m.fetched_at, m.include_state,
                       m.include_reason, m.importance_score, m.spam_score, m.exported_path,
                       COALESCE(GROUP_CONCAT(mt.tag, ','), '') AS tags
                FROM messages m
                LEFT JOIN message_tags mt ON mt.message_id = m.id
                {where_sql}
                GROUP BY m.id
                ORDER BY COALESCE(m.sent_at, m.fetched_at) DESC
                LIMIT ? OFFSET ?
                """,
                args + [limit, offset],
            ).fetchall()
            return {"total": total, "limit": limit, "offset": offset, "messages": [dict(row) for row in rows]}

    def get_message(self, message_id: str) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM messages WHERE id=?", (message_id,)).fetchone()
            if not row:
                return None
            tags = conn.execute("SELECT tag, source FROM message_tags WHERE message_id=? ORDER BY tag", (message_id,)).fetchall()
            data = dict(row)
            data["tags"] = [dict(tag) for tag in tags]
            data["classificationLabels"] = [dict(label) for label in conn.execute(
                "SELECT task, label, source, review_mode, created_at, updated_at FROM message_labels WHERE message_id=? ORDER BY task",
                (message_id,),
            ).fetchall()]
            predictions = conn.execute(
                """
                SELECT p.task, p.predicted_label, p.score, p.scores_json, p.input_hash,
                       p.created_at, r.id AS run_id, r.model_id, r.model_revision
                FROM message_predictions p
                JOIN classification_runs r ON r.id=p.run_id
                WHERE p.message_id=?
                ORDER BY r.started_at DESC
                LIMIT 10
                """,
                (message_id,),
            ).fetchall()
            data["classificationPredictions"] = []
            for prediction in predictions:
                item = dict(prediction)
                item["scores"] = json.loads(item.pop("scores_json") or "{}")
                data["classificationPredictions"].append(item)
            return data

    def upsert_rule(self, payload: dict[str, Any]) -> dict[str, Any]:
        scope = str(payload.get("scope") or "global").strip()
        account_id = str(payload.get("accountId") or payload.get("account_id") or "").strip() or None
        if scope not in {"global", "account"}:
            raise ValueError("Unsupported rule scope")
        if scope == "account" and not account_id:
            raise ValueError("Account-scoped rule requires accountId")
        if scope == "global":
            account_id = None
        rule_id = str(payload.get("id") or stable_hash([payload.get("name"), payload.get("field"), payload.get("pattern"), scope, account_id])[:16])
        now = iso_now()
        name = str(payload.get("name") or payload.get("pattern") or rule_id).strip()
        field = str(payload.get("field") or "sender_email").strip()
        operator = str(payload.get("operator") or "contains").strip()
        pattern = str(payload.get("pattern") or "").strip()
        action = str(payload.get("action") or "tag").strip()
        tag = str(payload.get("tag") or "").strip() or None
        enabled = 1 if payload.get("enabled", True) else 0
        if not pattern:
            raise ValueError("Rule pattern is required")
        if field not in {"sender_email", "sender_domain", "subject", "body", "account_id"}:
            raise ValueError("Unsupported rule field")
        if operator not in {"contains", "equals", "regex"}:
            raise ValueError("Unsupported rule operator")
        if action not in {"exclude", "include", "tag"}:
            raise ValueError("Unsupported rule action")
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO rules(id, name, enabled, scope, account_id, field, operator, pattern, action, tag, created_at, updated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name=excluded.name, enabled=excluded.enabled, scope=excluded.scope,
                  account_id=excluded.account_id, field=excluded.field,
                  operator=excluded.operator, pattern=excluded.pattern, action=excluded.action,
                  tag=excluded.tag, updated_at=excluded.updated_at
                """,
                (rule_id, name, enabled, scope, account_id, field, operator, pattern, action, tag, now, now),
            )
        return {"ok": True, "id": rule_id}

    def list_rules(self) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT r.*, COALESCE(hit_counts.hit_count, 0) AS hit_count
                FROM rules r
                LEFT JOIN (
                  SELECT rule_id, COUNT(*) AS hit_count
                  FROM rule_matches
                  GROUP BY rule_id
                ) hit_counts ON hit_counts.rule_id = r.id
                ORDER BY r.enabled DESC, r.updated_at DESC, r.name
                """
            ).fetchall()
            return [dict(row) for row in rows]

    def list_tags(self) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT tag, COUNT(*) AS count FROM message_tags GROUP BY tag ORDER BY count DESC, tag"
            ).fetchall()
            return [dict(row) for row in rows]

    def classification_models(self) -> list[dict[str, Any]]:
        """Return local model adapters without loading their weights."""
        return available_models()

    def list_classification_runs(self, limit: int = 20) -> list[dict[str, Any]]:
        """Return recent immutable model-run metadata."""
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM classification_runs ORDER BY started_at DESC LIMIT ?",
                (clamp_int(limit, 1, 100, 20),),
            ).fetchall()
        result = []
        for row in rows:
            item = dict(row)
            item["config"] = json.loads(item.pop("config_json") or "{}")
            item["selection"] = json.loads(item.pop("selection_json") or "{}")
            result.append(item)
        return result

    def start_classification_run(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Queue a local shadow classification run without changing mail workflow state."""
        model_id = str(payload.get("modelId") or "gliclass-multilang-mini").strip()
        if model_id not in MODEL_SPECS:
            raise ValueError("Unsupported classification model")
        model = next(item for item in self.classification_models() if item["id"] == model_id)
        if not model["available"]:
            raise RuntimeError(f"Model dependencies are missing: {', '.join(model['missing'])}")
        selection_mode = str(payload.get("selection") or "all").strip()
        if selection_mode not in {"all", "unlabeled"}:
            raise ValueError("Unsupported classification selection")
        account_id = str(payload.get("accountId") or "").strip()
        limit = clamp_int(payload.get("limit"), 1, 10000, 500)
        device = str(payload.get("device") or "auto").strip().lower()
        if device not in {"auto", "cpu", "cuda", "cuda:0"}:
            raise ValueError("Device must be auto, cpu, or cuda")
        threshold = float(payload.get("threshold", 0.5))
        margin = float(payload.get("uncertaintyMargin", 0.08))
        if not 0 <= threshold <= 1 or not 0 <= margin <= 1:
            raise ValueError("Classification threshold and uncertainty margin must be between 0 and 1")
        where = []
        args: list[Any] = []
        if account_id:
            where.append("m.account_id=?")
            args.append(account_id)
        if selection_mode == "unlabeled":
            where.append("NOT EXISTS (SELECT 1 FROM message_labels ml WHERE ml.message_id=m.id AND ml.task='spam')")
        where_sql = " WHERE " + " AND ".join(where) if where else ""
        with self._classification_lock, self.connect() as conn:
            active = conn.execute(
                "SELECT id FROM classification_runs WHERE status IN ('queued', 'running') LIMIT 1"
            ).fetchone()
            if active:
                raise RuntimeError(f"Classification run {active['id']} is already active")
            rows = conn.execute(
                f"""
                SELECT m.id, m.account_id, m.subject, m.sender_name, m.sender_email,
                       m.body_text, m.body_markdown, m.body_hash, m.sent_at
                FROM messages m{where_sql}
                ORDER BY COALESCE(m.sent_at, m.fetched_at) DESC
                LIMIT ?
                """,
                args + [limit],
            ).fetchall()
            messages = [dict(row) for row in rows]
            if not messages:
                raise ValueError("No messages match the classification selection")
            run_id = f"run-{secrets.token_hex(8)}"
            now = iso_now()
            config = {
                "adapterVersion": "spam-v1",
                "device": device,
                "threshold": threshold,
                "uncertaintyMargin": margin,
            }
            selection = {"mode": selection_mode, "accountId": account_id, "limit": limit}
            conn.execute(
                """
                INSERT INTO classification_runs(
                  id, task, model_id, model_revision, config_json, selection_json,
                  status, message_count, completed_count, started_at
                ) VALUES(?, 'spam', ?, ?, ?, ?, 'queued', ?, 0, ?)
                """,
                (
                    run_id,
                    model_id,
                    str(MODEL_SPECS[model_id]["revision"]),
                    json.dumps(config, sort_keys=True),
                    json.dumps(selection, sort_keys=True),
                    len(messages),
                    now,
                ),
            )
        worker = threading.Thread(
            target=self._execute_classification_run,
            args=(run_id, model_id, messages, config),
            daemon=True,
            name=f"email-classification-{run_id}",
        )
        worker.start()
        return {"ok": True, "runId": run_id, "status": "queued", "messageCount": len(messages)}

    def _execute_classification_run(
        self,
        run_id: str,
        model_id: str,
        messages: list[dict[str, Any]],
        config: dict[str, Any],
    ) -> None:
        """Execute one model run in a background thread and retain partial diagnostics."""
        try:
            with self.connect() as conn:
                conn.execute("UPDATE classification_runs SET status='running' WHERE id=?", (run_id,))
            message_by_id = {message["id"]: message for message in messages}
            completed = 0
            predictions = classify_messages(
                model_id,
                messages,
                device=str(config["device"]),
                threshold=float(config["threshold"]),
                uncertainty_margin=float(config["uncertaintyMargin"]),
            )
            for prediction in predictions:
                message = message_by_id[prediction["message_id"]]
                completed += 1
                with self.connect() as conn:
                    resolved_revision = str(prediction.get("model_revision") or MODEL_SPECS[model_id]["revision"])
                    conn.execute(
                        """
                        INSERT OR REPLACE INTO message_predictions(
                          run_id, message_id, task, predicted_label, score,
                          scores_json, input_hash, created_at
                        ) VALUES(?, ?, 'spam', ?, ?, ?, ?, ?)
                        """,
                        (
                            run_id,
                            prediction["message_id"],
                            prediction["label"],
                            prediction.get("score"),
                            json.dumps(prediction.get("scores") or {}, sort_keys=True),
                            sha256_text(message_text(message)),
                            iso_now(),
                        ),
                    )
                    conn.execute(
                        "UPDATE classification_runs SET completed_count=?, model_revision=? WHERE id=?",
                        (completed, resolved_revision, run_id),
                    )
            with self.connect() as conn:
                conn.execute(
                    "UPDATE classification_runs SET status='completed', completed_at=? WHERE id=?",
                    (iso_now(), run_id),
                )
        except Exception as exc:
            with self.connect() as conn:
                conn.execute(
                    "UPDATE classification_runs SET status='failed', error=?, completed_at=? WHERE id=?",
                    (str(exc)[:2000], iso_now(), run_id),
                )

    def classification_summary(self, run_id: str = "") -> dict[str, Any]:
        """Return review progress and held-out metrics for one model run."""
        with self.connect() as conn:
            total = int(conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0])
            label_rows = conn.execute(
                "SELECT message_id, label, review_mode FROM message_labels WHERE task='spam'"
            ).fetchall()
            if run_id:
                latest_row = conn.execute("SELECT * FROM classification_runs WHERE id=?", (run_id,)).fetchone()
                if not latest_row:
                    raise ValueError("Classification run not found")
            else:
                latest_row = conn.execute(
                    "SELECT * FROM classification_runs ORDER BY started_at DESC LIMIT 1"
                ).fetchone()
            prediction_rows = []
            if latest_row:
                prediction_rows = conn.execute(
                    "SELECT message_id, predicted_label, score FROM message_predictions WHERE run_id=? AND task='spam'",
                    (latest_row["id"],),
                ).fetchall()
        label_counts = {"ham": 0, "spam": 0, "unsure": 0}
        human = {}
        holdout_reviewed = 0
        for row in label_rows:
            label_counts[row["label"]] = label_counts.get(row["label"], 0) + 1
            human[row["message_id"]] = row["label"]
            if is_holdout_message(row["message_id"]):
                holdout_reviewed += 1
        prediction_counts = {"ham": 0, "spam": 0, "unsure": 0}
        correct = evaluated = false_positives = false_negatives = predicted_spam = actual_spam = 0
        for row in prediction_rows:
            predicted = row["predicted_label"]
            prediction_counts[predicted] = prediction_counts.get(predicted, 0) + 1
            actual = human.get(row["message_id"])
            if not is_holdout_message(row["message_id"]):
                continue
            if actual not in {"ham", "spam"} or predicted not in {"ham", "spam"}:
                continue
            evaluated += 1
            correct += int(actual == predicted)
            predicted_spam += int(predicted == "spam")
            actual_spam += int(actual == "spam")
            false_positives += int(predicted == "spam" and actual == "ham")
            false_negatives += int(predicted == "ham" and actual == "spam")
        true_positives = predicted_spam - false_positives
        metrics = {
            "evaluated": evaluated,
            "accuracy": correct / evaluated if evaluated else None,
            "spamPrecision": true_positives / predicted_spam if predicted_spam else None,
            "spamRecall": true_positives / actual_spam if actual_spam else None,
            "falsePositives": false_positives,
            "falseNegatives": false_negatives,
        }
        latest = dict(latest_row) if latest_row else None
        if latest:
            latest["config"] = json.loads(latest.pop("config_json") or "{}")
            latest["selection"] = json.loads(latest.pop("selection_json") or "{}")
        return {
            "ok": True,
            "totalMessages": total,
            "reviewed": len(label_rows),
            "remaining": max(0, total - len(label_rows)),
            "holdoutReviewed": holdout_reviewed,
            "labels": label_counts,
            "predictions": prediction_counts,
            "latestRun": latest,
            "metrics": metrics,
        }

    def list_classification_queue(self, query: dict[str, list[str]]) -> dict[str, Any]:
        """Return a bounded training or prediction-blind human review queue."""
        mode = first(query, "mode", "training").strip()
        if mode not in {"training", "blind", "all"}:
            raise ValueError("Unsupported review mode")
        queue_filter = first(query, "filter", "unlabeled").strip()
        if queue_filter not in {"unlabeled", "labeled", "all", "disagreement", "uncertain"}:
            raise ValueError("Unsupported review filter")
        limit = clamp_int(first(query, "limit", "100"), 1, 500, 100)
        run_id = first(query, "runId", "").strip()
        with self.connect() as conn:
            if not run_id:
                run = conn.execute(
                    "SELECT id FROM classification_runs ORDER BY started_at DESC LIMIT 1"
                ).fetchone()
                run_id = str(run["id"]) if run else ""
            rows = conn.execute(
                """
                SELECT m.id, m.account_id, m.mailbox, m.message_id, m.subject,
                       m.sender_name, m.sender_email, m.sent_at, m.fetched_at,
                       m.body_text, m.body_markdown, m.body_hash,
                       spam.label AS human_label, spam.review_mode AS human_review_mode,
                       kind.label AS mail_type,
                       p.predicted_label, p.score, p.scores_json
                FROM messages m
                LEFT JOIN message_labels spam ON spam.message_id=m.id AND spam.task='spam'
                LEFT JOIN message_labels kind ON kind.message_id=m.id AND kind.task='mail_type'
                LEFT JOIN message_predictions p ON p.message_id=m.id AND p.task='spam' AND p.run_id=?
                ORDER BY COALESCE(m.sent_at, m.fetched_at) DESC
                """,
                (run_id,),
            ).fetchall()
        candidates = []
        for row in rows:
            item = dict(row)
            item["holdout"] = is_holdout_message(item["id"])
            if mode == "blind" and not item["holdout"]:
                continue
            if mode == "training" and item["holdout"]:
                continue
            if queue_filter == "unlabeled" and item["human_label"]:
                continue
            if queue_filter == "labeled" and not item["human_label"]:
                continue
            if queue_filter == "disagreement" and (
                not item["human_label"]
                or not item["predicted_label"]
                or item["human_label"] == item["predicted_label"]
            ):
                continue
            if queue_filter == "uncertain" and item["predicted_label"] != "unsure":
                continue
            item["scores"] = json.loads(item.pop("scores_json") or "{}") if run_id else {}
            hidden = mode == "blind" and not item["human_label"]
            item["predictionHidden"] = hidden
            if hidden:
                item["predicted_label"] = None
                item["score"] = None
                item["scores"] = {}
            candidates.append(item)
        candidates.sort(key=lambda item: classification_queue_sort(item, queue_filter))
        return {"ok": True, "runId": run_id or None, "mode": mode, "filter": queue_filter, "messages": candidates[:limit]}

    def set_classification_label(self, payload: dict[str, Any], *, source: str = "human") -> dict[str, Any]:
        """Record a current label plus an append-only correction event."""
        message_id = str(payload.get("messageId") or "").strip()
        task = str(payload.get("task") or "spam").strip()
        label = str(payload.get("label") or "").strip()
        review_mode = str(payload.get("reviewMode") or "training").strip()
        validate_classification_label(task, label)
        if review_mode not in {"training", "blind", "import", "rule", "provider"}:
            raise ValueError("Unsupported label review mode")
        with self.connect() as conn:
            if not conn.execute("SELECT 1 FROM messages WHERE id=?", (message_id,)).fetchone():
                raise ValueError("Message not found")
            self._write_classification_label(conn, message_id, task, label, source, review_mode)
        return {"ok": True, "messageId": message_id, "task": task, "label": label}

    def _write_classification_label(
        self,
        conn: sqlite3.Connection,
        message_id: str,
        task: str,
        label: str,
        source: str,
        review_mode: str,
    ) -> None:
        now = iso_now()
        conn.execute(
            "INSERT INTO label_events(message_id, task, label, source, review_mode, created_at) VALUES(?, ?, ?, ?, ?, ?)",
            (message_id, task, label, source, review_mode, now),
        )
        conn.execute(
            """
            INSERT INTO message_labels(message_id, task, label, source, review_mode, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(message_id, task) DO UPDATE SET
              label=excluded.label, source=excluded.source,
              review_mode=excluded.review_mode, updated_at=excluded.updated_at
            """,
            (message_id, task, label, source, review_mode, now, now),
        )

    def export_classification_labels(self, include_content: bool = False) -> dict[str, Any]:
        """Return portable annotations; message content is opt-in because it is sensitive."""
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT m.id, m.account_id, m.mailbox, m.uid, m.message_id, m.sent_at,
                       m.subject, m.sender_email, m.body_text, m.body_hash
                FROM messages m
                WHERE EXISTS (SELECT 1 FROM message_labels ml WHERE ml.message_id=m.id)
                ORDER BY COALESCE(m.sent_at, m.fetched_at), m.id
                """
            ).fetchall()
            records = []
            for row in rows:
                message = dict(row)
                labels = [dict(label) for label in conn.execute(
                    "SELECT task, label, source, review_mode, created_at, updated_at FROM message_labels WHERE message_id=? ORDER BY task",
                    (message["id"],),
                ).fetchall()]
                identity = {
                    "id": message["id"],
                    "accountId": message["account_id"],
                    "mailbox": message["mailbox"],
                    "uid": message["uid"],
                    "rfcMessageId": message["message_id"],
                    "sentAt": message["sent_at"],
                    "bodyHash": message["body_hash"],
                }
                record: dict[str, Any] = {"message": identity, "labels": labels}
                if include_content:
                    record["content"] = {
                        "subject": message["subject"],
                        "senderEmail": message["sender_email"],
                        "bodyText": message["body_text"],
                    }
                records.append(record)
        return {
            "schemaVersion": 1,
            "exportedAt": iso_now(),
            "containsMessageContent": include_content,
            "records": records,
        }

    def import_classification_labels(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Restore portable annotations while refusing ambiguous message matches."""
        records = payload.get("records")
        if not isinstance(records, list) or len(records) > 50000:
            raise ValueError("Classification import requires at most 50000 records")
        imported = skipped = unchanged = 0
        with self.connect() as conn:
            for record in records:
                if not isinstance(record, dict) or not isinstance(record.get("message"), dict):
                    skipped += 1
                    continue
                identity = record["message"]
                message_id = str(identity.get("id") or "")
                row = conn.execute("SELECT id FROM messages WHERE id=?", (message_id,)).fetchone()
                if not row and identity.get("rfcMessageId"):
                    matches = conn.execute(
                        "SELECT id FROM messages WHERE account_id=? AND message_id=? LIMIT 2",
                        (str(identity.get("accountId") or ""), str(identity["rfcMessageId"])),
                    ).fetchall()
                    row = matches[0] if len(matches) == 1 else None
                if not row or not isinstance(record.get("labels"), list):
                    skipped += 1
                    continue
                for label_item in record["labels"]:
                    task = str(label_item.get("task") or "")
                    label = str(label_item.get("label") or "")
                    validate_classification_label(task, label)
                    current = conn.execute(
                        "SELECT label FROM message_labels WHERE message_id=? AND task=?",
                        (row["id"], task),
                    ).fetchone()
                    if current and current["label"] == label:
                        unchanged += 1
                        continue
                    self._write_classification_label(conn, row["id"], task, label, "import", "import")
                    imported += 1
        return {"ok": True, "imported": imported, "unchanged": unchanged, "skipped": skipped}

    def delete_rule(self, rule_id: str) -> dict[str, Any]:
        with self.connect() as conn:
            conn.execute("DELETE FROM rules WHERE id=?", (rule_id,))
        return {"ok": True}

    def tag_message(self, payload: dict[str, Any]) -> dict[str, Any]:
        message_id = str(payload.get("messageId") or "").strip()
        tag = normalize_tag(payload.get("tag"))
        state = str(payload.get("state") or "").strip()
        source = str(payload.get("source") or "manual").strip() or "manual"
        with self.connect() as conn:
            if tag:
                conn.execute(
                    "INSERT OR IGNORE INTO message_tags(message_id, tag, source, created_at) VALUES(?, ?, ?, ?)",
                    (message_id, tag, source, iso_now()),
                )
            if state in {"candidate", "included", "excluded"}:
                conn.execute(
                    "UPDATE messages SET include_state=?, include_reason=? WHERE id=?",
                    (state, "manual", message_id),
                )
        return {"ok": True}

    def apply_rules(self) -> dict[str, Any]:
        with self.connect() as conn:
            rules = [dict(row) for row in conn.execute("SELECT * FROM rules WHERE enabled=1 ORDER BY updated_at ASC")]
            rows = [dict(row) for row in conn.execute("SELECT id, account_id, sender_email, subject, body_markdown, include_state, include_reason FROM messages")]
            changed = 0
            matched = 0
            now = iso_now()
            conn.execute("DELETE FROM rule_matches")
            for msg in rows:
                next_state = msg["include_state"]
                next_reason = msg["include_reason"]
                for rule in rules:
                    if not rule_matches(rule, msg):
                        continue
                    matched += 1
                    conn.execute(
                        "INSERT OR REPLACE INTO rule_matches(message_id, rule_id, matched_at, result_json) VALUES(?, ?, ?, ?)",
                        (msg["id"], rule["id"], now, json.dumps({"action": rule["action"], "tag": rule.get("tag")})),
                    )
                    if rule["action"] in {"include", "exclude"}:
                        next_state = "included" if rule["action"] == "include" else "excluded"
                        next_reason = f"rule:{rule['id']}"
                    if rule.get("tag"):
                        conn.execute(
                            "INSERT OR IGNORE INTO message_tags(message_id, tag, source, created_at) VALUES(?, ?, ?, ?)",
                            (msg["id"], normalize_tag(rule["tag"]), f"rule:{rule['id']}", now),
                        )
                if next_state != msg["include_state"] or next_reason != msg["include_reason"]:
                    conn.execute(
                        "UPDATE messages SET include_state=?, include_reason=? WHERE id=?",
                        (next_state, next_reason, msg["id"]),
                    )
                    changed += 1
            return {"ok": True, "rules": len(rules), "matches": matched, "changed": changed}

    def fetch(self, payload: dict[str, Any]) -> dict[str, Any]:
        account_id = str(payload.get("accountId") or "").strip()
        if not account_id:
            raise ValueError("accountId is required")
        account = self.account_config(account_id)
        if not account:
            raise ValueError(f"Unknown account: {account_id}")
        if account.get("enabled") is False:
            raise ValueError(f"Account is disabled: {account_id}")
        mailboxes = payload.get("mailboxes") or account.get("mailboxes") or ["INBOX"]
        if isinstance(mailboxes, str):
            mailboxes = [mailboxes]
        limit = clamp_int(payload.get("limit"), 1, 10000, 500)
        if not payload.get("nestedProgress"):
            self.set_progress(
                active=True,
                phase="connect",
                operation="fetch-new" if payload.get("incremental") else "fetch-range",
                accountId=account_id,
                mailbox="",
                current=0,
                total=0,
                fetched=0,
                message=f"Connecting {account_id}...",
            )
        result = {"ok": True, "accountId": account_id, "fetched": 0, "mailboxes": []}
        try:
            with self._lock:
                with self.open_imap(account) as imap:
                    for mailbox in mailboxes:
                        mailbox_name = str(mailbox)
                        mailbox_payload = dict(payload)
                        if payload.get("incremental"):
                            state = self.get_mailbox_sync_state(account_id, mailbox_name)
                            mailbox_payload["minUid"] = int(state.get("highest_uid") or 0) + 1
                        box_result = self.fetch_mailbox(imap, account, mailbox_name, mailbox_payload, limit)
                        result["mailboxes"].append(box_result)
                        result["fetched"] += box_result["stored"]
                        if payload.get("incremental") and box_result.get("highestFetchedUid"):
                            self.update_mailbox_sync_state(
                                account_id,
                                mailbox_name,
                                int(box_result["highestFetchedUid"]),
                                int(box_result.get("total") or 0),
                                int(box_result.get("matched") or 0),
                            )
        except Exception as exc:
            self.set_progress(active=False, phase="error", message=str(exc))
            raise
        result["total"] = sum(item["total"] for item in result["mailboxes"])
        result["matched"] = sum(item["matched"] for item in result["mailboxes"])
        result["stored"] = sum(item["stored"] for item in result["mailboxes"])
        result["localStored"] = sum(item.get("localStored", item["stored"]) for item in result["mailboxes"])
        if not payload.get("nestedProgress"):
            self.set_progress(
                active=False,
                phase="done",
                accountId=account_id,
                current=result["matched"],
                total=result["matched"],
                fetched=result["fetched"],
                message=f"Fetched {result['fetched']} new messages from {account_id}",
            )
        return result

    def fetch_new(self, payload: dict[str, Any]) -> dict[str, Any]:
        next_payload = dict(payload)
        next_payload["incremental"] = True
        next_payload.pop("minUid", None)
        return self.fetch(next_payload)

    def get_mailbox_sync_state(self, account_id: str, mailbox: str) -> dict[str, Any]:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM mailbox_sync WHERE account_id=? AND mailbox=?",
                (account_id, mailbox),
            ).fetchone()
            if row:
                return dict(row)
            max_uid = conn.execute(
                "SELECT MAX(CAST(uid AS INTEGER)) AS uid FROM messages WHERE account_id=? AND mailbox=? AND uid GLOB '[0-9]*'",
                (account_id, mailbox),
            ).fetchone()["uid"]
            return {"account_id": account_id, "mailbox": mailbox, "highest_uid": int(max_uid or 0)}

    def update_mailbox_sync_state(self, account_id: str, mailbox: str, highest_uid: int, total: int, matched: int) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO mailbox_sync(account_id, mailbox, highest_uid, last_sync_at, last_total, last_matched, last_error)
                VALUES(?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(account_id, mailbox) DO UPDATE SET
                  highest_uid=MAX(mailbox_sync.highest_uid, excluded.highest_uid),
                  last_sync_at=excluded.last_sync_at,
                  last_total=excluded.last_total,
                  last_matched=excluded.last_matched,
                  last_error=NULL
                """,
                (account_id, mailbox, highest_uid, iso_now(), total, matched),
            )

    def update_mailbox_count_state(self, account_id: str, mailbox: str, total: int, matched: int) -> None:
        state = self.get_mailbox_sync_state(account_id, mailbox)
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO mailbox_sync(account_id, mailbox, highest_uid, last_sync_at, last_total, last_matched, last_error)
                VALUES(?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(account_id, mailbox) DO UPDATE SET
                  last_sync_at=excluded.last_sync_at,
                  last_total=excluded.last_total,
                  last_matched=excluded.last_matched,
                  last_error=NULL
                """,
                (account_id, mailbox, int(state.get("highest_uid") or 0), iso_now(), total, matched),
            )

    def count_mailboxes(self, payload: dict[str, Any]) -> dict[str, Any]:
        account_id = str(payload.get("accountId") or "").strip()
        if not account_id:
            raise ValueError("accountId is required")
        account = self.account_config(account_id)
        if not account:
            raise ValueError(f"Unknown account: {account_id}")
        if account.get("enabled") is False:
            raise ValueError(f"Account is disabled: {account_id}")
        mailboxes = payload.get("mailboxes") or account.get("mailboxes") or ["INBOX"]
        if isinstance(mailboxes, str):
            mailboxes = [mailboxes]
        result = {"ok": True, "accountId": account_id, "mailboxes": []}
        if not payload.get("nestedProgress"):
            self.set_progress(
                active=True,
                phase="count",
                operation="count",
                accountId=account_id,
                current=0,
                total=len(mailboxes),
                fetched=0,
                message=f"Counting {account_id}...",
            )
        with self._lock:
            with self.open_imap(account) as imap:
                for index, mailbox in enumerate(mailboxes, start=1):
                    mailbox_name = str(mailbox)
                    self.set_progress(current=index - 1, total=len(mailboxes), mailbox=mailbox_name, message=f"Counting {account_id} / {mailbox_name}")
                    box_result = self.count_mailbox(imap, account_id, mailbox_name, payload)
                    result["mailboxes"].append(box_result)
                    self.update_mailbox_count_state(
                        account_id,
                        mailbox_name,
                        int(box_result.get("total") or 0),
                        int(box_result.get("matched") or 0),
                    )
                    self.set_progress(current=index, total=len(mailboxes), mailbox=mailbox_name, message=f"Counted {account_id} / {mailbox_name}")
        result["total"] = sum(item["total"] for item in result["mailboxes"])
        result["matched"] = sum(item["matched"] for item in result["mailboxes"])
        result["stored"] = sum(item["stored"] for item in result["mailboxes"])
        result["localStored"] = result["stored"]
        result["newAvailable"] = sum(item.get("newAvailable", 0) for item in result["mailboxes"])
        if not payload.get("nestedProgress"):
            self.set_progress(
                active=False,
                phase="done",
                accountId=account_id,
                current=len(mailboxes),
                total=len(mailboxes),
                fetched=0,
                message=f"Counted {account_id}: {result['newAvailable']} new",
            )
        return result

    def count_all(self, payload: dict[str, Any]) -> dict[str, Any]:
        results = []
        total = 0
        matched = 0
        local_stored = 0
        new_available = 0
        succeeded = 0
        failed = 0
        enabled_accounts = [account for account in self.config.get("accounts", []) if str(account.get("id") or "").strip() and account.get("enabled") is not False]
        self.set_progress(active=True, phase="count", operation="count-all", current=0, total=len(enabled_accounts), fetched=0, message="Counting all accounts...")
        for index, account in enumerate(enabled_accounts, start=1):
            account_id = str(account.get("id") or "").strip()
            try:
                self.set_progress(current=index - 1, total=len(enabled_accounts), accountId=account_id, message=f"Counting {account_id} ({index}/{len(enabled_accounts)})")
                result = self.count_mailboxes({"accountId": account_id, **payload, "nestedProgress": True})
                results.append(result)
                total += int(result.get("total") or 0)
                matched += int(result.get("matched") or 0)
                local_stored += int(result.get("localStored") or 0)
                new_available += int(result.get("newAvailable") or 0)
                succeeded += 1
            except Exception as exc:
                results.append({"ok": False, "accountId": account_id, "error": str(exc)})
                failed += 1
            self.set_progress(current=index, total=len(enabled_accounts), accountId=account_id, message=f"Counted {index}/{len(enabled_accounts)} accounts")
        result_summary = f"Counted {succeeded}/{len(enabled_accounts)} accounts"
        if failed:
            result_summary += f"; {failed} failed"
        self.set_progress(active=False, phase="done", current=len(enabled_accounts), total=len(enabled_accounts), fetched=0, message=result_summary)
        return {
            "ok": True,
            "accounts": results,
            "succeeded": succeeded,
            "failed": failed,
            "partial": failed > 0,
            "total": total,
            "matched": matched,
            "localStored": local_stored,
            "newAvailable": new_available,
        }

    def fetch_new_all(self, payload: dict[str, Any]) -> dict[str, Any]:
        results = []
        fetched = 0
        matched = 0
        total = 0
        succeeded = 0
        failed = 0
        enabled_accounts = [account for account in self.config.get("accounts", []) if str(account.get("id") or "").strip() and account.get("enabled") is not False]
        self.set_progress(active=True, phase="fetch", operation="fetch-new-all", current=0, total=len(enabled_accounts), fetched=0, message="Fetching new mail from all accounts...")
        for index, account in enumerate(enabled_accounts, start=1):
            account_id = str(account.get("id") or "").strip()
            try:
                self.set_progress(current=index - 1, total=len(enabled_accounts), accountId=account_id, message=f"Fetching {account_id} ({index}/{len(enabled_accounts)})")
                result = self.fetch_new({"accountId": account_id, **payload, "nestedProgress": True})
                results.append(result)
                fetched += int(result.get("fetched") or 0)
                matched += int(result.get("matched") or 0)
                total += int(result.get("total") or 0)
                succeeded += 1
            except Exception as exc:
                results.append({"ok": False, "accountId": account_id, "error": str(exc)})
                failed += 1
            self.set_progress(current=index, total=len(enabled_accounts), accountId=account_id, fetched=fetched, message=f"Fetched {index}/{len(enabled_accounts)} accounts, {fetched} new messages")
        result_summary = f"Fetched {fetched} new messages from {succeeded}/{len(enabled_accounts)} accounts"
        if failed:
            result_summary += f"; {failed} failed"
        self.set_progress(active=False, phase="done", current=len(enabled_accounts), total=len(enabled_accounts), fetched=fetched, message=result_summary)
        return {
            "ok": True,
            "accounts": results,
            "succeeded": succeeded,
            "failed": failed,
            "partial": failed > 0,
            "fetched": fetched,
            "matched": matched,
            "total": total,
        }

    def account_config(self, account_id: str) -> dict[str, Any] | None:
        for account in self.config.get("accounts", []):
            if str(account.get("id") or "") == account_id:
                return account
        return None

    def open_imap(self, account: dict[str, Any]) -> imaplib.IMAP4:
        host = str(account.get("server") or account.get("host") or "").strip()
        if not host:
            raise ValueError("Account server is required")
        port = int(account.get("port") or (993 if account.get("ssl", True) else 143))
        username = str(account.get("username") or account.get("email") or "").strip()
        password = str(account.get("password") or "")
        password_env = str(account.get("passwordEnv") or "").strip()
        if password_env:
            password = os.environ.get(password_env, password)
        auth = account.get("auth") if isinstance(account.get("auth"), dict) else {}
        auth_method = str(auth.get("method") or "password").strip().lower()
        if not username:
            raise ValueError(f"Missing IMAP username for account {account.get('id')}")
        if account.get("ssl", True):
            client: imaplib.IMAP4 = imaplib.IMAP4_SSL(host, port, ssl_context=ssl.create_default_context())
        else:
            client = imaplib.IMAP4(host, port)
            if account.get("starttls"):
                client.starttls(ssl_context=ssl.create_default_context())
        if auth_method == "oauth":
            access_token = self.get_oauth_access_token(account)
            client.authenticate("XOAUTH2", lambda _challenge: xoauth2_sasl(username, access_token))
        else:
            if not password:
                raise ValueError(f"Missing IMAP credentials for account {account.get('id')}")
            client.login(username, password)
        return client

    def get_oauth_access_token(self, account: dict[str, Any]) -> str:
        auth = account.get("auth") if isinstance(account.get("auth"), dict) else {}
        provider = str(auth.get("provider") or "").strip().lower()
        account_id = str(account.get("id") or "").strip()
        token_path = self.resolve_state_path(account.get("oauthTokenPath") or f"{account_id}.json")
        if not token_path.exists():
            raise ValueError(f"OAuth token file is missing for account {account_id}")
        tokens = json.loads(token_path.read_text(encoding="utf-8"))
        if oauth_token_expired(tokens):
            tokens = refresh_oauth_token(provider, tokens)
            write_json_atomic(token_path, tokens)
        access_token = str(tokens.get("access_token") or "").strip()
        if not access_token:
            raise ValueError(f"OAuth access token is missing for account {account_id}")
        return access_token

    def start_oauth_login(self, payload: dict[str, Any]) -> dict[str, Any]:
        account_id = str(payload.get("accountId") or "").strip()
        account = self.account_config(account_id)
        if not account:
            raise ValueError(f"Unknown account: {account_id}")
        auth = account.get("auth") if isinstance(account.get("auth"), dict) else {}
        provider = str(auth.get("provider") or "").strip().lower()
        if provider != "microsoft":
            raise ValueError("Only Microsoft OAuth login is currently implemented")
        token_url, client_id, _client_secret = oauth_provider_config(provider)
        redirect_uri = f"http://localhost:{self.oauth_callback_port}/callback"
        state = secrets.token_urlsafe(24)
        flow = {
            "account_id": account_id,
            "provider": provider,
            "token_url": token_url,
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "state": state,
            "created_at": time.time(),
            "expires_in": 900,
            "pending": True,
        }
        self.oauth_flows[account_id] = flow
        self.ensure_oauth_callback_server()
        auth_url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?" + urllib.parse.urlencode(
            {
                "client_id": client_id,
                "response_type": "code",
                "redirect_uri": redirect_uri,
                "response_mode": "query",
                "scope": "offline_access https://outlook.office.com/IMAP.AccessAsUser.All",
                "state": state,
                "prompt": "select_account",
                "login_hint": account.get("username") or account.get("email") or "",
            }
        )
        return {
            "ok": True,
            "accountId": account_id,
            "authorizationUrl": auth_url,
            "verificationUri": auth_url,
            "userCode": "",
            "message": "Open the authorization URL, sign in, and approve IMAP access.",
            "expiresIn": flow.get("expires_in"),
            "interval": 2,
        }

    def poll_oauth_login(self, payload: dict[str, Any]) -> dict[str, Any]:
        account_id = str(payload.get("accountId") or "").strip()
        flow = self.oauth_flows.get(account_id)
        if not flow:
            raise ValueError("No OAuth login flow is active for this account")
        if time.time() > flow["created_at"] + int(flow.get("expires_in") or 900):
            self.oauth_flows.pop(account_id, None)
            raise ValueError("OAuth login flow expired")
        if flow.get("error"):
            raise ValueError(str(flow["error"]))
        if flow.get("pending", True):
            return {"ok": True, "pending": True}
        payload = exchange_oauth_code(flow)
        account = self.account_config(account_id)
        if not account:
            raise ValueError(f"Unknown account: {account_id}")
        token_path = self.resolve_state_path(account.get("oauthTokenPath") or f"{account_id}.json")
        tokens = oauth_payload_to_tokens(payload)
        if not str(tokens.get("access_token") or "").strip():
            raise ValueError("OAuth login response did not include an access token")
        with self._lock:
            if not str(tokens.get("refresh_token") or "").strip() and token_path.exists():
                existing_tokens = json.loads(token_path.read_text(encoding="utf-8"))
                tokens["refresh_token"] = existing_tokens.get("refresh_token")
            if not str(tokens.get("refresh_token") or "").strip():
                raise ValueError("OAuth login response did not include a refresh token")
            write_json_atomic(token_path, tokens)
        self.oauth_flows.pop(account_id, None)
        return {"ok": True, "pending": False, "accountId": account_id}

    def ensure_oauth_callback_server(self) -> None:
        if self.oauth_callback_server:
            return
        OAuthCallbackHandler.tool = self
        server = ThreadingHTTPServer(("127.0.0.1", self.oauth_callback_port), OAuthCallbackHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.oauth_callback_server = server

    def fetch_mailbox(
        self,
        imap: imaplib.IMAP4,
        account: dict[str, Any],
        mailbox: str,
        payload: dict[str, Any],
        limit: int,
    ) -> dict[str, Any]:
        status, select_data = imap.select(mailbox, readonly=True)
        if status != "OK":
            raise RuntimeError(f"Cannot open mailbox {mailbox}")
        total = int(select_data[0]) if select_data and select_data[0] else 0
        criteria = build_search_criteria(payload)
        status, data = imap.uid("SEARCH", None, *criteria)
        if status != "OK" or not data:
            return {"mailbox": mailbox, "total": total, "matched": 0, "stored": 0, "localStored": 0, "highestFetchedUid": 0}
        uids = data[0].split()
        if payload.get("minUid"):
            min_uid = int(payload["minUid"])
            uids = [uid for uid in uids if int(uid) >= min_uid]
        matched = len(uids)
        uids = uids[-limit:]
        to_fetch = len(uids)
        stored = 0
        highest_fetched_uid = 0
        self.set_progress(
            active=True,
            phase="fetch",
            accountId=str(account.get("id")),
            mailbox=mailbox,
            current=0,
            total=to_fetch,
            matched=matched,
            fetched=0,
            message=f"{account.get('id')} / {mailbox}: 0/{to_fetch} fetched",
        )
        for index, uid in enumerate(uids, start=1):
            status, msg_data = imap.uid("FETCH", uid, "(BODY.PEEK[])")
            if status != "OK" or not msg_data:
                self.set_progress(current=index, total=to_fetch, fetched=stored, message=f"{account.get('id')} / {mailbox}: {index}/{to_fetch} fetched")
                continue
            raw = first_bytes(msg_data)
            if not raw:
                self.set_progress(current=index, total=to_fetch, fetched=stored, message=f"{account.get('id')} / {mailbox}: {index}/{to_fetch} fetched")
                continue
            parsed = parse_email(raw)
            parsed["account_id"] = str(account.get("id"))
            parsed["mailbox"] = mailbox
            parsed["uid"] = uid.decode("ascii", errors="ignore")
            highest_fetched_uid = max(highest_fetched_uid, int(parsed["uid"] or 0))
            stored += self.store_message(parsed)
            self.set_progress(current=index, total=to_fetch, fetched=stored, message=f"{account.get('id')} / {mailbox}: {index}/{to_fetch} fetched")
        with self.connect() as conn:
            local_stored = conn.execute(
                "SELECT COUNT(*) AS c FROM messages WHERE account_id=? AND mailbox=?",
                (str(account.get("id")), mailbox),
            ).fetchone()["c"]
        return {
            "mailbox": mailbox,
            "total": total,
            "matched": matched,
            "stored": stored,
            "localStored": local_stored,
            "highestFetchedUid": highest_fetched_uid,
        }

    def count_mailbox(self, imap: imaplib.IMAP4, account_id: str, mailbox: str, payload: dict[str, Any]) -> dict[str, Any]:
        status, data = imap.select(mailbox, readonly=True)
        if status != "OK":
            raise RuntimeError(f"Cannot open mailbox {mailbox}")
        total = int(data[0]) if data and data[0] else 0
        criteria = build_search_criteria(payload)
        status, search_data = imap.uid("SEARCH", None, *criteria)
        if status != "OK" or not search_data:
            matched = 0
            uids: list[bytes] = []
        else:
            uids = search_data[0].split()
            if payload.get("minUid"):
                min_uid = int(payload["minUid"])
                uids = [uid for uid in uids if int(uid) >= min_uid]
            matched = len(uids)
        sync_state = self.get_mailbox_sync_state(account_id, mailbox)
        sync_highest_uid = int(sync_state.get("highest_uid") or 0)
        new_available = len([uid for uid in uids if int(uid) > sync_highest_uid])
        with self.connect() as conn:
            stored = conn.execute(
                "SELECT COUNT(*) AS c FROM messages WHERE account_id=? AND mailbox=?",
                (account_id, mailbox),
            ).fetchone()["c"]
        return {
            "mailbox": mailbox,
            "total": total,
            "matched": matched,
            "stored": stored,
            "localStored": stored,
            "syncHighestUid": sync_highest_uid,
            "newAvailable": new_available,
        }

    def store_message(self, parsed: dict[str, Any]) -> int:
        message_id = parsed.get("message_id") or ""
        stable_id = stable_hash([parsed["account_id"], parsed["mailbox"], parsed["uid"], message_id])
        now = iso_now()
        with self.connect() as conn:
            before = conn.execute("SELECT id FROM messages WHERE id=?", (stable_id,)).fetchone()
            conn.execute(
                """
                INSERT INTO messages(
                  id, account_id, mailbox, uid, message_id, thread_key, subject,
                  sender_name, sender_email, recipients_json, cc_json, sent_at, fetched_at,
                  raw_headers_json, body_text, body_markdown, body_hash, attachment_count,
                  size_bytes, include_state, include_reason
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  message_id=excluded.message_id, thread_key=excluded.thread_key, subject=excluded.subject,
                  sender_name=excluded.sender_name, sender_email=excluded.sender_email,
                  recipients_json=excluded.recipients_json, cc_json=excluded.cc_json,
                  sent_at=excluded.sent_at, fetched_at=excluded.fetched_at,
                  raw_headers_json=excluded.raw_headers_json, body_text=excluded.body_text,
                  body_markdown=excluded.body_markdown, body_hash=excluded.body_hash,
                  attachment_count=excluded.attachment_count, size_bytes=excluded.size_bytes
                """,
                (
                    stable_id,
                    parsed["account_id"],
                    parsed["mailbox"],
                    parsed["uid"],
                    message_id,
                    parsed.get("thread_key"),
                    parsed.get("subject"),
                    parsed.get("sender_name"),
                    parsed.get("sender_email"),
                    json.dumps(parsed.get("recipients") or [], ensure_ascii=False),
                    json.dumps(parsed.get("cc") or [], ensure_ascii=False),
                    parsed.get("sent_at"),
                    now,
                    json.dumps(parsed.get("headers") or {}, ensure_ascii=False),
                    parsed.get("body_text"),
                    parsed.get("body_markdown"),
                    parsed.get("body_hash"),
                    parsed.get("attachment_count") or 0,
                    parsed.get("size_bytes") or 0,
                    "candidate",
                    "fetched",
                ),
            )
            return 0 if before else 1

    def normalize_export_selection(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Validate and normalize the bounded export selection."""
        state = str(payload.get("state") or "included").strip()
        if state not in {"candidate", "included", "excluded", "all"}:
            raise ValueError("Unsupported export state")
        limit = clamp_int(payload.get("limit"), 1, 100000, 5000)
        return {
            "state": state,
            "accountId": str(payload.get("accountId") or "").strip(),
            "limit": limit,
        }

    def build_export_snapshot(self, selection: dict[str, Any], conn: sqlite3.Connection) -> dict[str, Any]:
        """Render an export selection and classify its current target files."""
        state = selection["state"]
        limit = selection["limit"]
        args: list[Any] = []
        where = []
        if state != "all":
            where.append("include_state=?")
            args.append(state)
        account_id = selection["accountId"]
        if account_id:
            where.append("account_id=?")
            args.append(account_id)
        where_sql = " WHERE " + " AND ".join(where) if where else ""
        export_root = self.email_vault_root
        rows = conn.execute(
            f"SELECT * FROM messages{where_sql} ORDER BY COALESCE(sent_at, fetched_at) DESC LIMIT ?",
            args + [limit],
        ).fetchall()
        legacy_index = build_legacy_export_filename_index(export_root)
        account_slugs: dict[str, set[str]] = {}
        legacy_message_counts: dict[tuple[str, str], int] = {}
        legacy_identity_counts: dict[tuple[str, str], int] = {}
        for account_row in conn.execute("SELECT account_id, uid, sent_at FROM messages"):
            account_id_value = str(account_row["account_id"] or "account")
            account_slug = legacy_account_slug(account_id_value)
            account_slugs.setdefault(account_slug, set()).add(account_id_value)
            identity_key = (account_slug, str(account_row["uid"] or ""))
            legacy_message_counts[identity_key] = legacy_message_counts.get(identity_key, 0) + 1
            legacy_timestamp = legacy_export_timestamp(account_row["sent_at"])
            if legacy_timestamp:
                timestamp_key = (account_slug, legacy_timestamp)
                legacy_identity_counts[timestamp_key] = legacy_identity_counts.get(timestamp_key, 0) + 1
        legacy_uid_cache: dict[Path, str] = {}
        entries = []
        seen_targets: set[Path] = set()
        for row in rows:
            msg = dict(row)
            msg["tags"] = [
                tag["tag"]
                for tag in conn.execute(
                    "SELECT tag FROM message_tags WHERE message_id=? ORDER BY tag",
                    (msg["id"],),
                )
            ]
            rel_path = self.export_path_for(msg)
            target = (export_root / rel_path).resolve()
            if target != export_root and export_root not in target.parents:
                raise RuntimeError("Export path escaped email directory")
            account_slug = legacy_account_slug(msg.get("account_id") or "account")
            message_uid = str(msg.get("uid") or "")
            legacy_key = (account_slug, message_uid)
            legacy_timestamp = legacy_export_timestamp(msg.get("sent_at"))
            timestamp_key = (account_slug, legacy_timestamp)
            timestamp_candidates = legacy_index.get(timestamp_key, []) if legacy_timestamp else []
            legacy_candidates: list[Path] = []
            legacy_ambiguous = False
            if timestamp_candidates:
                if len(account_slugs.get(account_slug, set())) > 1:
                    legacy_ambiguous = True
                elif legacy_identity_counts.get(timestamp_key, 0) == 1 and len(timestamp_candidates) == 1:
                    legacy_candidates = timestamp_candidates
                else:
                    for candidate in timestamp_candidates:
                        if candidate not in legacy_uid_cache:
                            legacy_uid_cache[candidate] = read_legacy_export_uid(candidate)
                    candidate_uids = [legacy_uid_cache[candidate] for candidate in timestamp_candidates]
                    matching_candidates = [
                        candidate
                        for candidate in timestamp_candidates
                        if legacy_uid_cache[candidate] == message_uid
                    ]
                    if any(not uid for uid in candidate_uids):
                        legacy_ambiguous = True
                    elif len(matching_candidates) == 1 and legacy_message_counts.get(legacy_key, 0) == 1:
                        legacy_candidates = matching_candidates
                    elif matching_candidates:
                        legacy_ambiguous = True
            if not target.exists() and len(legacy_candidates) == 1 and not legacy_ambiguous:
                target = legacy_candidates[0]
                rel_path = target.relative_to(export_root)
            if target in seen_targets:
                raise RuntimeError("Multiple messages resolved to the same export path")
            seen_targets.add(target)
            content = render_markdown(msg).encode("utf-8")
            content_hash = hashlib.sha256(content).hexdigest()
            target_hash = ""
            if legacy_ambiguous and not target.exists():
                target_status = "conflict"
                target_hash = legacy_candidate_fingerprint(export_root, timestamp_candidates)
            elif target.exists():
                if target.is_file():
                    target_hash = sha256_file(target)
                    if len(legacy_candidates) == 1 and target == legacy_candidates[0]:
                        target_status = "legacy-existing"
                    else:
                        target_status = "unchanged" if target_hash == content_hash else "conflict"
                else:
                    target_status = "conflict"
                    target_hash = "non-file"
            else:
                target_status = "create"
            entries.append({
                "messageId": msg["id"],
                "relativePath": rel_path,
                "target": target,
                "content": content,
                "contentHash": content_hash,
                "targetHash": target_hash,
                "status": target_status,
            })
        fingerprint_payload = {
            "selection": selection,
            "entries": [
                {
                    "messageId": entry["messageId"],
                    "relativePath": normalize_slashes(str(entry["relativePath"])),
                    "contentHash": entry["contentHash"],
                    "targetHash": entry["targetHash"],
                    "status": entry["status"],
                }
                for entry in entries
            ],
        }
        fingerprint = hashlib.sha256(
            json.dumps(fingerprint_payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        return {
            "selection": selection,
            "entries": entries,
            "fingerprint": fingerprint,
            "create": sum(1 for entry in entries if entry["status"] == "create"),
            "unchanged": sum(1 for entry in entries if entry["status"] == "unchanged"),
            "legacyExisting": sum(1 for entry in entries if entry["status"] == "legacy-existing"),
            "conflicts": sum(1 for entry in entries if entry["status"] == "conflict"),
        }

    def plan_export(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Preview a vault export without creating directories or changing state."""
        selection = self.normalize_export_selection(payload)
        with self._export_lock:
            with self.connect() as conn:
                conn.execute("BEGIN")
                snapshot = self.build_export_snapshot(selection, conn)
            now = time.time()
            self.export_plans = {
                token: plan
                for token, plan in self.export_plans.items()
                if float(plan["expiresAt"]) > now
            }
            can_apply = bool(snapshot["entries"]) and snapshot["conflicts"] == 0
            plan_token = secrets.token_urlsafe(24) if can_apply else ""
            if plan_token:
                self.export_plans[plan_token] = {
                    "selection": selection,
                    "fingerprint": snapshot["fingerprint"],
                    "expiresAt": now + EXPORT_PLAN_TTL_SECONDS,
                }
        return {
            "ok": True,
            "state": selection["state"],
            "accountScoped": bool(selection["accountId"]),
            "limit": selection["limit"],
            "total": len(snapshot["entries"]),
            "create": snapshot["create"],
            "unchanged": snapshot["unchanged"],
            "legacyExisting": snapshot["legacyExisting"],
            "conflicts": snapshot["conflicts"],
            "destination": normalize_slashes(self.email_vault_dir),
            "canApply": can_apply,
            "planToken": plan_token,
            "expiresIn": EXPORT_PLAN_TTL_SECONDS if plan_token else 0,
        }

    def apply_export(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Apply one current export plan with conflict-safe atomic publication."""
        plan_token = str(payload.get("planToken") or "").strip()
        if not plan_token:
            raise ValueError("Export plan token is required")
        if not self._export_lock.acquire(blocking=False):
            raise ValueError("Another export is already running")
        conn: sqlite3.Connection | None = None
        staged: list[Path] = []
        published: list[dict[str, Any]] = []
        created_dirs: set[Path] = set()
        try:
            plan = self.export_plans.pop(plan_token, None)
            if not plan or float(plan["expiresAt"]) <= time.time():
                raise ValueError("Export plan is missing or expired; preview again")
            with self._lock:
                conn = self.connect()
                conn.execute("BEGIN IMMEDIATE")
                snapshot = self.build_export_snapshot(plan["selection"], conn)
                if snapshot["fingerprint"] != plan["fingerprint"] or snapshot["conflicts"]:
                    raise ValueError("Export plan is stale or has target conflicts; preview again")
                for entry in snapshot["entries"]:
                    if entry["status"] != "create":
                        continue
                    target = entry["target"]
                    missing_dirs = []
                    cursor = target.parent
                    while cursor != self.email_vault_root and not cursor.exists():
                        missing_dirs.append(cursor)
                        cursor = cursor.parent
                    if not self.email_vault_root.exists():
                        missing_dirs.append(self.email_vault_root)
                    for directory in reversed(missing_dirs):
                        try:
                            directory.mkdir()
                        except FileExistsError:
                            if not directory.is_dir():
                                raise RuntimeError("Export directory changed during apply")
                        else:
                            created_dirs.add(directory)
                    resolved_target = (self.email_vault_root / entry["relativePath"]).resolve()
                    if resolved_target != target:
                        raise RuntimeError("Export target changed after preview")
                    stage = target.with_name(f".{target.name}.stage-{secrets.token_hex(12)}")
                    descriptor = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    with os.fdopen(descriptor, "wb") as stream:
                        stream.write(entry["content"])
                        stream.flush()
                        os.fsync(stream.fileno())
                    staged.append(stage)
                    entry["stage"] = stage
                for entry in snapshot["entries"]:
                    if entry["status"] != "create":
                        continue
                    try:
                        os.link(entry["stage"], entry["target"])
                    except FileExistsError as error:
                        raise RuntimeError("Export target changed after preview") from error
                    published.append(entry)
                    entry["stage"].unlink()
                    staged.remove(entry["stage"])
                for entry in snapshot["entries"]:
                    target = entry["target"]
                    expected_hash = entry["targetHash"] if entry["status"] == "legacy-existing" else entry["contentHash"]
                    if not target.is_file() or sha256_file(target) != expected_hash:
                        raise RuntimeError("Export target changed during apply")
                exported_at = iso_now()
                for entry in snapshot["entries"]:
                    exported_path = normalize_slashes(str(Path(self.email_vault_dir) / entry["relativePath"]))
                    conn.execute(
                        "UPDATE messages SET exported_path=?, exported_at=?, export_hash=? WHERE id=?",
                        (
                            exported_path,
                            exported_at,
                            entry["targetHash"] if entry["status"] == "legacy-existing" else entry["contentHash"],
                            entry["messageId"],
                        ),
                    )
                    conn.execute(
                        """
                        INSERT INTO exports(message_id, profile, exported_path, content_hash, exported_at, status)
                        VALUES(?, ?, ?, ?, ?, ?)
                        ON CONFLICT(message_id, profile) DO UPDATE SET
                          exported_path=excluded.exported_path,
                          content_hash=excluded.content_hash,
                          exported_at=excluded.exported_at,
                          status=excluded.status
                        """,
                        (
                            entry["messageId"],
                            snapshot["selection"]["state"],
                            exported_path,
                            entry["targetHash"] if entry["status"] == "legacy-existing" else entry["contentHash"],
                            exported_at,
                            entry["status"],
                        ),
                    )
                conn.commit()
            return {
                "ok": True,
                "exported": len(snapshot["entries"]),
                "created": snapshot["create"],
                "unchanged": snapshot["unchanged"],
                "legacyExisting": snapshot["legacyExisting"],
                "destination": normalize_slashes(self.email_vault_dir),
            }
        except Exception as error:
            if conn is not None:
                conn.rollback()
            rollback_conflicts = 0
            for entry in reversed(published):
                target = entry["target"]
                if not target.exists():
                    continue
                if target.is_file() and sha256_file(target) == entry["contentHash"]:
                    target.unlink()
                else:
                    rollback_conflicts += 1
            for stage in staged:
                try:
                    stage.unlink()
                except FileNotFoundError:
                    pass
            staged.clear()
            for directory in sorted(created_dirs, key=lambda path: len(path.parts), reverse=True):
                try:
                    directory.rmdir()
                except OSError:
                    pass
            if rollback_conflicts:
                raise RuntimeError(
                    f"Export failed and {rollback_conflicts} published file(s) changed before rollback"
                ) from error
            raise
        finally:
            if conn is not None:
                conn.close()
            for stage in staged:
                try:
                    stage.unlink()
                except FileNotFoundError:
                    pass
            self._export_lock.release()

    def export_markdown(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Compatibility wrapper that still uses the safe plan/apply pipeline."""
        plan = self.plan_export(payload)
        if not plan["canApply"]:
            if plan["conflicts"]:
                raise ValueError("Export targets conflict with existing files")
            return {
                "ok": True,
                "exported": 0,
                "created": 0,
                "unchanged": 0,
                "legacyExisting": 0,
                "destination": plan["destination"],
            }
        return self.apply_export({"planToken": plan["planToken"]})

    def export_path_for(self, msg: dict[str, Any]) -> Path:
        sent = parse_iso_date(msg.get("sent_at")) or dt.datetime.now(dt.timezone.utc)
        year = f"{sent.year:04d}"
        month = f"{sent.month:02d}"
        sender = sanitize_path_part(msg.get("sender_email") or msg.get("sender_name") or "unknown")
        subject = sanitize_path_part(msg.get("subject") or "no subject")[:80]
        return Path(str(msg.get("account_id") or "account")) / year / month / f"{sent.strftime('%Y-%m-%d')} - {sender} - {subject} - {msg['id'][:8]}.md"


def load_env(path: Path) -> None:
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def load_config(state_dir: Path) -> dict[str, Any]:
    config = json.loads(json.dumps(DEFAULT_CONFIG))
    for name in ("config.json", "config.local.json"):
        path = state_dir / name
        if path.exists():
            config = deep_merge(config, json.loads(path.read_text(encoding="utf-8")))
    return config


def parse_email_capabilities(value: str) -> frozenset[str]:
    """Parse and validate the explicit Email write-capability allowlist."""
    requested = frozenset(item.strip() for item in value.split(",") if item.strip())
    unknown = sorted(requested - EMAIL_WRITE_CAPABILITIES)
    if unknown:
        raise RuntimeError(f"Unknown Email write capabilities: {', '.join(unknown)}")
    return requested


def capability_health(capabilities: frozenset[str], unrestricted: bool) -> dict[str, bool]:
    """Return stable health keys without exposing configuration or credentials."""
    return {
        "unrestricted": unrestricted,
        "mailCount": "mail.count" in capabilities,
        "mailFetch": "mail.fetch" in capabilities,
        "classificationLabel": "classification.label" in capabilities,
        "classificationRun": "classification.run" in capabilities,
        "messageTag": "message.tag" in capabilities,
        "oauthManage": "oauth.manage" in capabilities,
        "rulesApply": "rules.apply" in capabilities,
        "rulesManage": "rules.manage" in capabilities,
        "vaultExport": "vault.export" in capabilities,
    }


def ensure_column(conn: sqlite3.Connection, table: str, column: str, ddl: str) -> None:
    columns = {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}
    if column not in columns:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}")


def fetch_homepage_theme_snapshot() -> dict[str, Any]:
    homepage_url = os.environ.get("NICA_HOMEPAGE_URL", "http://127.0.0.1:4274").rstrip("/")
    try:
        with urllib.request.urlopen(f"{homepage_url}/api/obsidian/theme", timeout=3) as response:
            payload = json.loads(response.read().decode("utf-8"))
            payload["available"] = True
            return payload
    except Exception:
        return {"ok": True, "available": False, "theme": {"vars": {}}}


def deep_merge(base: dict[str, Any], update: dict[str, Any]) -> dict[str, Any]:
    result = dict(base)
    for key, value in update.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def iso_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def stable_hash(values: Iterable[Any]) -> str:
    payload = "\u001f".join("" if value is None else str(value) for value in values)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def sha256_file(path: Path) -> str:
    """Return a file digest without loading an entire export into memory."""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


CLASSIFICATION_LABELS = {
    "spam": {"ham", "spam", "unsure"},
    "mail_type": {
        "phishing",
        "newsletter_marketing",
        "transactional",
        "personal_organisational",
        "other",
        "unsure",
    },
}


def validate_classification_label(task: str, label: str) -> None:
    """Reject unknown annotation taxonomies and labels."""
    if task not in CLASSIFICATION_LABELS:
        raise ValueError("Unsupported classification task")
    if label not in CLASSIFICATION_LABELS[task]:
        raise ValueError(f"Unsupported {task} label")


def is_holdout_message(message_id: str) -> bool:
    """Assign a stable 20 percent blind holdout without storing new authority."""
    digest = hashlib.sha256(message_id.encode("utf-8", errors="replace")).digest()
    return digest[0] % 5 == 0


def classification_queue_sort(item: dict[str, Any], queue_filter: str) -> tuple[Any, ...]:
    """Prioritize disagreements and uncertain decisions, then newest messages."""
    disagreement = bool(
        item.get("human_label")
        and item.get("predicted_label")
        and item["human_label"] != item["predicted_label"]
    )
    uncertain = item.get("predicted_label") == "unsure"
    score = item.get("score")
    distance = abs(float(score) - 0.5) if score is not None else 1.0
    if queue_filter == "disagreement":
        return (not disagreement, distance, str(item.get("sent_at") or item.get("fetched_at") or ""))
    return (not disagreement, not uncertain, distance, str(item.get("sent_at") or item.get("fetched_at") or ""))


def legacy_account_slug(value: Any) -> str:
    """Return the account-folder slug used by the established Email archive."""
    normalized = unicodedata.normalize("NFKD", str(value or "account"))
    ascii_text = normalized.encode("ascii", "ignore").decode("ascii").lower()
    return re.sub(r"[^a-z0-9]+", "-", ascii_text).strip("-") or "account"


def legacy_export_timestamp(value: Any) -> str:
    """Return the timestamp prefix used by established Email archive notes."""
    parsed = parse_iso_date(value)
    return parsed.strftime("%Y-%m-%d-%H%M%S") if parsed else ""


def read_legacy_export_uid(path: Path) -> str:
    """Read only the bounded frontmatter UID needed to identify a legacy note."""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as stream:
            first_line = stream.readline(4097)
            if len(first_line) > 4096 or first_line.strip() != "---":
                return ""
            for _line_number in range(64):
                line = stream.readline(4097)
                if not line or len(line) > 4096 or line.strip() == "---":
                    return ""
                if not line.startswith("uid:"):
                    continue
                raw_value = line.split(":", 1)[1].strip()
                try:
                    return str(json.loads(raw_value))
                except (json.JSONDecodeError, TypeError):
                    return raw_value.strip("'\"")
    except OSError:
        return ""
    return ""


def build_legacy_export_filename_index(export_root: Path) -> dict[tuple[str, str], list[Path]]:
    """Index established flat archive filenames without opening every note."""
    index: dict[tuple[str, str], list[Path]] = {}
    if not export_root.is_dir():
        return index
    for account_directory in export_root.iterdir():
        if account_directory.is_symlink() or not account_directory.is_dir():
            continue
        resolved_account = account_directory.resolve()
        if resolved_account.parent != export_root:
            continue
        for candidate in account_directory.glob("*.md"):
            if candidate.is_symlink() or not candidate.is_file():
                continue
            resolved_candidate = candidate.resolve()
            if resolved_candidate.parent != resolved_account:
                continue
            name_match = LEGACY_EXPORT_NAME_RE.fullmatch(candidate.name)
            if name_match:
                index.setdefault((account_directory.name, name_match.group(1)), []).append(resolved_candidate)
    return index


def legacy_candidate_fingerprint(export_root: Path, candidates: list[Path]) -> str:
    """Fingerprint ambiguous legacy candidates without exposing their paths."""
    digest = hashlib.sha256()
    for candidate in sorted(candidates, key=lambda path: normalize_slashes(str(path.relative_to(export_root)))):
        digest.update(normalize_slashes(str(candidate.relative_to(export_root))).encode("utf-8"))
        digest.update(b"\0")
        digest.update(sha256_file(candidate).encode("ascii"))
        digest.update(b"\0")
    return "legacy-conflict:" + digest.hexdigest()


def write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    """Publish sensitive JSON state atomically without exposing partial tokens."""
    path.parent.mkdir(parents=True, exist_ok=True)
    stage = path.with_name(f".{path.name}.stage-{secrets.token_hex(12)}")
    try:
        descriptor = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(payload, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(stage, path)
    finally:
        try:
            stage.unlink()
        except FileNotFoundError:
            pass


def first(query: dict[str, list[str]] | list[str] | None, key: str | None = None, default: str = "") -> str:
    if key is None:
        values = query if isinstance(query, list) else None
    else:
        values = query.get(key) if isinstance(query, dict) else None
    return str(values[0]) if values else default


def clamp_int(value: Any, minimum: int, maximum: int, default: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        number = default
    return max(minimum, min(maximum, number))


def decode_header_value(value: str | None) -> str:
    if not value:
        return ""
    parts: list[str] = []
    for chunk, charset in decode_header(value):
        if isinstance(chunk, bytes):
            parts.append(chunk.decode(charset or "utf-8", errors="replace"))
        else:
            parts.append(chunk)
    return "".join(parts).strip()


def parse_email(raw: bytes) -> dict[str, Any]:
    message = email.message_from_bytes(raw, policy=email.policy.default)
    subject = decode_header_value(message.get("subject"))
    sender_name, sender_email = parseaddr(decode_header_value(message.get("from")))
    body_text = ""
    body_html = ""
    attachment_count = 0
    for part in message.walk():
        content_disposition = (part.get_content_disposition() or "").lower()
        content_type = part.get_content_type().lower()
        if content_disposition == "attachment":
            attachment_count += 1
            continue
        try:
            content = part.get_content()
        except Exception:
            continue
        if content_type == "text/plain" and not body_text:
            body_text = str(content)
        elif content_type == "text/html" and not body_html:
            body_html = str(content)
    body_markdown = body_text.strip() or html_to_text(body_html)
    recipients = parse_address_list(message.get_all("to", []))
    cc = parse_address_list(message.get_all("cc", []))
    sent_at = parse_email_date(message.get("date"))
    msg_id = decode_header_value(message.get("message-id"))
    headers = {key.lower(): decode_header_value(value) for key, value in message.items() if key.lower() in {"from", "to", "cc", "date", "subject", "message-id", "in-reply-to", "references"}}
    return {
        "message_id": msg_id,
        "thread_key": decode_header_value(message.get("in-reply-to")) or msg_id,
        "subject": subject,
        "sender_name": sender_name,
        "sender_email": sender_email.lower(),
        "recipients": recipients,
        "cc": cc,
        "sent_at": sent_at,
        "headers": headers,
        "body_text": body_text.strip(),
        "body_markdown": body_markdown.strip(),
        "body_hash": sha256_text(body_markdown.strip()),
        "attachment_count": attachment_count,
        "size_bytes": len(raw),
    }


def parse_address_list(values: list[str]) -> list[dict[str, str]]:
    decoded = [decode_header_value(value) for value in values]
    return [{"name": name, "email": addr.lower()} for name, addr in getaddresses(decoded) if addr]


def parse_email_date(value: str | None) -> str | None:
    if not value:
        return None
    try:
        parsed = parsedate_to_datetime(value)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat()
    except (TypeError, ValueError, IndexError, OverflowError):
        return None


def html_to_text(value: str) -> str:
    parser = HtmlToText()
    parser.feed(value or "")
    return parser.text()


def build_search_criteria(payload: dict[str, Any]) -> list[str]:
    criteria = ["ALL"]
    since = str(payload.get("since") or "").strip()
    before = str(payload.get("before") or "").strip()
    if since:
        criteria.extend(["SINCE", to_imap_date(since)])
    if before:
        criteria.extend(["BEFORE", to_imap_date(before)])
    return criteria


def to_imap_date(value: str) -> str:
    parsed = dt.date.fromisoformat(value[:10])
    return parsed.strftime("%d-%b-%Y")


def first_bytes(msg_data: list[Any]) -> bytes | None:
    for item in msg_data:
        if isinstance(item, tuple) and len(item) >= 2 and isinstance(item[1], bytes):
            return item[1]
    return None


def oauth_token_expired(tokens: dict[str, Any]) -> bool:
    expires_at = tokens.get("expires_at")
    if expires_at:
        parsed = parse_iso_date(expires_at)
        if parsed:
            return parsed.timestamp() <= time.time() + 300
    expires_in = tokens.get("expires_in")
    if expires_in is not None:
        try:
            return float(expires_in) <= 300
        except (TypeError, ValueError):
            return True
    return True


def refresh_oauth_token(provider: str, tokens: dict[str, Any]) -> dict[str, Any]:
    refresh_token = str(tokens.get("refresh_token") or "").strip()
    if not refresh_token:
        raise ValueError("OAuth refresh token is missing")
    token_url, client_id, client_secret = oauth_provider_config(provider)
    fields = {
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": client_id,
    }
    if client_secret:
        fields["client_secret"] = client_secret
    body = urllib.parse.urlencode(fields).encode("utf-8")
    request = urllib.request.Request(token_url, data=body, method="POST")
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        try:
            detail = json.loads(body)
            message = detail.get("error_description") or detail.get("error") or body
        except json.JSONDecodeError:
            message = body or str(exc)
        raise ValueError(f"OAuth token refresh failed: HTTP {exc.code}: {message}") from exc
    except Exception as exc:
        raise ValueError(f"OAuth token refresh failed: {exc}") from exc
    if payload.get("error"):
        raise ValueError(f"OAuth token refresh failed: {payload.get('error_description') or payload.get('error')}")
    access_token = str(payload.get("access_token") or "").strip()
    if not access_token:
        raise ValueError("OAuth token refresh response did not include access_token")
    updated = oauth_payload_to_tokens(payload)
    updated["refresh_token"] = updated.get("refresh_token") or refresh_token
    return updated


def oauth_payload_to_tokens(payload: dict[str, Any]) -> dict[str, Any]:
    expires_in = int(payload.get("expires_in") or 3600)
    expires_at = dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=expires_in)
    return {
        "access_token": payload.get("access_token"),
        "refresh_token": payload.get("refresh_token"),
        "expires_at": expires_at.replace(microsecond=0).isoformat(),
        "expires_in": expires_in,
    }


def exchange_oauth_code(flow: dict[str, Any]) -> dict[str, Any]:
    code = str(flow.get("code") or "").strip()
    if not code:
        raise ValueError("OAuth authorization code is missing")
    fields = {
        "grant_type": "authorization_code",
        "client_id": flow["client_id"],
        "code": code,
        "redirect_uri": flow["redirect_uri"],
        "scope": "offline_access https://outlook.office.com/IMAP.AccessAsUser.All",
    }
    client_secret = os.environ.get("MS_CLIENT_SECRET", "").strip()
    if client_secret:
        fields["client_secret"] = client_secret
    body = urllib.parse.urlencode(fields).encode("utf-8")
    request = urllib.request.Request(flow["token_url"], data=body, method="POST")
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body_text = exc.read().decode("utf-8", errors="replace")
        try:
            detail = json.loads(body_text)
            message = detail.get("error_description") or detail.get("error") or body_text
        except json.JSONDecodeError:
            message = body_text or str(exc)
        raise ValueError(f"OAuth code exchange failed: HTTP {exc.code}: {message}") from exc
    if payload.get("error"):
        raise ValueError(payload.get("error_description") or payload.get("error"))
    return payload


def oauth_provider_config(provider: str) -> tuple[str, str, str | None]:
    if provider == "microsoft":
        client_id = os.environ.get("MS_CLIENT_ID", "").strip()
        client_secret = os.environ.get("MS_CLIENT_SECRET", "").strip() or None
        if not client_id:
            raise ValueError("MS_CLIENT_ID is required for Microsoft OAuth")
        return "https://login.microsoftonline.com/common/oauth2/v2.0/token", client_id, client_secret
    if provider == "google":
        client_id = os.environ.get("GOOGLE_CLIENT_ID", "").strip()
        client_secret = os.environ.get("GOOGLE_CLIENT_SECRET", "").strip()
        if not client_id or not client_secret:
            raise ValueError("GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET are required for Google OAuth")
        return "https://oauth2.googleapis.com/token", client_id, client_secret
    raise ValueError(f"Unsupported OAuth provider: {provider}")


def xoauth2_sasl(username: str, access_token: str) -> bytes:
    raw = f"user={username}\x01auth=Bearer {access_token}\x01\x01"
    return raw.encode("utf-8")


def rule_matches(rule: dict[str, Any], msg: dict[str, Any]) -> bool:
    if str(rule.get("scope") or "global") == "account":
        if str(rule.get("account_id") or "") != str(msg.get("account_id") or ""):
            return False
    field = rule["field"]
    if field == "sender_domain":
        value = str(msg.get("sender_email") or "").split("@")[-1]
    elif field == "body":
        value = str(msg.get("body_markdown") or "")
    else:
        value = str(msg.get(field) or "")
    pattern = str(rule.get("pattern") or "")
    operator = str(rule.get("operator") or "contains")
    if operator == "equals":
        return value.lower() == pattern.lower()
    if operator == "regex":
        try:
            return re.search(pattern, value, re.IGNORECASE) is not None
        except re.error:
            return False
    return pattern.lower() in value.lower()


def normalize_tag(value: Any) -> str:
    tag = re.sub(r"[^a-zA-Z0-9_.:/-]+", "-", str(value or "").strip()).strip("-").lower()
    return tag[:80]


def sanitize_path_part(value: Any) -> str:
    text = re.sub(r"[<>:/\\|?*\x00-\x1f]+", "-", str(value or "").strip())
    text = re.sub(r"\s+", " ", text).strip(" .-")
    return text[:120] or "untitled"


def normalize_slashes(value: str) -> str:
    return value.replace("\\", "/")


def parse_iso_date(value: Any) -> dt.datetime | None:
    if not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed
    except ValueError:
        return None


def render_markdown(msg: dict[str, Any]) -> str:
    tags = [normalize_tag(tag) for tag in msg.get("tags", []) if normalize_tag(tag)]
    frontmatter = [
        "---",
        yaml_line("email_id", msg.get("id")),
        yaml_line("account", msg.get("account_id")),
        yaml_line("mailbox", msg.get("mailbox")),
        yaml_line("uid", msg.get("uid")),
        yaml_line("message_id", msg.get("message_id")),
        yaml_line("subject", msg.get("subject")),
        yaml_line("from", msg.get("sender_email")),
        yaml_line("from_name", msg.get("sender_name")),
        yaml_line("sent", msg.get("sent_at")),
        yaml_line("include_state", msg.get("include_state")),
        "tags: [" + ", ".join(json.dumps(tag, ensure_ascii=False) for tag in tags) + "]",
        "---",
        "",
    ]
    recipients = json.loads(msg.get("recipients_json") or "[]")
    cc = json.loads(msg.get("cc_json") or "[]")
    meta = [
        f"# {msg.get('subject') or '(no subject)'}",
        "",
        f"- From: {msg.get('sender_name') or ''} <{msg.get('sender_email') or ''}>",
        f"- Sent: {msg.get('sent_at') or ''}",
        f"- Account: {msg.get('account_id') or ''}",
        f"- Mailbox: {msg.get('mailbox') or ''}",
        f"- To: {', '.join(addr.get('email', '') for addr in recipients)}",
    ]
    if cc:
        meta.append(f"- Cc: {', '.join(addr.get('email', '') for addr in cc)}")
    meta.extend(["", "## Body", "", msg.get("body_markdown") or ""])
    return "\n".join(frontmatter + meta).rstrip() + "\n"


def yaml_line(key: str, value: Any) -> str:
    return f"{key}: {json.dumps('' if value is None else value, ensure_ascii=False)}"


class Handler(BaseHTTPRequestHandler):
    """HTTP bridge for the local email UI."""

    tool: EmailTool
    write_enabled = False
    write_capabilities: frozenset[str] = frozenset()
    unrestricted_write = False
    state_dir: Path

    def log_message(self, format: str, *args: Any) -> None:
        sys.stderr.write("Email server: " + format % args + "\n")

    def do_GET(self) -> None:
        try:
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/api/ping":
                mode = "read-write" if self.unrestricted_write else "limited-write" if self.write_enabled else "read-only"
                self.send_json({
                    "ok": True,
                    "component": "email",
                    "mode": mode,
                    "writesEnabled": self.write_enabled,
                    "writeCapabilities": capability_health(self.write_capabilities, self.unrestricted_write),
                    "oauthCallback": {
                        "host": "127.0.0.1",
                        "port": self.tool.oauth_callback_port,
                    },
                    "authority": {
                        "vault": str(self.tool.vault_root),
                        "localState": str(self.state_dir),
                        "vaultIsAuthoritative": True,
                    },
                })
                return
            if parsed.path == "/api/state":
                self.send_json({"ok": True, "stats": self.tool.stats(), "accounts": self.tool.accounts(), "rules": self.tool.list_rules()})
                return
            if parsed.path == "/api/progress":
                self.send_json({"ok": True, "progress": self.tool.get_progress()})
                return
            if parsed.path == "/api/dashboard":
                query = urllib.parse.parse_qs(parsed.query)
                self.send_json(self.tool.dashboard(clamp_int(first(query, "limit", "30"), 1, 200, 30)))
                return
            if parsed.path == "/api/accounts":
                self.send_json({"ok": True, "accounts": self.tool.accounts()})
                return
            if parsed.path == "/api/obsidian/theme":
                self.send_json(fetch_homepage_theme_snapshot())
                return
            if parsed.path == "/api/rules":
                self.send_json({"ok": True, "rules": self.tool.list_rules()})
                return
            if parsed.path == "/api/tags":
                self.send_json({"ok": True, "tags": self.tool.list_tags()})
                return
            if parsed.path == "/api/classification/models":
                self.send_json({"ok": True, "models": self.tool.classification_models()})
                return
            if parsed.path == "/api/classification/runs":
                query = urllib.parse.parse_qs(parsed.query)
                self.send_json({
                    "ok": True,
                    "runs": self.tool.list_classification_runs(clamp_int(first(query, "limit", "20"), 1, 100, 20)),
                })
                return
            if parsed.path == "/api/classification/summary":
                query = urllib.parse.parse_qs(parsed.query)
                self.send_json(self.tool.classification_summary(first(query, "runId", "")))
                return
            if parsed.path == "/api/classification/queue":
                query = urllib.parse.parse_qs(parsed.query)
                self.send_json(self.tool.list_classification_queue(query))
                return
            if parsed.path == "/api/classification/export":
                query = urllib.parse.parse_qs(parsed.query)
                include_content = first(query, "includeContent", "false").lower() == "true"
                self.send_json(self.tool.export_classification_labels(include_content))
                return
            if parsed.path == "/api/messages":
                query = urllib.parse.parse_qs(parsed.query)
                self.send_json({"ok": True, **self.tool.list_messages(query)})
                return
            if parsed.path.startswith("/api/messages/"):
                message_id = parsed.path.rsplit("/", 1)[-1]
                message = self.tool.get_message(message_id)
                if not message:
                    self.send_error(404, "Message not found")
                    return
                self.send_json({"ok": True, "message": message})
                return
            self.serve_static(parsed.path)
        except Exception as exc:
            self.send_json({"ok": False, "error": str(exc)}, status=500)

    def do_POST(self) -> None:
        try:
            parsed = urllib.parse.urlparse(self.path)
            capability = POST_ROUTE_CAPABILITIES.get(parsed.path)
            if not capability:
                self.send_error(404, "Not found")
                return
            if capability not in self.write_capabilities:
                self.send_json({
                    "ok": False,
                    "code": "NICA_CAPABILITY_DISABLED",
                    "capability": capability,
                    "error": f"Action disabled: Email capability {capability} is not enabled",
                }, status=403)
                return
            if parsed.path == "/api/export" and not self.unrestricted_write:
                self.send_json({
                    "ok": False,
                    "code": "NICA_EXPORT_PLAN_REQUIRED",
                    "capability": capability,
                    "error": "Bounded Email export requires preview and separate apply",
                }, status=409)
                return
            payload = self.read_json()
            if parsed.path == "/api/fetch":
                self.send_json(self.tool.fetch(payload))
                return
            if parsed.path == "/api/fetch-new":
                self.send_json(self.tool.fetch_new(payload))
                return
            if parsed.path == "/api/count":
                self.send_json(self.tool.count_mailboxes(payload))
                return
            if parsed.path == "/api/count-all":
                self.send_json(self.tool.count_all(payload))
                return
            if parsed.path == "/api/fetch-new-all":
                self.send_json(self.tool.fetch_new_all(payload))
                return
            if parsed.path == "/api/classification/run":
                self.send_json(self.tool.start_classification_run(payload), status=202)
                return
            if parsed.path == "/api/classification/labels":
                self.send_json(self.tool.set_classification_label(payload))
                return
            if parsed.path == "/api/classification/labels/import":
                self.send_json(self.tool.import_classification_labels(payload))
                return
            if parsed.path == "/api/export":
                self.send_json(self.tool.export_markdown(payload))
                return
            if parsed.path == "/api/export/plan":
                self.send_json(self.tool.plan_export(payload))
                return
            if parsed.path == "/api/export/apply":
                self.send_json(self.tool.apply_export(payload))
                return
            if parsed.path == "/api/rules":
                self.send_json(self.tool.upsert_rule(payload))
                return
            if parsed.path == "/api/rules/delete":
                self.send_json(self.tool.delete_rule(str(payload.get("id") or "")))
                return
            if parsed.path == "/api/rules/apply":
                self.send_json(self.tool.apply_rules())
                return
            if parsed.path == "/api/messages/tag":
                self.send_json(self.tool.tag_message(payload))
                return
            if parsed.path == "/api/oauth/start":
                self.send_json(self.tool.start_oauth_login(payload))
                return
            if parsed.path == "/api/oauth/poll":
                self.send_json(self.tool.poll_oauth_login(payload))
                return
        except Exception as exc:
            self.send_json({"ok": False, "error": str(exc)}, status=400)

    def read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("content-length") or "0")
        if not length:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def send_json(self, payload: dict[str, Any], status: int = 200) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def serve_static(self, request_path: str) -> None:
        path = "/email.html" if request_path in {"/", ""} else request_path
        rel = Path(urllib.parse.unquote(path.lstrip("/")))
        if rel.is_absolute() or ".." in rel.parts:
            self.send_error(403, "Forbidden")
            return
        target = (ROOT / rel).resolve()
        if target != ROOT and ROOT not in target.parents:
            self.send_error(403, "Forbidden")
            return
        if not target.exists() or not target.is_file():
            self.send_error(404, "Not found")
            return
        data = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", MIME_TYPES.get(target.suffix.lower(), "application/octet-stream"))
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class OAuthCallbackHandler(BaseHTTPRequestHandler):
    """Receive OAuth authorization-code callbacks on the configured loopback port."""

    tool: EmailTool

    def log_message(self, format: str, *args: Any) -> None:
        sys.stderr.write("Email OAuth callback: " + format % args + "\n")

    def log_request(self, code: int | str = "-", size: int | str = "-") -> None:
        """Log callback status without authorization codes or state values."""
        path = urllib.parse.urlparse(self.path).path
        self.log_message('"%s %s %s" %s %s', self.command, path, self.request_version, str(code), str(size))

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/callback":
            self.send_response(404)
            self.end_headers()
            return
        params = urllib.parse.parse_qs(parsed.query)
        state = first(params, "state")
        code = first(params, "code")
        error = first(params, "error_description") or first(params, "error")
        flow = None
        for candidate in self.tool.oauth_flows.values():
            if candidate.get("state") == state:
                flow = candidate
                break
        if not flow:
            self.respond("OAuth state mismatch. You can close this tab.", status=400)
            return
        if error:
            flow["error"] = error
            flow["pending"] = False
            self.respond("OAuth login failed. You can close this tab.", status=400)
            return
        if not code:
            flow["error"] = "OAuth callback did not include an authorization code"
            flow["pending"] = False
            self.respond("OAuth login failed: missing code. You can close this tab.", status=400)
            return
        flow["code"] = code
        flow["pending"] = False
        self.respond("OAuth login received. You can close this tab and return to Email DB.")

    def respond(self, text: str, status: int = 200) -> None:
        data = f"<!doctype html><meta charset='utf-8'><title>Email OAuth</title><p>{html.escape(text)}</p>".encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def require_directory_env(name: str, create: bool = False) -> Path:
    """Return a validated absolute directory configured through the environment."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        raise RuntimeError(f"{name} is required")
    candidate = Path(raw)
    if not candidate.is_absolute():
        raise RuntimeError(f"{name} must be an absolute path")
    if create:
        candidate.mkdir(parents=True, exist_ok=True)
    if not candidate.is_dir():
        raise RuntimeError(f"{name} must identify an existing directory")
    return candidate.resolve()


def require_state_root(vault_root: Path) -> Path:
    """Create local state only after proving its path is outside the vault."""
    raw = os.environ.get("NICA_STATE_ROOT", "").strip()
    if not raw:
        raise RuntimeError("NICA_STATE_ROOT is required")
    candidate = Path(raw)
    if not candidate.is_absolute():
        raise RuntimeError("NICA_STATE_ROOT must be an absolute path")
    unresolved = candidate.resolve()
    if unresolved == vault_root or unresolved in vault_root.parents or vault_root in unresolved.parents:
        raise RuntimeError("NICA_STATE_ROOT and NICA_VAULT_ROOT must be separate directory trees")
    candidate.mkdir(parents=True, exist_ok=True)
    state_root = candidate.resolve()
    if state_root == vault_root or state_root in vault_root.parents or vault_root in state_root.parents:
        raise RuntimeError("NICA_STATE_ROOT and NICA_VAULT_ROOT must be separate directory trees")
    return state_root


def serve(args: argparse.Namespace) -> None:
    vault_root = require_directory_env("NICA_VAULT_ROOT")
    state_root = require_state_root(vault_root)
    unrestricted_write = os.environ.get("NICA_WRITE_ENABLED", "").strip().lower() == "true"
    configured_capabilities = parse_email_capabilities(os.environ.get("NICA_EMAIL_CAPABILITIES", ""))
    write_capabilities = EMAIL_WRITE_CAPABILITIES if unrestricted_write else configured_capabilities
    state_dir = state_root / "email"
    if state_dir.is_symlink():
        raise RuntimeError("Email state directory must not be a symbolic link")
    state_dir.mkdir(parents=True, exist_ok=True)
    state_dir = state_dir.resolve()
    if state_root not in state_dir.parents:
        raise RuntimeError("Email state directory escaped NICA_STATE_ROOT")
    for env_name in (".env", ".env.local"):
        env_path = state_dir / env_name
        if env_path.is_symlink():
            raise RuntimeError("Email environment files must not be symbolic links")
        load_env(env_path)
    config = load_config(state_dir)
    config["runtimeRoot"] = str(state_dir)
    config["vaultRoot"] = str(vault_root)
    config["database"] = "email.db"
    config["host"] = os.environ.get("EMAIL_HOST", config.get("host") or "127.0.0.1")
    config["port"] = int(os.environ.get("EMAIL_PORT", args.port or config.get("port") or 4176))
    config["oauthCallbackPort"] = int(os.environ.get("EMAIL_OAUTH_CALLBACK_PORT", config.get("oauthCallbackPort") or 8080))
    tool = EmailTool(config)
    host = str(tool.config.get("host") or "127.0.0.1")
    port = int(tool.config.get("port") or 4176)
    Handler.tool = tool
    Handler.state_dir = state_dir
    Handler.write_capabilities = write_capabilities
    Handler.unrestricted_write = unrestricted_write
    Handler.write_enabled = bool(write_capabilities)
    server = ThreadingHTTPServer((host, port), Handler)
    pid_file = state_dir / "email.preview.pid"
    pid_file.write_text(str(os.getpid()), encoding="ascii")
    print(f"Email preview server: http://{host}:{port}/email.html", flush=True)
    mode = "read-write" if unrestricted_write else "limited-write" if write_capabilities else "read-only"
    print(f"Runtime mode: {mode}; vault authority: {vault_root}", flush=True)
    try:
        server.serve_forever()
    finally:
        try:
            pid_file.unlink()
        except FileNotFoundError:
            pass


def smoke() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        config = dict(DEFAULT_CONFIG)
        config["runtimeRoot"] = temp_dir
        config["database"] = str(Path(temp_dir) / "email.db")
        config["vaultRoot"] = temp_dir
        config["emailVaultDir"] = "8. Emails"
        tool = EmailTool(config)
        previous_homepage_url = os.environ.get("NICA_HOMEPAGE_URL")
        os.environ["NICA_HOMEPAGE_URL"] = "http://127.0.0.1:1"
        try:
            unavailable_theme = fetch_homepage_theme_snapshot()
        finally:
            if previous_homepage_url is None:
                os.environ.pop("NICA_HOMEPAGE_URL", None)
            else:
                os.environ["NICA_HOMEPAGE_URL"] = previous_homepage_url
        assert unavailable_theme == {"ok": True, "available": False, "theme": {"vars": {}}}
        tool.config["accounts"] = [
            {"id": "working", "enabled": True},
            {"id": "failing", "enabled": True},
        ]

        def synthetic_count(payload: dict[str, Any]) -> dict[str, Any]:
            if payload["accountId"] == "failing":
                raise RuntimeError("synthetic account failure")
            return {"ok": True, "accountId": "working", "total": 5, "matched": 4, "localStored": 3, "newAvailable": 1}

        def synthetic_fetch(payload: dict[str, Any]) -> dict[str, Any]:
            if payload["accountId"] == "failing":
                raise RuntimeError("synthetic account failure")
            return {"ok": True, "accountId": "working", "total": 5, "matched": 2, "fetched": 1}

        tool.count_mailboxes = synthetic_count  # type: ignore[method-assign]
        counted = tool.count_all({})
        assert counted["ok"] is True
        assert counted["succeeded"] == 1 and counted["failed"] == 1 and counted["partial"] is True
        assert counted["newAvailable"] == 1
        assert tool.get_progress()["message"] == "Counted 1/2 accounts; 1 failed"
        tool.fetch_new = synthetic_fetch  # type: ignore[method-assign]
        fetched = tool.fetch_new_all({})
        assert fetched["ok"] is True
        assert fetched["succeeded"] == 1 and fetched["failed"] == 1 and fetched["partial"] is True
        assert fetched["fetched"] == 1
        assert tool.get_progress()["message"] == "Fetched 1 new messages from 1/2 accounts; 1 failed"
        tool.config["accounts"] = []
        sample = {
            "account_id": "demo",
            "mailbox": "INBOX",
            "uid": "1",
            "message_id": "<demo@example.test>",
            "thread_key": "<demo@example.test>",
            "subject": "Demo message",
            "sender_name": "Demo Sender",
            "sender_email": "demo@example.test",
            "recipients": [{"name": "Example User", "email": "user@example.test"}],
            "cc": [],
            "sent_at": "2026-01-02T03:04:05+00:00",
            "headers": {},
            "body_text": "Hello from the email DB.",
            "body_markdown": "Hello from the email DB.",
            "body_hash": sha256_text("Hello from the email DB."),
            "attachment_count": 0,
            "size_bytes": 32,
        }
        assert tool.store_message(sample) == 1
        assert tool.store_message(sample) == 0
        assert tool.stats()["messages"]["total"] == 1
        listed = tool.list_messages({"q": ["demo"], "limit": ["10"]})
        assert listed["total"] == 1
        tool.tag_message({"messageId": listed["messages"][0]["id"], "tag": "manual-test"})
        tagged = tool.list_messages({"tag": ["manual-test"], "limit": ["10"]})
        assert tagged["total"] == 1
        tool.upsert_rule({"name": "demo", "scope": "account", "accountId": "demo", "field": "sender_domain", "operator": "equals", "pattern": "example.test", "action": "include", "tag": "demo"})
        applied = tool.apply_rules()
        assert applied["matches"] == 1
        tool.upsert_rule({"name": "wrong account", "scope": "account", "accountId": "other", "field": "sender_domain", "operator": "equals", "pattern": "example.test", "action": "exclude"})
        applied = tool.apply_rules()
        assert applied["matches"] == 1
        assert applied["changed"] == 0
        assert tool.list_tags()
        exported = tool.export_markdown({"state": "included"})
        assert exported["exported"] == 1
        try:
            tool.resolve_state_path("../escaped-token.json")
            raise AssertionError("Email state containment accepted an escaping path")
        except ValueError:
            pass
        escaped_export = dict(config)
        escaped_export["emailVaultDir"] = "../escaped-export"
        try:
            EmailTool(escaped_export)
            raise AssertionError("Email export containment accepted an escaping path")
        except ValueError:
            pass
    print("Email smoke check passed")


def main() -> None:
    parser = argparse.ArgumentParser(description="Database-first email bridge")
    sub = parser.add_subparsers(dest="command", required=True)
    serve_parser = sub.add_parser("serve")
    serve_parser.add_argument("--port", type=int)
    sub.add_parser("smoke")
    args = parser.parse_args()
    if args.command == "serve":
        serve(args)
    elif args.command == "smoke":
        smoke()


if __name__ == "__main__":
    main()
