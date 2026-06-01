import AVFoundation
import AppKit
import SwiftUI
import VoiceyCore

/// Local dictation history toggle and review list (Settings → Transcription).
struct DictationHistorySettingsView: View {
  private static let defaults = SettingsManager.defaultsStore
  @AppStorage("keepDictationHistoryLocally", store: defaults) private var keepDictationHistoryLocally =
    false
  @State private var records: [UtteranceArchiveRecord] = []
  @State private var selectedRecordID: UUID?
  @State private var audioPlayer: AVAudioPlayer?
  @State private var clearError: String?
  @State private var showClearError = false

  var body: some View {
    Section(L10n.DictationHistory.sectionTitle) {
      Toggle(L10n.DictationHistory.enableToggle, isOn: $keepDictationHistoryLocally)

      Text(L10n.DictationHistory.enableDescription)
        .font(.caption)
        .foregroundStyle(.secondary)

      if keepDictationHistoryLocally {
        HStack {
          Button(L10n.DictationHistory.deleteAll) {
            deleteAllArchive()
          }
          .buttonStyle(.bordered)

          Button(L10n.DictationHistory.revealInFinder) {
            NSWorkspace.shared.open(SessionArchiveStore.shared.rootURL())
          }
          .buttonStyle(.link)
        }

        if records.isEmpty {
          Text(L10n.DictationHistory.empty)
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          List(selection: $selectedRecordID) {
            ForEach(recordsSorted) { record in
              DictationHistoryRow(record: record)
                .tag(record.id)
            }
          }
          .frame(minHeight: 160, maxHeight: 220)

          if let record = selectedRecord {
            DictationHistoryDetailView(
              record: record,
              audioURL: SessionArchiveStore.shared.audioFileURL(for: record),
              onPlay: { play(record: record) },
              onStop: { stopPlayback() }
            )
          }
        }
      }
    }
    .onAppear { reloadRecords() }
    .onReceive(NotificationCenter.default.publisher(for: .voiceySessionArchiveDidChange)) { _ in
      reloadRecords()
    }
    .alert(L10n.DictationHistory.deleteFailed, isPresented: $showClearError) {
      Button(L10n.Model.ok, role: .cancel) {}
    } message: {
      Text(clearError ?? L10n.Model.unknownError)
    }
  }

  private var recordsSorted: [UtteranceArchiveRecord] {
    records.sorted { $0.createdAt > $1.createdAt }
  }

  private var selectedRecord: UtteranceArchiveRecord? {
    guard let selectedRecordID else { return nil }
    return records.first { $0.id == selectedRecordID }
  }

  private func reloadRecords() {
    records = SessionArchiveStore.shared.loadRecords()
    if let selectedRecordID, !records.contains(where: { $0.id == selectedRecordID }) {
      self.selectedRecordID = nil
    }
  }

  private func deleteAllArchive() {
    Task {
      do {
        stopPlayback()
        try await SessionArchiveStore.shared.deleteAll()
        await MainActor.run {
          reloadRecords()
          selectedRecordID = nil
        }
      } catch {
        await MainActor.run {
          clearError = error.localizedDescription
          showClearError = true
        }
      }
    }
  }

  private func play(record: UtteranceArchiveRecord) {
    let url = SessionArchiveStore.shared.audioFileURL(for: record)
    do {
      stopPlayback()
      audioPlayer = try AVAudioPlayer(contentsOf: url)
      audioPlayer?.play()
    } catch {
      clearError = error.localizedDescription
      showClearError = true
    }
  }

  private func stopPlayback() {
    audioPlayer?.stop()
    audioPlayer = nil
  }
}

private struct DictationHistoryRow: View {
  let record: UtteranceArchiveRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(record.createdAt, style: .date)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(record.createdAt, style: .time)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        OutcomeBadge(outcome: record.outcome)
      }
      Text(record.displayPreview)
        .font(.body)
        .lineLimit(2)
    }
    .padding(.vertical, 2)
  }
}

private struct OutcomeBadge: View {
  let outcome: UtteranceArchiveOutcome

  var body: some View {
    Text(label)
      .font(.caption2)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(background.opacity(0.15))
      .foregroundStyle(background)
      .clipShape(Capsule())
  }

  private var label: String {
    switch outcome {
    case .completed:
      return L10n.DictationHistory.outcomeCompleted
    case .emptyDelivery:
      return L10n.DictationHistory.outcomeEmpty
    case .error:
      return L10n.DictationHistory.outcomeError
    }
  }

  private var background: Color {
    switch outcome {
    case .completed:
      return .green
    case .emptyDelivery:
      return .orange
    case .error:
      return .red
    }
  }
}

private struct DictationHistoryDetailView: View {
  let record: UtteranceArchiveRecord
  let audioURL: URL
  let onPlay: () -> Void
  let onStop: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Button(L10n.DictationHistory.play, action: onPlay)
        Button(L10n.DictationHistory.stop, action: onStop)
        Spacer()
        Text(
          L10n.DictationHistory.durationSeconds(record.audioSeconds)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if let errorMessage = record.errorMessage, !errorMessage.isEmpty {
        LabeledContent(L10n.DictationHistory.errorLabel) {
          Text(errorMessage)
            .textSelection(.enabled)
        }
      }

      if !record.processedText.isEmpty {
        LabeledContent(L10n.DictationHistory.processedText) {
          Text(record.processedText)
            .textSelection(.enabled)
        }
      }

      if !record.rawText.isEmpty, record.rawText != record.processedText {
        LabeledContent(L10n.DictationHistory.rawText) {
          Text(record.rawText)
            .textSelection(.enabled)
            .font(.caption)
        }
      }

      if let partial = record.partialTranscription, !partial.isEmpty {
        LabeledContent(L10n.DictationHistory.partialText) {
          Text(partial)
            .textSelection(.enabled)
            .font(.caption)
        }
      }
    }
    .font(.callout)
    .padding(.top, 4)
  }
}
