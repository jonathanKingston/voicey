import AppKit
import Combine
import SwiftUI

/// First-run onboarding view to guide users through required permissions
struct OnboardingView: View {
  @State private var microphoneGranted = false
  @State private var accessibilityGranted = false
  @State private var launchAtLoginEnabled = false
  @State private var isCheckingAccessibility = false
  @State private var accessibilityCheckTask: Task<Void, Never>?

  // Observe model status from shared state
  @ObservedObject private var modelManager = ModelManager.shared

  let onComplete: () -> Void

  /// The fast model to download first for quick startup
  private let fastModel = WhisperModel.base

  /// The high-quality model to download in background
  private let qualityModel = WhisperModel.largeTurbo

  /// Whether all required setup is complete (fast model is enough to proceed)
  private var isSetupComplete: Bool {
    microphoneGranted && modelManager.hasDownloadedModel
  }

  /// Whether fast model is currently downloading
  private var isFastModelDownloading: Bool {
    modelManager.isDownloading[fastModel] == true
  }

  /// Whether quality model is currently downloading
  private var isQualityModelDownloading: Bool {
    modelManager.isDownloading[qualityModel] == true
  }

  /// Whether fast model is ready
  private var isFastModelReady: Bool {
    // Any downloaded model is sufficient to proceed; fast model is just the default download.
    modelManager.hasDownloadedModel || modelManager.isDownloaded(fastModel)
  }

  /// Whether quality model is ready
  private var isQualityModelReady: Bool {
    modelManager.isDownloaded(qualityModel)
  }

  /// Download progress for fast model (0-1)
  private var fastDownloadProgress: Double {
    modelManager.downloadProgress[fastModel] ?? 0
  }

  /// Download progress for quality model (0-1)
  private var qualityDownloadProgress: Double {
    modelManager.downloadProgress[qualityModel] ?? 0
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      VStack(spacing: 8) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 80, height: 80)

        Text("Welcome to Voicey")
          .font(.title)
          .fontWeight(.bold)

        Text("Voice-to-text transcription for macOS")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 30)
      .padding(.bottom, 20)

      Divider()
        .padding(.horizontal, 20)

      // Setup steps
      VStack(spacing: 12) {
        Text("Complete these steps to get started:")
          .font(.headline)
          .padding(.top, 20)

        // Step 1: Model Download (any model works; fast model is default)
        SetupStepRow(
          stepNumber: 1,
          icon: "cpu",
          title: "Download Model",
          description: "Any model works. Default: \(fastModel.displayName) (~80MB) - Quick start",
          isComplete: isFastModelReady,
          isInProgress: isFastModelDownloading,
          progress: fastDownloadProgress,
          buttonTitle: isFastModelReady
            ? "Ready" : (isFastModelDownloading ? "Downloading..." : "Download"),
          action: startFastModelDownload
        )

        // Step 1b: Quality Model Download (background upgrade)
        SetupStepRow(
          stepNumber: 0,  // No number - it's a sub-step
          icon: "sparkles",
          title: "Download Quality Model",
          description: "\(qualityModel.displayName) (~1.5GB) - Better accuracy",
          isComplete: isQualityModelReady,
          isInProgress: isQualityModelDownloading,
          progress: qualityDownloadProgress,
          isOptional: true,
          buttonTitle: isQualityModelReady
            ? "Ready"
            : (isQualityModelDownloading
              ? "Downloading..." : (isFastModelReady ? "Download" : "After fast model")),
          action: startQualityModelDownload
        )
        .disabled(!isFastModelReady && !isQualityModelDownloading)
        .opacity(isFastModelReady || isQualityModelDownloading || isQualityModelReady ? 1.0 : 0.6)

        // Step 2: Microphone
        SetupStepRow(
          stepNumber: 2,
          icon: "mic.fill",
          title: "Microphone Access",
          description: "Required to hear your voice",
          isComplete: microphoneGranted,
          buttonTitle: microphoneGranted ? "Granted" : "Allow",
          action: requestMicrophonePermission
        )

        // Step 3: Accessibility (optional, enables auto-insert into text fields)
        SetupStepRow(
          stepNumber: 3,
          icon: "keyboard",
          title: "Accessibility Access",
          description: "Optional: Enables auto-insert into text fields",
          isComplete: accessibilityGranted,
          isInProgress: isCheckingAccessibility,
          progress: 0,
          isOptional: true,
          buttonTitle: accessibilityGranted
            ? "Granted" : (isCheckingAccessibility ? "Checking..." : "Open Settings"),
          action: requestAccessibilityPermission
        )

        // Step 4: Launch at Login (optional)
        SetupStepRow(
          stepNumber: 4,
          icon: "arrow.clockwise",
          title: "Launch at Login",
          description: "Start automatically (optional)",
          isComplete: launchAtLoginEnabled,
          isOptional: true,
          buttonTitle: launchAtLoginEnabled ? "Enabled" : "Enable",
          action: enableLaunchAtLogin
        )
      }

      // Background upgrade status
      if isFastModelReady && !isQualityModelReady {
        VStack(spacing: 8) {
          if isQualityModelDownloading {
            HStack(spacing: 8) {
              ProgressView()
                .scaleEffect(0.7)
              Text(
                "Upgrading to \(qualityModel.displayName)... \(Int(qualityDownloadProgress * 100))%"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            ProgressView(value: qualityDownloadProgress)
              .progressViewStyle(.linear)
          } else {
            Text("💡 Tip: Download the quality model for better accuracy")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 30)
        .padding(.top, 8)
      }

      Spacer()

      // Status and continue button
      VStack(spacing: 16) {
        // Status message
        if !isSetupComplete {
          HStack(spacing: 8) {
            if isFastModelDownloading {
              ProgressView()
                .scaleEffect(0.7)
              Text("Downloading model... \(Int(fastDownloadProgress * 100))%")
            } else if !isFastModelReady {
              Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
              Text("Model download required")
            } else if !microphoneGranted {
              Image(systemName: "mic.slash")
                .foregroundStyle(.orange)
              Text("Microphone access required")
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
            if isQualityModelReady {
              Text("All set! Using quality model.")
            } else if isQualityModelDownloading {
              Text("Ready! Quality model downloading in background...")
            } else {
              Text("Ready to start with fast model!")
            }
          }
          .font(.subheadline)
          .foregroundStyle(.green)
        }

        // Download progress bar
        if isFastModelDownloading {
          ProgressView(value: fastDownloadProgress)
            .progressViewStyle(.linear)
            .padding(.horizontal, 30)
        }

        HStack(spacing: 12) {
          Button {
            debugPrint("✅ Get Started pressed - setup complete", category: "ONBOARD")
            onComplete()
          } label: {
            Text(isSetupComplete ? "Get Started" : "Please complete setup")
              .font(.headline)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
          }
          .buttonStyle(.borderedProminent)
          .disabled(!isSetupComplete)
        }
        .padding(.horizontal, 30)
      }
      .padding(.bottom, 30)
    }
    .frame(width: 480, height: 780)  // Slightly taller for the extra model row
    .onAppear {
      checkCurrentPermissions()
      // Only auto-download if the user has no models yet.
      if !modelManager.hasDownloadedModel {
        startFastModelDownload()
      }
    }
    .onDisappear {
      accessibilityCheckTask?.cancel()
      accessibilityCheckTask = nil
    }
  }

  private func checkCurrentPermissions() {
    Task {
      microphoneGranted = await PermissionsManager.shared.checkMicrophonePermission()
      accessibilityGranted = PermissionsManager.shared.checkAccessibilityPermission()
      launchAtLoginEnabled = SettingsManager.shared.launchAtLogin
    }
  }

  /// Start downloading the fast model automatically during onboarding
  private func startFastModelDownload() {
    // If any model is already downloaded, don't force-download the fast model.
    guard !modelManager.hasDownloadedModel else { return }

    // Only download if not already downloaded and not currently downloading
    guard !modelManager.isDownloaded(fastModel),
      modelManager.isDownloading[fastModel] != true
    else {
      // If fast model is already ready, start quality model download
      if isFastModelReady {
        startQualityModelDownload()
      }
      return
    }

    debugPrint(
      "📥 Auto-starting download of \(fastModel.displayName) during onboarding",
      category: "ONBOARD")
    modelManager.downloadModel(fastModel)

    // Watch for fast model completion to auto-start quality model
    Task {
      await waitForFastModelThenStartQualityDownload()
    }
  }

  /// Wait for fast model to complete, then start quality model download
  private func waitForFastModelThenStartQualityDownload() async {
    // Poll until fast model download completes
    while modelManager.isDownloading[fastModel] == true {
      try? await Task.sleep(nanoseconds: 500_000_000)  // Check every 0.5s
    }

    // If fast model is now downloaded, start quality model
    if modelManager.isDownloaded(fastModel) {
      await MainActor.run {
        startQualityModelDownload()
      }
    }
  }

  /// Start downloading the quality model (can be done in background)
  private func startQualityModelDownload() {
    // Only download if not already downloaded and not currently downloading
    guard !modelManager.isDownloaded(qualityModel),
      modelManager.isDownloading[qualityModel] != true
    else {
      return
    }

    debugPrint(
      "📥 Starting download of \(qualityModel.displayName) for quality upgrade",
      category: "ONBOARD")
    modelManager.downloadModel(qualityModel)
  }

  private func requestMicrophonePermission() {
    Task {
      let granted = await PermissionsManager.shared.requestMicrophonePermission()
      await MainActor.run {
        microphoneGranted = granted
        bringOnboardingWindowToFront()
      }
    }
  }

  private func bringOnboardingWindowToFront() {
    NSApp.activate(ignoringOtherApps: true)

    // The system permission prompt can cause our onboarding window to fall behind other apps.
    // Re-assert focus after the permission flow completes.
    if let window = NSApp.windows.first(where: { $0.title == "Welcome to Voicey" }) {
      window.makeKeyAndOrderFront(nil)
    } else if let window = NSApp.windows.first {
      window.makeKeyAndOrderFront(nil)
    }
  }

  private func requestAccessibilityPermission() {
    // Cancel any existing check
    accessibilityCheckTask?.cancel()
    accessibilityCheckTask = nil

    PermissionsManager.shared.promptForAccessibilityPermission()
    isCheckingAccessibility = true

    // Poll for accessibility permission since we can't get a callback
    accessibilityCheckTask = Task {
      for i in 0..<60 {  // Check for 60 seconds
        if Task.isCancelled { break }

        try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 second

        let granted = PermissionsManager.shared.checkAccessibilityPermission()

        await MainActor.run {
          accessibilityGranted = granted
          // Stop showing "Checking..." after a few seconds
          if i > 6 {
            isCheckingAccessibility = false
          }
        }

        if granted {
          await MainActor.run {
            isCheckingAccessibility = false
          }
          break
        }
      }

      await MainActor.run {
        isCheckingAccessibility = false
      }
    }
  }

  private func enableLaunchAtLogin() {
    SettingsManager.shared.configureLaunchAtLogin(enabled: true)
    launchAtLoginEnabled = true
  }
}

/// Setup step row with progress support
struct SetupStepRow: View {
  let stepNumber: Int
  let icon: String
  let title: String
  let description: String
  let isComplete: Bool
  var isInProgress: Bool = false
  var progress: Double = 0
  var isOptional: Bool = false
  let buttonTitle: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 16) {
      // Step number / status indicator
      ZStack {
        Circle()
          .fill(
            isComplete
              ? Color.green.opacity(0.15)
              : (isInProgress ? Color.blue.opacity(0.15) : Color.gray.opacity(0.1))
          )
          .frame(width: 44, height: 44)

        if isComplete {
          Image(systemName: "checkmark")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.green)
        } else if isInProgress {
          if progress > 0 {
            // Circular progress
            Circle()
              .stroke(Color.blue.opacity(0.3), lineWidth: 3)
              .frame(width: 30, height: 30)
            Circle()
              .trim(from: 0, to: progress)
              .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
              .frame(width: 30, height: 30)
              .rotationEffect(.degrees(-90))
          } else {
            ProgressView()
              .scaleEffect(0.8)
          }
        } else {
          Text("\(stepNumber)")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.secondary)
        }
      }

      // Text
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(title)
            .font(.headline)
            .foregroundStyle(isComplete ? .secondary : .primary)

          if isOptional {
            Text("Optional")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(Color.secondary.opacity(0.2))
              .cornerRadius(3)
          }
        }

        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      // Button
      Button(action: action) {
        Text(buttonTitle)
          .font(.subheadline)
      }
      .buttonStyle(.bordered)
      .disabled(isComplete || isInProgress)
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 12)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(isComplete ? Color.green.opacity(0.05) : Color.clear)
    )
  }
}

/// Legacy permission row (keeping for compatibility)
struct PermissionRow: View {
  let icon: String
  let title: String
  let description: String
  let isGranted: Bool
  let buttonTitle: String
  var isOptional: Bool = false
  let action: () -> Void

  var body: some View {
    SetupStepRow(
      stepNumber: 0,
      icon: icon,
      title: title,
      description: description,
      isComplete: isGranted,
      isOptional: isOptional,
      buttonTitle: buttonTitle,
      action: action
    )
  }
}

#Preview {
  OnboardingView(onComplete: {})
}
