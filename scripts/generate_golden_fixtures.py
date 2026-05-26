#!/usr/bin/env python3
"""Generate short 16 kHz mono WAV fixtures for benchmark parity."""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "Benchmarks" / "Golden"


def write_sine_wav(path: Path, duration_seconds: float, frequency_hz: float = 440.0) -> None:
    sample_rate = 16_000
    sample_count = int(duration_seconds * sample_rate)
    with wave.open(str(path), "w") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        frames = bytearray()
        for index in range(sample_count):
            sample = int(0.2 * 32767 * math.sin(2 * math.pi * frequency_hz * index / sample_rate))
            frames.extend(struct.pack("<h", sample))
        handle.writeframes(frames)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    write_sine_wav(OUT_DIR / "tone_0p5s_440hz.wav", 0.5, 440.0)
    write_sine_wav(OUT_DIR / "tone_1p0s_220hz.wav", 1.0, 220.0)
    write_sine_wav(OUT_DIR / "tone_2p0s_330hz.wav", 2.0, 330.0)
    print(f"Wrote fixtures under {OUT_DIR}")


if __name__ == "__main__":
    main()
