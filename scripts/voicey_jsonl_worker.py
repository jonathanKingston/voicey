#!/usr/bin/env python3
"""Minimal JSONL stdin/stdout client for Voicey Rust workers (local harnesses only)."""

from __future__ import annotations

import json
import subprocess
import uuid
from collections.abc import Mapping
from typing import Any


class JsonlWorker:
    def __init__(
        self,
        executable: str,
        *,
        env: Mapping[str, str] | None = None,
    ) -> None:
        self._proc = subprocess.Popen(
            [executable],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        if self._proc.stdin is None or self._proc.stdout is None:
            raise RuntimeError(f"failed to start worker: {executable}")

    def request(self, payload: dict[str, Any], *, request_id: str | None = None) -> dict[str, Any]:
        req_id = request_id or str(uuid.uuid4())
        if "id" not in payload:
            payload = {**payload, "id": req_id}
        line = json.dumps(payload, separators=(",", ":")) + "\n"
        self._proc.stdin.write(line)
        self._proc.stdin.flush()
        response_line = self._proc.stdout.readline()
        if not response_line:
            stderr = self._proc.stderr.read() if self._proc.stderr else ""
            raise RuntimeError(f"worker closed stdout ({executable_hint(stderr)})")
        return json.loads(response_line)

    def close(self) -> None:
        if self._proc.poll() is not None:
            return
        try:
            self.request({"type": "shutdown", "id": "shutdown"})
        except (RuntimeError, json.JSONDecodeError, BrokenPipeError):
            pass
        self._proc.terminate()
        try:
            self._proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._proc.kill()


def executable_hint(stderr: str) -> str:
    tail = stderr.strip()[-400:]
    return tail if tail else "no stderr"


def new_request_id(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4().hex[:8]}"
