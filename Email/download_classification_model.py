#!/usr/bin/env python3
"""Download an approved GLiClass model into the configured local cache.

Installation deliberately does not instantiate the model. Loading hundreds of
megabytes of weights here duplicates the runtime's memory requirement and can
make an otherwise resumable download fail on a memory-constrained workstation.
The Email classification run performs the real load check when the operator
chooses a model.
"""
from __future__ import annotations

import argparse
import importlib.metadata
import json
from pathlib import Path
import socket
from typing import Any


APPROVED_MODELS = {
    "gliclass-multilang-mini": "knowledgator/gliclass-multilang-mini",
    "gliclass-multilang-edge": "knowledgator/gliclass-multilang-edge",
}


def prefer_ipv4() -> None:
    """Keep this downloader off an unusable IPv6 route without changing Windows."""
    original_getaddrinfo = socket.getaddrinfo

    def ipv4_getaddrinfo(*args: Any, **kwargs: Any) -> list[Any]:
        results = original_getaddrinfo(*args, **kwargs)
        ipv4_results = [result for result in results if result[0] == socket.AF_INET]
        return ipv4_results or results

    socket.getaddrinfo = ipv4_getaddrinfo  # type: ignore[assignment]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=sorted(APPROVED_MODELS), default="gliclass-multilang-mini")
    parser.add_argument("--prefer-ipv4", action="store_true")
    args = parser.parse_args()
    if args.prefer_ipv4:
        prefer_ipv4()
    from huggingface_hub import snapshot_download

    repository = APPROVED_MODELS[args.model]
    snapshot = Path(snapshot_download(repo_id=repository))
    commit = snapshot.name
    try:
        import torch

        cuda_available = bool(torch.cuda.is_available())
        cuda_device = torch.cuda.get_device_name(0) if cuda_available else ""
    except Exception:
        cuda_available = False
        cuda_device = ""
    print(json.dumps({
        "ok": True,
        "model": args.model,
        "repository": repository,
        "revision": commit,
        "snapshot": str(snapshot),
        "gliclassVersion": importlib.metadata.version("gliclass"),
        "torchVersion": importlib.metadata.version("torch"),
        "preferredIpv4": args.prefer_ipv4,
        "cudaAvailable": cuda_available,
        "cudaDevice": cuda_device,
    }))


if __name__ == "__main__":
    main()
