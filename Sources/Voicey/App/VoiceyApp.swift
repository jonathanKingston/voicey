import AppKit
import Darwin
import SwiftUI

struct VoiceyApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    Settings {
      SettingsView()
        .environmentObject(appDelegate.appState)
    }
  }
}

@main
enum VoiceyMain {
  static func main() async {
    if InferWorkerCommand.canHandle(CommandLine.arguments) {
      let exitCode = await InferWorkerCommand.run()
      exit(Int32(exitCode))
    }

    if BenchmarkTranscribeCommand.canHandle(CommandLine.arguments) {
      let exitCode = await BenchmarkTranscribeCommand.run(arguments: CommandLine.arguments)
      exit(Int32(exitCode))
    }

    if BenchmarkTranscribeBatchCommand.canHandle(CommandLine.arguments) {
      let exitCode = await BenchmarkTranscribeBatchCommand.run(arguments: CommandLine.arguments)
      exit(Int32(exitCode))
    }

    if BenchmarkModelDownloadCommand.canHandle(CommandLine.arguments) {
      let exitCode = await BenchmarkModelDownloadCommand.run(arguments: CommandLine.arguments)
      exit(Int32(exitCode))
    }

    if BenchmarkCaptureCompareCommand.canHandle(CommandLine.arguments) {
      let exitCode = await BenchmarkCaptureCompareCommand.run(arguments: CommandLine.arguments)
      exit(Int32(exitCode))
    }

    VoiceyApp.main()
  }
}
