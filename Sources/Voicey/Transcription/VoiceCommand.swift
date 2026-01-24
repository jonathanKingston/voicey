import Foundation

// MARK: - Voice Command Types

enum VoiceCommandAction: Codable, Equatable {
  case newLine
  case newParagraph
  case scratchThat
  case custom(String)
}

struct VoiceCommand: Identifiable, Codable {
  let id: UUID
  var phrase: String
  var action: VoiceCommandAction
  var enabled: Bool

  static let defaults: [VoiceCommand] = [
    VoiceCommand(id: UUID(), phrase: "new line", action: .newLine, enabled: true),
    VoiceCommand(id: UUID(), phrase: "new paragraph", action: .newParagraph, enabled: true),
    VoiceCommand(id: UUID(), phrase: "scratch that", action: .scratchThat, enabled: true)
  ]
}
