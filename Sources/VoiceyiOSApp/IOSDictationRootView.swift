import SwiftUI

struct IOSDictationRootView: View {
  @StateObject private var viewModel = IOSDictationViewModel()

  var body: some View {
    NavigationStack {
      Form {
        Section("Keyboard Integration") {
          Text("1. Enable Voicey Keyboard in Settings > General > Keyboard.")
          Text("2. Allow Full Access for Voicey Keyboard.")
          Text("3. Tap Dictate from the keyboard to hand off into this app.")
        }

        Section("Setup") {
          if let setupErrorMessage = viewModel.setupErrorMessage {
            Text(setupErrorMessage)
              .foregroundStyle(.red)
          } else {
            Text("App Group: \(VoiceyiOSConstants.appGroupIdentifier)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Section("Dictation Request State") {
          LabeledContent("Status", value: viewModel.statusMessage)
          LabeledContent("Pending Request", value: viewModel.pendingRequestID ?? "None")

          Button("Refresh State") {
            viewModel.refreshState()
          }

          Button("Mark Request Processing") {
            viewModel.markRequestProcessing()
          }
        }

        Section("Publish Result") {
          TextField("Transcript text", text: $viewModel.draftTranscript, axis: .vertical)
            .lineLimit(3...6)

          Button("Publish Transcript to Keyboard") {
            viewModel.publishResult()
          }
          .disabled(viewModel.draftTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        Section("Last Published Result") {
          Text(viewModel.lastPublishedResult ?? "None")
            .foregroundStyle(.secondary)
        }

        Section {
          Button("Clear Shared Records", role: .destructive) {
            viewModel.clearSharedRecords()
          }
        }
      }
      .navigationTitle("Voicey iOS")
    }
    .task {
      viewModel.refreshState()
    }
    .onOpenURL { url in
      viewModel.handleIncomingURL(url)
    }
  }
}

#Preview {
  IOSDictationRootView()
}
