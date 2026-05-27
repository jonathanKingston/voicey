import Foundation

// MARK: - Voice Command Types

public enum VoiceCommandAction: Codable, Equatable {
  case newLine
  case newParagraph
  case scratchThat
  case custom(String)
}

public struct VoiceCommand: Identifiable, Codable, Equatable {
  public let id: UUID
  public var phrase: String
  public var action: VoiceCommandAction
  public var enabled: Bool

  public init(id: UUID, phrase: String, action: VoiceCommandAction, enabled: Bool) {
    self.id = id
    self.phrase = phrase
    self.action = action
    self.enabled = enabled
  }

  public static let defaults: [VoiceCommand] = [
    VoiceCommand(id: UUID(), phrase: "new line", action: .newLine, enabled: true),
    VoiceCommand(id: UUID(), phrase: "new paragraph", action: .newParagraph, enabled: true),
    VoiceCommand(id: UUID(), phrase: "scratch that", action: .scratchThat, enabled: true),
    VoiceCommand(id: UUID(), phrase: "etcetera", action: .custom("etc."), enabled: true),
    VoiceCommand(id: UUID(), phrase: "et cetera", action: .custom("etc."), enabled: true),
    VoiceCommand(id: UUID(), phrase: "for example", action: .custom("e.g."), enabled: true),
    VoiceCommand(id: UUID(), phrase: "versus", action: .custom("vs."), enabled: true),
    VoiceCommand(id: UUID(), phrase: "mister", action: .custom("Mr."), enabled: true),
    VoiceCommand(id: UUID(), phrase: "missus", action: .custom("Mrs."), enabled: true),
    VoiceCommand(id: UUID(), phrase: "doctor", action: .custom("Dr."), enabled: true),
    VoiceCommand(id: UUID(), phrase: "okay", action: .custom("OK"), enabled: true)
  ]
}
