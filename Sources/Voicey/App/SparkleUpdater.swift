import Foundation

#if VOICEY_DIRECT_DISTRIBUTION
import Sparkle

/// Manages automatic updates via Sparkle for direct distribution builds
final class SparkleUpdater: NSObject, ObservableObject {
  static let shared = SparkleUpdater()

  /// The Sparkle updater controller
  private let updaterController: SPUStandardUpdaterController

  /// Published property to track if an update is available
  @Published var canCheckForUpdates = false

  private override init() {
    // Initialize Sparkle with standard UI
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    super.init()

    // Observe when we can check for updates
    updaterController.updater.publisher(for: \.canCheckForUpdates)
      .assign(to: &$canCheckForUpdates)
  }

  /// Check for updates manually (user-initiated)
  func checkForUpdates() {
    updaterController.checkForUpdates(nil)
  }

  /// The underlying updater for advanced configuration
  var updater: SPUUpdater {
    updaterController.updater
  }

  /// Whether automatic update checks are enabled
  var automaticallyChecksForUpdates: Bool {
    get { updater.automaticallyChecksForUpdates }
    set { updater.automaticallyChecksForUpdates = newValue }
  }

  /// Whether automatic downloads are enabled
  var automaticallyDownloadsUpdates: Bool {
    get { updater.automaticallyDownloadsUpdates }
    set { updater.automaticallyDownloadsUpdates = newValue }
  }

  /// The update check interval (default: 1 day)
  var updateCheckInterval: TimeInterval {
    get { updater.updateCheckInterval }
    set { updater.updateCheckInterval = newValue }
  }
}

#else

/// Stub implementation for App Store builds (no Sparkle)
final class SparkleUpdater: ObservableObject {
  static let shared = SparkleUpdater()

  @Published var canCheckForUpdates = false

  private init() {}

  func checkForUpdates() {
    // No-op for App Store builds - updates handled by App Store
  }
}

#endif
