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

  /// The default model to download
  private let defaultModel = WhisperModel.largeTurbo

  /// Whether all required setup is complete
  private var isSetupComplete: Bool {
    microphoneGranted && accessibilityGranted && modelManager.isDownloaded(defaultModel)
  }

  /// Whether model is currently downloading
  private var isModelDownloading: Bool {
    modelManager.isDownloading[defaultModel] == true
  }

  /// Whether model is ready
  private var isModelReady: Bool {
    modelManager.isDownloaded(defaultModel)
  }

  /// Download progress (0-1)
  private var downloadProgress: Double {
    modelManager.downloadProgress[defaultModel] ?? 0
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      VStack(spacing: 8) {
        Image(systemName: "mic.circle.fill")
          .font(.system(size: 60))
          .foregroundStyle(.blue)

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

        // Step 1: Model Download (most important - show first)
        SetupStepRow(
          stepNumber: 1,
          icon: "cpu",
          title: "Download AI Model",
          description: "\(defaultModel.displayName) (~1.5GB)",
          isComplete: isModelReady,
          isInProgress: isModelDownloading,
          progress: downloadProgress,
          buttonTitle: isModelReady
            ? "Ready" : (isModelDownloading ? "Downloading..." : "Download"),
          action: startModelDownloadIfNeeded
        )

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

        // Step 3: Accessibility
        SetupStepRow(
          stepNumber: 3,
          icon: "keyboard",
          title: "Accessibility Access",
          description: "Required to paste text into apps",
          isComplete: accessibilityGranted,
          isInProgress: isCheckingAccessibility,
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
      .padding(.horizontal, 30)

      Spacer()

      // Status and continue button
      VStack(spacing: 16) {
        // Status message
        if !isSetupComplete {
          HStack(spacing: 8) {
            if isModelDownloading {
              ProgressView()
                .scaleEffect(0.7)
              Text("Downloading model... \(Int(downloadProgress * 100))%")
            } else if !isModelReady {
              Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
              Text("Model download required")
            } else if !microphoneGranted {
              Image(systemName: "mic.slash")
                .foregroundStyle(.orange)
              Text("Microphone access required")
            } else if !accessibilityGranted {
              Image(systemName: "keyboard")
                .foregroundStyle(.orange)
              Text("Accessibility access required")
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
            Text("All set! Ready to start.")
          }
          .font(.subheadline)
          .foregroundStyle(.green)
        }

        // Download progress bar
        if isModelDownloading {
          ProgressView(value: downloadProgress)
            .progressViewStyle(.linear)
            .padding(.horizontal, 30)
        }

        HStack(spacing: 12) {
          // Recheck button for accessibility
          if !accessibilityGranted && !isCheckingAccessibility {
            Button("Recheck") {
              recheckPermissions()
            }
            .buttonStyle(.bordered)
          }

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

        // Fallback for accessibility detection issues
        if !accessibilityGranted && microphoneGranted && isModelReady {
          Button {
            debugPrint("⚠️ Continue anyway pressed", category: "ONBOARD")
            onComplete()
          } label: {
            Text("I've granted accessibility → Continue anyway")
              .font(.caption)
              .underline()
          }
          .buttonStyle(.plain)
          .foregroundStyle(.blue)
        }
      }
      .padding(.bottom, 30)
    }
    .frame(width: 480, height: 720)
    .onAppear {
      checkCurrentPermissions()
      startModelDownloadIfNeeded()
    }
    .onDisappear {
      accessibilityCheckTask?.cancel()
    }
  }

  private func checkCurrentPermissions() {
    Task {
      microphoneGranted = await PermissionsManager.shared.checkMicrophonePermission()
      accessibilityGranted = PermissionsManager.shared.checkAccessibilityPermission()
      launchAtLoginEnabled = SettingsManager.shared.launchAtLogin
    }
  }

  /// Start downloading the default model automatically during onboarding
  private func startModelDownloadIfNeeded() {
    // Only download if not already downloaded and not currently downloading
    guard !modelManager.isDownloaded(defaultModel),
      modelManager.isDownloading[defaultModel] != true
    else {
      return
    }

    debugPrint(
      "📥 Auto-starting download of \(defaultModel.displayName) during onboarding",
      category: "ONBOARD")
    modelManager.downloadModel(defaultModel)
  }

  private func recheckPermissions() {
    Task {
      microphoneGranted = await PermissionsManager.shared.checkMicrophonePermission()
      // Use refresh for accessibility - tries multiple detection methods
      let granted = PermissionsManager.shared.refreshAccessibilityPermission()
      await MainActor.run {
        accessibilityGranted = granted
        if granted {
          AppLogger.general.info("Accessibility permission detected as granted")
        } else {
          AppLogger.general.warning("Accessibility permission still not detected")
        }
      }
    }
  }

  private func requestMicrophonePermission() {
    Task {
      let granted = await PermissionsManager.shared.requestMicrophonePermission()
      await MainActor.run {
        microphoneGranted = granted
      }
    }
  }

  private func requestAccessibilityPermission() {
    // Cancel any existing check
    accessibilityCheckTask?.cancel()

    PermissionsManager.shared.promptForAccessibilityPermission()
    isCheckingAccessibility = true

    // Poll for accessibility permission since we can't get a callback
    accessibilityCheckTask = Task {
      for i in 0..<60 {  // Check for 60 seconds
        if Task.isCancelled { break }

        try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 second

        // Use the refresh method which tries multiple detection approaches
        let granted = PermissionsManager.shared.refreshAccessibilityPermission()

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
