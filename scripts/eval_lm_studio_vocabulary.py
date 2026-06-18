#!/usr/bin/env python3
"""Evaluate LM Studio vocabulary post-process on text golden cases.

Calls a local OpenAI-compatible /v1/chat/completions endpoint (default LM Studio).
Skips gracefully when the server is unavailable unless --require-server is set.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

DEFAULT_BASE_URL = "http://127.0.0.1:1234/v1"
DEFAULT_GLOSSARY = (
    "IncrementalTranscriptionCoordinator.swift, Voicey, Qwen, voicey-text, "
    "UtteranceTranscriptionFinish.swift, metformin, HbA1c"
)


@dataclass(frozen=True)
class GoldenCase:
    id: str
    transcript: str
    vocabulary: str
    must_contain: tuple[str, ...]
    must_not_contain: tuple[str, ...] = ()


GOLDEN_CASES: tuple[GoldenCase, ...] = (
    GoldenCase(
        id="swift-filename",
        transcript="open incremental transcription coordinator dot swift in the editor",
        vocabulary=DEFAULT_GLOSSARY,
        must_contain=("IncrementalTranscriptionCoordinator.swift",),
    ),
    GoldenCase(
        id="medical-token",
        transcript="the patient takes met form in twice daily",
        vocabulary="metformin, HbA1c",
        must_contain=("metformin",),
        must_not_contain=("met form in",),
    ),
    GoldenCase(
        id="readaloud-clip5-filename-sentence",
        transcript="This file is IncrementalTranscriptionCoordinator dot Swift.",
        vocabulary=DEFAULT_GLOSSARY,
        must_contain=("This file is", "IncrementalTranscriptionCoordinator"),
        must_not_contain=(),
    ),
    GoldenCase(
        id="no-rewrite",
        transcript="please ship the patch today",
        vocabulary=DEFAULT_GLOSSARY,
        must_contain=("please ship the patch today",),
        must_not_contain=("IncrementalTranscriptionCoordinator",),
    ),
)


def lm_studio_request_headers() -> dict[str, str]:
    headers = {"Content-Type": "application/json"}
    token = (os.environ.get("LM_API_TOKEN") or os.environ.get("LM_STUDIO_API_KEY") or "").strip()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def server_available(base_url: str, timeout_seconds: float) -> bool:
    models_url = base_url.rstrip("/") + "/models"
    request = urllib.request.Request(models_url, method="GET", headers=lm_studio_request_headers())
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            return 200 <= response.status < 300
    except (urllib.error.URLError, TimeoutError, ValueError):
        return False


def refine_transcript(
    *,
    base_url: str,
    model: str | None,
    transcript: str,
    vocabulary: str,
    timeout_seconds: float,
) -> str:
    endpoint = base_url.rstrip("/") + "/chat/completions"
    payload = {
        "model": model or "local-model",
        "messages": [
            {
                "role": "system",
                "content": (
                    "You correct dictation transcripts using a provided vocabulary list. "
                    "Fix spelling of proper nouns, product names, and technical terms when they "
                    "clearly match a vocabulary entry. Do not add words, remove content, change "
                    "meaning, or rewrite style. Return only the corrected transcript with no commentary."
                ),
            },
            {
                "role": "user",
                "content": f"Vocabulary: {vocabulary}\n\nTranscript:\n{transcript}",
            },
        ],
        "temperature": 0,
        "stream": False,
    }
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=data,
        method="POST",
        headers=lm_studio_request_headers(),
    )
    with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
        body = json.loads(response.read().decode("utf-8"))
    choices = body.get("choices") or []
    if not choices:
        raise RuntimeError("empty LM Studio completion")
    content = choices[0].get("message", {}).get("content")
    if not isinstance(content, str) or not content.strip():
        raise RuntimeError("LM Studio returned blank content")
    return content.strip()


def score_case(case: GoldenCase, refined: str) -> dict:
    lowered = refined.lower()
    missing = [token for token in case.must_contain if token.lower() not in lowered]
    forbidden = [token for token in case.must_not_contain if token.lower() in lowered]
    return {
        "id": case.id,
        "input": case.transcript,
        "output": refined,
        "passed": not missing and not forbidden,
        "missing": missing,
        "forbidden": forbidden,
    }


def write_summary(path: Path, rows: list[dict], *, skipped: bool) -> None:
    if skipped:
        path.write_text("# LM Studio vocabulary eval\n\nSkipped — server unavailable.\n", encoding="utf-8")
        return
    lines = [
        "# LM Studio vocabulary eval",
        "",
        "| case | passed | missing | forbidden |",
        "| --- | --- | --- | --- |",
    ]
    for row in rows:
        lines.append(
            "| "
            + " | ".join(
                [
                    row["id"],
                    "yes" if row["passed"] else "no",
                    ", ".join(row["missing"]) or "—",
                    ", ".join(row["forbidden"]) or "—",
                ]
            )
            + " |"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--model", default="")
    parser.add_argument("--timeout-seconds", type=float, default=30.0)
    parser.add_argument(
        "--require-server",
        action="store_true",
        help="Exit non-zero when LM Studio is unavailable.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=REPO_ROOT / "benchmark-results" / "lm-studio-vocabulary.json",
    )
    args = parser.parse_args(argv)

    if not server_available(args.base_url, args.timeout_seconds):
        message = f"LM Studio not reachable at {args.base_url}"
        if args.require_server:
            print(f"error: {message}", file=sys.stderr)
            return 1
        print(f"skip: {message}", file=sys.stderr)
        payload = {
            "created_at": datetime.now(timezone.utc).isoformat(),
            "skipped": True,
            "reason": message,
        }
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        write_summary(args.out.with_suffix(".md"), [], skipped=True)
        return 0

    model = args.model.strip() or None
    rows: list[dict] = []
    latency_seconds: list[float] = []
    for case in GOLDEN_CASES:
        started = time.perf_counter()
        refined = refine_transcript(
            base_url=args.base_url,
            model=model,
            transcript=case.transcript,
            vocabulary=case.vocabulary,
            timeout_seconds=args.timeout_seconds,
        )
        elapsed = time.perf_counter() - started
        latency_seconds.append(elapsed)
        row = score_case(case, refined)
        row["latency_seconds"] = round(elapsed, 3)
        row["input_chars"] = len(case.transcript)
        row["output_chars"] = len(refined)
        rows.append(row)
        print(
            f"{case.id}: {'pass' if row['passed'] else 'fail'} "
            f"latency={elapsed:.2f}s -> {refined!r}",
            file=sys.stderr,
        )

    passed = sum(1 for row in rows if row["passed"])
    total_latency = sum(latency_seconds)
    payload = {
        "created_at": datetime.now(timezone.utc).isoformat(),
        "base_url": args.base_url,
        "model": model,
        "passed": passed,
        "total": len(rows),
        "latency_seconds_total": round(total_latency, 3),
        "latency_seconds_mean": round(total_latency / len(latency_seconds), 3)
        if latency_seconds
        else None,
        "cases": rows,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_summary(args.out.with_suffix(".md"), rows, skipped=False)
    print(f"Wrote {args.out} ({passed}/{len(rows)} passed)", file=sys.stderr)
    return 0 if passed == len(rows) else 2


if __name__ == "__main__":
    raise SystemExit(main())
