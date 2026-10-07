"""Synthetic verification for consistent Email SQLite snapshots."""
from __future__ import annotations

import sqlite3
import sys
import tempfile
from contextlib import closing
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "Email"))

from snapshot_db import snapshot_database  # noqa: E402


def message_count(database: Path) -> int:
    """Return the number of synthetic messages in a database."""
    with closing(sqlite3.connect(database)) as connection:
        result = connection.execute("SELECT COUNT(*) FROM messages").fetchone()
    return int(result[0])


def main() -> None:
    """Create and refresh a snapshot while the WAL-backed source stays open."""
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp_dir:
        root = Path(temp_dir)
        source = root / "source.db"
        snapshot = root / "snapshot.db"
        with sqlite3.connect(source) as source_db:
            source_db.execute("PRAGMA journal_mode=WAL")
            source_db.execute("PRAGMA wal_autocheckpoint=0")
            source_db.execute("CREATE TABLE messages(id TEXT PRIMARY KEY, subject TEXT NOT NULL)")
            source_db.execute("INSERT INTO messages VALUES('one', 'Synthetic one')")
            source_db.commit()

            first = snapshot_database(source, snapshot)
            assert first["quickCheck"] == "ok"
            assert message_count(snapshot) == 1

            source_db.execute("INSERT INTO messages VALUES('two', 'Synthetic two')")
            source_db.commit()
            Path(f"{snapshot}-wal").write_bytes(b"stale synthetic WAL")
            Path(f"{snapshot}-shm").write_bytes(b"stale synthetic SHM")
            second = snapshot_database(source, snapshot)
            assert second["quickCheck"] == "ok"
            assert message_count(snapshot) == 2
            assert not Path(f"{snapshot}-wal").exists()
            assert not Path(f"{snapshot}-shm").exists()

        assert not list(root.glob(".snapshot.db.snapshot-*.tmp"))
    print("Email SQLite snapshot smoke check OK")


if __name__ == "__main__":
    main()
