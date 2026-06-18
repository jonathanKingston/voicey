"""Local Voicey artifact paths (never commit audio or transcripts to git)."""

from __future__ import annotations

import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def default_session_archive_root() -> Path:
    return Path.home() / "Library/Application Support/Voicey/SessionArchive"


def default_artifacts_root() -> Path:
    override = os.environ.get("VOICEY_ARTIFACTS_ROOT", "").strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library/Application Support/Voicey/Artifacts"


def readaloud_artifact_dir(
    *,
    corpus_version: int,
    tag: str | None = None,
    artifacts_root: Path | None = None,
) -> Path:
    root = artifacts_root or default_artifacts_root()
    base = f"readaloud-corpus-v{corpus_version}"
    if tag:
        safe = "".join(c if c.isalnum() or c in "-_" else "-" for c in tag.strip())
        return root / f"{base}__{safe}"
    return root / base
