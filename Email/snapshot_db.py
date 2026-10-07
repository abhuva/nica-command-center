#!/usr/bin/env python3
"""Create a consistent local Email SQLite snapshot without copying WAL files."""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import uuid
from contextlib import closing
from pathlib import Path


def snapshot_database(source: Path, destination: Path) -> dict[str, int | str | bool]:
    """Back up a live SQLite database and atomically publish the verified copy."""
    source = source.resolve(strict=True)
    destination = destination.resolve(strict=False)
    if not source.is_file():
        raise RuntimeError("Email snapshot source must be a file")
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = destination.with_name(f".{destination.name}.snapshot-{uuid.uuid4().hex}.tmp")

    try:
        source_uri = f"{source.as_uri()}?mode=ro"
        with closing(sqlite3.connect(source_uri, uri=True, timeout=30)) as source_db:
            source_db.execute("PRAGMA query_only=ON")
            with closing(sqlite3.connect(stage, timeout=30)) as snapshot_db:
                source_db.backup(snapshot_db)
                result = snapshot_db.execute("PRAGMA quick_check").fetchall()
                if result != [("ok",)]:
                    raise RuntimeError("Email snapshot failed SQLite quick_check")
        for suffix in ("-wal", "-shm"):
            try:
                Path(f"{destination}{suffix}").unlink()
            except FileNotFoundError:
                pass
        os.replace(stage, destination)
    finally:
        try:
            stage.unlink()
        except FileNotFoundError:
            pass

    return {
        "ok": True,
        "sourceBytes": source.stat().st_size,
        "snapshotBytes": destination.stat().st_size,
        "quickCheck": "ok",
    }


def main() -> None:
    """Parse CLI arguments and emit non-sensitive snapshot metadata."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(snapshot_database(args.source, args.destination), separators=(",", ":")))


if __name__ == "__main__":
    main()
