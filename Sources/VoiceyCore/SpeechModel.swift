import Foundation

public enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
  case qwen3Large = "qwen3-asr-1.7b-bf16"
  case qwen3Small = "qwen3-asr-0.6b-6bit"
  case graniteSpeech = "granite-4.0-1b-speech"
  case largeTurbo = "large-v3_turbo"
  case large = "large-v3"
  case distilLarge = "distil-large-v3"
  case small = "small"
  case base = "base"
  case tiny = "tiny"
  case smallEn = "small.en"
  case baseEn = "base.en"
  case tinyEn = "tiny.en"

  public var id: String { rawValue }

  public var backendKind: SpeechBackendKind {
    switch self {
    case .graniteSpeech:
      return .granitePython
    case .qwen3Small, .qwen3Large:
      return .qwenMLX
    default:
      return .whisperKit
    }
  }

  public var isGraniteModel: Bool {
    backendKind == .granitePython
  }

  public var isWhisperModel: Bool {
    backendKind == .whisperKit
  }

  public var isQwenModel: Bool {
    backendKind == .qwenMLX
  }

  public var displayName: String {
    switch self {
    case .graniteSpeech: return "Granite 4.0 1B Speech"
    case .qwen3Small: return "Qwen3 ASR 0.6B (MLX)"
    case .qwen3Large: return "Qwen3 ASR 1.7B (MLX)"
    case .largeTurbo: return "Large v3 Turbo"
    case .large: return "Large v3"
    case .distilLarge: return "Distil Large v3"
    case .small: return "Small (Multilingual)"
    case .base: return "Base (Multilingual)"
    case .tiny: return "Tiny (Multilingual)"
    case .smallEn: return "Small (English)"
    case .baseEn: return "Base (English)"
    case .tinyEn: return "Tiny (English)"
    }
  }

  public var description: String {
    switch self {
    case .graniteSpeech: return "#1 on OpenASR leaderboard, multilingual, ~1GB (requires Python + mlx-audio)"
    case .qwen3Small:
      return "Native Swift MLX, multilingual auto-detect, fast startup (~400MB)"
    case .qwen3Large:
      return "Native Swift MLX, multilingual auto-detect, highest Qwen quality (~1.7GB)"
    case .largeTurbo: return "Fast & accurate, 8x faster than Large (~1.5GB)"
    case .large: return "Maximum accuracy, slower (~3GB)"
    case .distilLarge: return "Distilled model, fast & accurate (~800MB)"
    case .small: return "Balanced speed/accuracy, multilingual (~250MB)"
    case .base: return "Fast, basic accuracy, multilingual (~80MB)"
    case .tiny: return "Fastest, lowest accuracy, multilingual (~40MB)"
    case .smallEn: return "Balanced speed/accuracy, English only (~250MB)"
    case .baseEn: return "Fast, basic accuracy, English only (~80MB)"
    case .tinyEn: return "Fastest, lowest accuracy, English only (~40MB)"
    }
  }

  public var isRecommended: Bool {
    self == .qwen3Large
  }

  public var isEnglishOnly: Bool {
    switch self {
    case .smallEn, .baseEn, .tinyEn: return true
    default: return false
    }
  }

  public var isFastModel: Bool {
    switch self {
    case .qwen3Small:
      return true
    case .base, .baseEn, .tiny, .tinyEn, .small, .smallEn:
      return true
    default:
      return false
    }
  }

  public var diskSize: Int64 {
    switch self {
    case .graniteSpeech: return 1_000_000_000
    case .qwen3Small: return 450_000_000
    case .qwen3Large: return 1_800_000_000
    case .largeTurbo: return 1_500_000_000
    case .large: return 3_000_000_000
    case .distilLarge: return 800_000_000
    case .small, .smallEn: return 250_000_000
    case .base, .baseEn: return 80_000_000
    case .tiny, .tinyEn: return 40_000_000
    }
  }

  public var memoryUsage: Int64 {
    switch self {
    case .graniteSpeech: return 2_000_000_000
    case .qwen3Small: return 1_300_000_000
    case .qwen3Large: return 3_500_000_000
    case .largeTurbo: return 3_000_000_000
    case .large: return 6_000_000_000
    case .distilLarge: return 2_000_000_000
    case .small, .smallEn: return 600_000_000
    case .base, .baseEn: return 200_000_000
    case .tiny, .tinyEn: return 100_000_000
    }
  }

  public var huggingFaceModelId: String? {
    switch self {
    case .graniteSpeech: return "ibm-granite/granite-4.0-1b-speech"
    case .qwen3Small: return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    case .qwen3Large: return "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
    default: return nil
    }
  }

  public var whisperKitModelId: String? {
    switch self {
    case .graniteSpeech, .qwen3Small, .qwen3Large: return nil
    case .largeTurbo: return "openai_whisper-large-v3_turbo"
    case .large: return "openai_whisper-large-v3"
    case .distilLarge: return "distil-whisper_distil-large-v3"
    case .small: return "openai_whisper-small"
    case .base: return "openai_whisper-base"
    case .tiny: return "openai_whisper-tiny"
    case .smallEn: return "openai_whisper-small.en"
    case .baseEn: return "openai_whisper-base.en"
    case .tinyEn: return "openai_whisper-tiny.en"
    }
  }
}

public typealias WhisperModel = SpeechModel
public typealias ModelUpgradeCallback = @Sendable (SpeechModel) -> Void
