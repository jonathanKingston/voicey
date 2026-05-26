# Cross-platform runtime (deferred)

Linux and Windows hosts, non-MLX Qwen backends, and unified Rust inference on macOS are **explicitly deferred** until macOS gates G0–G4 pass (see plan).

## Linux

- Host: CLI or GTK/tray using the same `voicey-protocol` schema
- Infer: ONNX/CUDA or Python Qwen worker — not MLX weights from HugFace Apple builds
- CI: extend beyond `VoiceyCore` tests once macOS prototype is stable

## Windows

- Host: WinUI/tray
- Sandbox: AppContainer + Job objects
- Infer: same non-MLX Qwen strategy as Linux

## Optional unified eval (Phase 5)

Compare exported Qwen (ORT/CoreML) against MLX infer worker on WER **and** warm RTF before changing the macOS default backend.
