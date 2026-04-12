import Foundation

public enum CoreVoiceCommandAction: Codable, Equatable, Sendable {
  case newLine
  case newParagraph
  case scratchThat
  case custom(String)
}

public struct CoreVoiceCommand: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var phrase: String
  public var action: CoreVoiceCommandAction
  public var enabled: Bool

  public init(
    id: UUID = UUID(),
    phrase: String,
    action: CoreVoiceCommandAction,
    enabled: Bool
  ) {
    self.id = id
    self.phrase = phrase
    self.action = action
    self.enabled = enabled
  }

  public static let defaults: [CoreVoiceCommand] = [
    CoreVoiceCommand(phrase: "new line", action: .newLine, enabled: true),
    CoreVoiceCommand(phrase: "new paragraph", action: .newParagraph, enabled: true),
    CoreVoiceCommand(phrase: "scratch that", action: .scratchThat, enabled: true),
  ]
}

public typealias VoiceCommandAction = CoreVoiceCommandAction
public typealias VoiceCommand = CoreVoiceCommand
