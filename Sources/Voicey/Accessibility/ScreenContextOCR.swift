import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision
import VoiceyCore
import os

/// On-device window OCR fallback when accessibility exposure is limited.
enum ScreenContextOCR {
  private static let maxCorpusChunkLength = 500
  private static let minCorpusChunkLength = 8
  private static let maxQueryCharacterCount = 4000

  /// Captures the target app's frontmost on-screen window before overlay/UI updates (call early on record start).
  static func grabFrontWindowImageSync(targetPID: pid_t) -> CGImage? {
    guard CGPreflightScreenCaptureAccess() else { return nil }

    var image: CGImage?
    let group = DispatchGroup()
    group.enter()
    Task {
      image = await captureFrontWindowImage(targetPID: targetPID)
      group.leave()
    }
    group.wait()
    return image
  }

  static func recognizeText(in image: CGImage) async -> ScreenContextSnapshot? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
          try handler.perform([request])
        } catch {
          AppLogger.transcription.error(
            "ScreenContextOCR: Vision failed: \(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(returning: nil)
          return
        }

        let lines = (request.results ?? [])
          .compactMap { $0.topCandidates(1).first?.string }
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }

        let snapshot = snapshot(fromRecognizedLines: lines)
        AppLogger.transcription.info(
          "ScreenContextOCR: lines=\(lines.count) queryChars=\(snapshot.queryText.count) chunks=\(snapshot.corpusChunks.count)"
        )
        if SettingsManager.shared.enableDetailedLogging, !lines.isEmpty {
          let preview = lines.prefix(8).joined(separator: " | ")
          AppLogger.transcription.info("ScreenContextOCR sample: \(preview, privacy: .public)")
        }
        continuation.resume(returning: snapshot)
      }
    }
  }

  // MARK: - ScreenCaptureKit

  private static func captureFrontWindowImage(targetPID: pid_t) async -> CGImage? {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      guard
        let window = content.windows.first(where: {
          $0.owningApplication?.processID == targetPID && $0.isOnScreen && $0.frame.width > 40
        })
      else {
        AppLogger.transcription.debug("ScreenContextOCR: No on-screen window for pid=\(targetPID)")
        return nil
      }

      let filter = SCContentFilter(desktopIndependentWindow: window)
      let configuration = SCStreamConfiguration()
      let scale = window.frame.width > 0 ? min(2.0, 4096 / window.frame.width) : 1.0
      configuration.width = Int(window.frame.width * scale)
      configuration.height = Int(window.frame.height * scale)
      configuration.captureResolution = .best

      return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    } catch {
      AppLogger.transcription.error(
        "ScreenContextOCR: ScreenCaptureKit failed: \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
  }

  // MARK: - Snapshot building

  private static func snapshot(fromRecognizedLines lines: [String]) -> ScreenContextSnapshot {
    guard !lines.isEmpty else { return .empty }

    let queryText = String(lines.prefix(12).joined(separator: " ").prefix(maxQueryCharacterCount))
    var chunks: [String] = []
    var seen: Set<String> = []

    for line in lines {
      guard line.count >= minCorpusChunkLength else { continue }
      let chunk = String(line.prefix(maxCorpusChunkLength))
      let key = chunk.lowercased()
      guard !seen.contains(key) else { continue }
      seen.insert(key)
      chunks.append(chunk)
    }

    if chunks.isEmpty, let longest = lines.max(by: { $0.count < $1.count }), longest.count >= 4 {
      chunks.append(String(longest.prefix(maxCorpusChunkLength)))
    }

    return ScreenContextSnapshot(queryText: queryText, corpusChunks: chunks)
  }
}
