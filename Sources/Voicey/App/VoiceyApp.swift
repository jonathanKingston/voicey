import AppKit
import SwiftUI

@main
struct VoiceyApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    Settings {
      SettingsView()
        .environmentObject(appDelegate.appState)
    }
  }
}
