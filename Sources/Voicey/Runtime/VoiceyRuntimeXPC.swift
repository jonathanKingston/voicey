import Foundation

/// XPC service hooks for P4 entitlement-split workers. Subprocess mode remains the default prototype path.
enum VoiceyRuntimeXPC {
  static var isEnabled: Bool {
    VoiceyRuntimeConfiguration.useXPCServices
  }

  static func inferServiceName() -> String {
    "work.voicey.Voicey.infer-worker"
  }

  static func captureServiceName() -> String {
    "work.voicey.Voicey.capture-worker"
  }

  static func fetchServiceName() -> String {
    "work.voicey.Voicey.fetch-worker"
  }
}
