"""Load committed read-aloud steering corpus manifest (no audio)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CORPUS_PATH = REPO_ROOT / "Benchmarks" / "readaloud_steering_corpus.json"


@dataclass(frozen=True)
class ReadAloudClip:
    id_prefix: str
    script: str
    reference: str
    category: str
    expect_coordinator_swift: bool
    expect_glossary_token: str | None


def load_corpus_manifest(path: Path = DEFAULT_CORPUS_PATH) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if "clips" not in data:
        raise ValueError(f"invalid corpus manifest: {path}")
    return data


def blended_glossary(manifest: dict | None = None) -> str:
    manifest = manifest or load_corpus_manifest()
    glossary = (manifest.get("glossary_manual") or "").strip()
    if not glossary:
        raise ValueError("corpus manifest missing glossary_manual")
    return glossary


def clips_from_manifest(
    manifest: dict | None = None,
    *,
    require_id: bool = True,
) -> tuple[ReadAloudClip, ...]:
    manifest = manifest or load_corpus_manifest()
    out: list[ReadAloudClip] = []
    for row in manifest["clips"]:
        prefix = row.get("id_prefix")
        if require_id and not prefix:
            continue
        if not prefix:
            continue
        out.append(
            ReadAloudClip(
                id_prefix=str(prefix),
                script=str(row["script"]),
                reference=str(row["reference"]),
                category=str(row.get("category") or "unknown"),
                expect_coordinator_swift=bool(row.get("expect_coordinator_swift")),
                expect_glossary_token=row.get("expect_glossary_token"),
            )
        )
    return tuple(out)


def pending_clips(manifest: dict | None = None) -> list[dict]:
    manifest = manifest or load_corpus_manifest()
    return [row for row in manifest["clips"] if not row.get("id_prefix")]
