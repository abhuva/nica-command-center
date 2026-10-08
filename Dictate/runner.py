"""NICA-owned launcher adapter for the vendored Dictate desktop application."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parent
UPSTREAM_ROOT = ROOT / "upstream"
REGISTRY_PATH = ROOT / "model-registry.json"
UPSTREAM_REVISION = "b3aa938e6c6c120f4fd54c6d0ad4c791af79261a"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run local NICA Dictate")
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--hotkey", choices=("ctrl", "ctrl_l", "ctrl_r", "f12"), default="ctrl")
    parser.add_argument("--min-hold", type=float, default=2.0)
    parser.add_argument("--ready-file", required=True)
    return parser.parse_args()


def read_model(model_id: str) -> dict:
    registry = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    if registry.get("schemaVersion") != 1:
        raise RuntimeError("Unsupported Dictate model registry")
    for model in registry.get("models", []):
        if model.get("id") == model_id:
            return model
    raise RuntimeError(f"Unknown Dictate model: {model_id}")


def write_json_atomic(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    args = parse_args()
    state_root = Path(args.state_root).resolve()
    model_dir = Path(args.model_dir).resolve()
    ready_file = Path(args.ready_file).resolve()
    model = read_model(args.model)

    expected_files = [entry["name"] for entry in model["files"]]
    missing = [name for name in expected_files if not (model_dir / name).is_file()]
    if missing:
        raise RuntimeError(f"Dictate model is incomplete: {', '.join(missing)}")

    sys.path.insert(0, str(UPSTREAM_ROOT))
    import core  # type: ignore[import-not-found]
    import local_stt  # type: ignore[import-not-found]

    core.CONFIG_DIR = state_root / "config"
    core.CONFIG_PATH = core.CONFIG_DIR / "config.json"
    core.LOG_PATH = state_root / "logs" / "dictate.log"
    core.FAILED_DIR = state_root / "failed-audio-disabled"
    local_stt.MODEL_DIR = model_dir
    local_stt.MODEL_FILES = expected_files

    config = {
        **core.DEFAULT_CONFIG,
        "provider": "parakeet_local",
        "model": args.model,
        "key": args.hotkey,
        "mode": "ptt",
        "threshold": max(0.0, args.min_hold),
        "local_stt_num_threads": 4,
    }
    core.load_config = lambda: dict(config)
    core.save_config = lambda _config: None

    def do_not_retain_failed_audio(_audio: np.ndarray) -> None:
        core.log.warning("recognition returned empty text; failed audio retention is disabled")

    core.keep_failed_audio = do_not_retain_failed_audio
    core.setup_logging()
    core.log.info("starting NICA Dictate model=%s hotkey=%s", args.model, args.hotkey)

    recognizer = local_stt.get_recognizer(num_threads=4)
    if not recognizer.wait_ready(timeout=120):
        raise RuntimeError("Dictate model did not become ready within 120 seconds")
    if not recognizer.is_ready():
        recognizer.transcribe(np.zeros((1600, 1), dtype=np.int16))

    import gui  # type: ignore[import-not-found]
    from PyQt6.QtWidgets import QApplication

    if not gui.acquire_single_instance_lock():
        return 0
    app = QApplication(sys.argv[:1])
    app.setApplicationName("NICA Dictate")
    app.setQuitOnLastWindowClosed(not gui.QSystemTrayIcon.isSystemTrayAvailable())
    window = gui.MainWindow()
    window.setWindowTitle("NICA Dictate")
    window.settings_btn.setVisible(False)
    window.show()

    write_json_atomic(
        ready_file,
        {
            "version": 1,
            "component": "dictate",
            "pid": os.getpid(),
            "model": args.model,
            "hotkey": args.hotkey,
            "minHoldSeconds": args.min_hold,
            "upstreamRevision": UPSTREAM_REVISION,
            "readyAt": datetime.now(timezone.utc).isoformat(),
        },
    )
    try:
        return app.exec()
    finally:
        ready_file.unlink(missing_ok=True)
        core.log.info("NICA Dictate stopped")


if __name__ == "__main__":
    raise SystemExit(main())
