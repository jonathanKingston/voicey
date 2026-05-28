import Foundation

enum VoiceyFetchWorkerLaunchMode: String, Sendable {
  case directProcess = "direct-process"
  case seatbeltProfile = "seatbelt-profile"
}

struct VoiceyFetchWorkerLaunchConfiguration: Sendable {
  private static let bundledProfileRelativePath = "Sandbox/VoiceyFetch.sb"

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
    if let sandboxProfilePath = resolvedSandboxProfilePath() {
      let homeDirectory = NSHomeDirectory()
      return VoiceyFetchWorkerLaunchConfiguration(
        executablePath: "/usr/bin/sandbox-exec",
        arguments: ["-D", "HOME=\(homeDirectory)", "-f", sandboxProfilePath, workerPath],
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

  private static func resolvedSandboxProfilePath() -> String? {
    if let override = VoiceyRuntimeConfiguration.fetchSandboxProfileOverride {
      return override
    }
    guard VoiceyRuntimeConfiguration.usesFetchSandboxByDefault else { return nil }
    return bundledSandboxProfilePath()
  }

  private static func bundledSandboxProfilePath() -> String? {
    if let resourcePath = Bundle.main.resourceURL?.appendingPathComponent(bundledProfileRelativePath).path,
      FileManager.default.isReadableFile(atPath: resourcePath)
    {
      return resourcePath
    }

    let repoPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Resources")
      .appendingPathComponent(bundledProfileRelativePath)
      .path
    if FileManager.default.isReadableFile(atPath: repoPath) {
      return repoPath
    }

    return nil
  }
}
