import Foundation

enum VoiceyFetchWorkerLaunchMode: String, Sendable {
  case directProcess = "direct-process"
  case seatbeltProfile = "seatbelt-profile"
}

struct VoiceyFetchWorkerLaunchConfiguration: Sendable {
  let executablePath: String
  let arguments: [String]
  let environment: [String: String]
  let mode: VoiceyFetchWorkerLaunchMode
  let sandboxProfilePath: String?

  static func current() throws -> VoiceyFetchWorkerLaunchConfiguration {
    guard let workerPath = VoiceyRuntimeConfiguration.fetchWorkerPath else {
      throw VoiceyFetchWorkerError.missingBinary
    }

    let environment = ProcessInfo.processInfo.environment
    if let sandboxProfilePath = VoiceyRuntimeConfiguration.fetchSandboxProfileOverride {
      return VoiceyFetchWorkerLaunchConfiguration(
        executablePath: "/usr/bin/sandbox-exec",
        arguments: ["-f", sandboxProfilePath, workerPath],
        environment: environment,
        mode: .seatbeltProfile,
        sandboxProfilePath: sandboxProfilePath
      )
    }

    return VoiceyFetchWorkerLaunchConfiguration(
      executablePath: workerPath,
      arguments: [],
      environment: environment,
      mode: .directProcess,
      sandboxProfilePath: nil
    )
  }
}
