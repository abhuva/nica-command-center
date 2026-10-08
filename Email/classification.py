#!/usr/bin/env python3
"""Local email-classification adapters with optional model dependencies."""
from __future__ import annotations

import importlib.util
import math
import re
from typing import Any, Iterable


SPAM_LABELS = ("ham", "spam")
MODEL_SPECS: dict[str, dict[str, Any]] = {
    "keyword-baseline-v1": {
        "name": "Transparent keyword baseline",
        "revision": "1",
        "kind": "baseline",
        "languages": ["de", "en"],
        "description": "Deterministic smoke-test baseline; not intended for automatic filtering.",
        "requires": [],
    },
    "gliclass-multilang-mini": {
        "name": "GLiClass Multilang Mini",
        "revision": "knowledgator/gliclass-multilang-mini",
        "kind": "zero-shot",
        "languages": ["de", "en"],
        "description": "Recommended multilingual zero-shot classifier (about 288M parameters).",
        "requires": ["gliclass", "transformers", "torch"],
    },
    "gliclass-multilang-edge": {
        "name": "GLiClass Multilang Edge",
        "revision": "knowledgator/gliclass-multilang-edge",
        "kind": "zero-shot",
        "languages": ["de", "en"],
        "description": "Smaller multilingual zero-shot comparison (about 140M parameters).",
        "requires": ["gliclass", "transformers", "torch"],
    },
}


def available_models() -> list[dict[str, Any]]:
    """Return model metadata and dependency/device diagnostics."""
    result = []
    for model_id, spec in MODEL_SPECS.items():
        missing = [name for name in spec["requires"] if importlib.util.find_spec(name) is None]
        item = {"id": model_id, **spec, "available": not missing, "missing": missing}
        if not missing and "torch" in spec["requires"]:
            try:
                import torch

                item["cudaAvailable"] = bool(torch.cuda.is_available())
                item["cudaDevice"] = torch.cuda.get_device_name(0) if torch.cuda.is_available() else ""
            except Exception:
                item["cudaAvailable"] = False
                item["cudaDevice"] = ""
        result.append(item)
    return result


def message_text(message: dict[str, Any], maximum_chars: int = 16000) -> str:
    """Create the stable model input without attachments or hidden local state."""
    sender = str(message.get("sender_email") or message.get("sender_name") or "").strip()
    subject = str(message.get("subject") or "").strip()
    body = str(message.get("body_text") or message.get("body_markdown") or "").strip()
    text = f"Sender: {sender}\nSubject: {subject}\n\n{body}"
    return text[:maximum_chars]


def classify_messages(
    model_id: str,
    messages: list[dict[str, Any]],
    *,
    device: str = "auto",
    threshold: float = 0.5,
    uncertainty_margin: float = 0.08,
    batch_size: int = 8,
) -> Iterable[dict[str, Any]]:
    """Yield one normalized spam prediction per message."""
    if model_id not in MODEL_SPECS:
        raise ValueError(f"Unsupported classification model: {model_id}")
    if model_id == "keyword-baseline-v1":
        for message in messages:
            yield keyword_prediction(message)
        return
    yield from gliclass_predictions(
        model_id,
        messages,
        device=device,
        threshold=threshold,
        uncertainty_margin=uncertainty_margin,
        batch_size=batch_size,
    )


SPAM_TERMS = {
    "claim your prize": 2.0,
    "you have won": 2.0,
    "sie haben gewonnen": 2.0,
    "kostenlos gewonnen": 2.0,
    "limited time offer": 1.1,
    "click here now": 1.2,
    "klicken sie hier": 1.0,
    "crypto investment": 1.5,
    "bitcoin investment": 1.5,
    "casino bonus": 1.7,
    "viagra": 2.0,
    "verify your password": 1.7,
    "passwort bestätigen": 1.7,
    "wallet address": 1.3,
}
HAM_TERMS = {
    "meeting": 0.35,
    "termin": 0.35,
    "minutes": 0.3,
    "protokoll": 0.3,
    "rechnung": 0.25,
    "invoice": 0.25,
    "registration": 0.25,
    "anmeldung": 0.25,
}


def keyword_prediction(message: dict[str, Any]) -> dict[str, Any]:
    """Return a conservative deterministic baseline for workflow verification."""
    text = message_text(message).casefold()
    spam_weight = sum(weight for term, weight in SPAM_TERMS.items() if term in text)
    ham_weight = sum(weight for term, weight in HAM_TERMS.items() if term in text)
    url_count = len(re.findall(r"https?://|www\.", text))
    if url_count >= 5:
        spam_weight += min(1.0, url_count * 0.1)
    spam_score = 1.0 / (1.0 + math.exp(-(spam_weight - ham_weight - 1.8)))
    ham_score = 1.0 - spam_score
    if spam_score >= 0.7:
        label = "spam"
    elif ham_score >= 0.7:
        label = "ham"
    else:
        label = "unsure"
    return {
        "message_id": message["id"],
        "label": label,
        "score": spam_score,
        "scores": {"spam": spam_score, "ham": ham_score},
        "model_revision": "1",
    }


def gliclass_predictions(
    model_id: str,
    messages: list[dict[str, Any]],
    *,
    device: str,
    threshold: float,
    uncertainty_margin: float,
    batch_size: int,
) -> Iterable[dict[str, Any]]:
    """Run GLiClass locally and normalize its independent label scores."""
    try:
        import torch
        from gliclass import GLiClassModel, ZeroShotClassificationPipeline
        from transformers import AutoTokenizer
    except ImportError as exc:
        raise RuntimeError(
            "GLiClass is not installed. Run scripts/install-email-classification.ps1 first."
        ) from exc

    spec = MODEL_SPECS[model_id]
    resolved_device = device
    if resolved_device == "auto":
        resolved_device = "cuda:0" if torch.cuda.is_available() else "cpu"
    if resolved_device.startswith("cuda") and not torch.cuda.is_available():
        raise RuntimeError("CUDA was requested but PyTorch cannot access a CUDA device")

    revision = spec["revision"]
    model = GLiClassModel.from_pretrained(revision)
    tokenizer = AutoTokenizer.from_pretrained(revision)
    pipeline = ZeroShotClassificationPipeline(
        model,
        tokenizer,
        classification_type="multi-label",
        device=resolved_device,
    )
    resolved_revision = str(getattr(model.config, "_commit_hash", "") or revision)
    ham_description = "legitimate wanted email, personal or organisational correspondence, or an expected notification"
    spam_description = "unsolicited bulk advertising, scam, phishing, malicious, or deceptive email"
    labels = [ham_description, spam_description]
    try:
        for start in range(0, len(messages), max(1, batch_size)):
            batch = messages[start:start + max(1, batch_size)]
            texts = [message_text(message) for message in batch]
            raw_batch = pipeline(texts, labels, threshold=0.0)
            for message, raw in zip(batch, raw_batch, strict=True):
                score_map = {
                    str(item.get("label")): float(item.get("score"))
                    for item in raw
                    if isinstance(item, dict) and item.get("label") is not None and item.get("score") is not None
                }
                if ham_description not in score_map or spam_description not in score_map:
                    raise RuntimeError("GLiClass returned an unexpected classification shape")
                ham_score = score_map[ham_description]
                spam_score = score_map[spam_description]
                difference = abs(spam_score - ham_score)
                if max(spam_score, ham_score) < threshold or difference < uncertainty_margin:
                    label = "unsure"
                else:
                    label = "spam" if spam_score > ham_score else "ham"
                yield {
                    "message_id": message["id"],
                    "label": label,
                    "score": spam_score,
                    "scores": {"spam": spam_score, "ham": ham_score},
                    "model_revision": resolved_revision,
                }
    finally:
        del pipeline, model, tokenizer
        if resolved_device.startswith("cuda"):
            torch.cuda.empty_cache()
