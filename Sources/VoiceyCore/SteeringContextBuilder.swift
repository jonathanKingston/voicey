import Foundation

/// Builds Qwen decoder steering context from manual glossary and screen snapshots.
/// Mirrors `voicey-text` `build_steering_context` for Linux CI golden fixture parity.
public enum SteeringContextBuilder {
  public struct Input: Sendable {
    public let manualGlossaryEnabled: Bool
    public let manualGlossary: String
    public let screenContextEnabled: Bool
    public let snapshot: ScreenContextSnapshot?
    public let maxTerms: Int

    public init(
      manualGlossaryEnabled: Bool,
      manualGlossary: String,
      screenContextEnabled: Bool,
      snapshot: ScreenContextSnapshot?,
      maxTerms: Int = ScreenTermSelector.defaultMaxTerms
    ) {
      self.manualGlossaryEnabled = manualGlossaryEnabled
      self.manualGlossary = manualGlossary
      self.screenContextEnabled = screenContextEnabled
      self.snapshot = snapshot
      self.maxTerms = maxTerms
    }
  }

  public struct Output: Sendable, Equatable {
    public let terms: [String]
    public let decoderContext: String?

    public init(terms: [String], decoderContext: String?) {
      self.terms = terms
      self.decoderContext = decoderContext
    }
  }

  public static func build(_ input: Input) -> Output {
    guard input.manualGlossaryEnabled || input.screenContextEnabled else {
      return Output(terms: [], decoderContext: nil)
    }

    var manualTerms: [String] = []
    if input.manualGlossaryEnabled {
      manualTerms = TranscriptionGlossary.parseTerms(input.manualGlossary)
    }

    var screenTerms: [String] = []
    if input.screenContextEnabled {
      screenTerms = ScreenTermSelector.select(
        snapshot: input.snapshot,
        manualGlossary: input.manualGlossary,
        manualGlossaryEnabled: false,
        maxTerms: input.maxTerms
      )
    }

    let terms = manualTerms + screenTerms
    let decoderContext = TranscriptionGlossary.decodingContext(terms: terms)
    return Output(terms: terms, decoderContext: decoderContext)
  }
}
