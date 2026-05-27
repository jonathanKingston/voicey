import AppKit
import ApplicationServices
import Foundation
import VoiceyCore
import os

/// Heuristic check for whether the target app exposes enough AX text for screen steering (esp. Electron).
enum ScreenContextExposureAssessment {
  /// AX exposure quality inferred from a quick tree scan + snapshot contents.
  enum Level: String, Sendable {
    case rich
    /// Editor/chat text likely not in AX (Electron without web a11y). Intended trigger for optional OCR fallback.
    case limited
    case menuDominated
  }

  struct Result: Sendable {
    let level: Level
    let bundleID: String?
    let visitedNodes: Int
    let webAreaCount: Int
    let staticTextCount: Int

    /// When true, BM25 from AX alone is unlikely to help; consider window OCR if the user opts in.
    var shouldConsiderOCRFallback: Bool {
      level == .limited
    }
  }

  static func evaluate(targetPID: pid_t, snapshot: ScreenContextSnapshot) -> Result {
    let bundleID = NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier
    let metrics = quickScanMetrics(targetPID: targetPID)
    let level = classify(snapshot: snapshot, metrics: metrics, bundleID: bundleID)
    return Result(
      level: level,
      bundleID: bundleID,
      visitedNodes: metrics.visitedNodes,
      webAreaCount: metrics.webAreaCount,
      staticTextCount: metrics.staticTextCount
    )
  }

  private static let quickScanMaxNodes = 600
  private static let quickScanMaxDepth = 12
  private static let quickScanMaxChildren = 80

  /// Bundle IDs known to be Electron-based; limited exposure is especially common here.
  private static let electronBundleIDPrefixes = [
    "com.todesktop.",
    "com.cursor.",
    "com.github.Electron",
    "com.microsoft.VSCode",
    "com.slack.Slack",
    "com.discordapp.Discord",
    "com.spotify.client"
  ]

  static func logIfNeeded(targetPID: pid_t, snapshot: ScreenContextSnapshot) -> Result {
    let result = evaluate(targetPID: targetPID, snapshot: snapshot)

    switch result.level {
    case .rich:
      if SettingsManager.shared.enableDetailedLogging {
        AppLogger.transcription.info(
          """
          ScreenContext exposure: rich bundle=\(result.bundleID ?? "unknown", privacy: .public) \
          nodes=\(result.visitedNodes) webAreas=\(result.webAreaCount) staticText=\(result.staticTextCount)
          """
        )
      }
    case .limited:
      AppLogger.transcription.warning(
        "ScreenContext exposure: limited for \(result.bundleID ?? "pid:\(targetPID)", privacy: .public) — \(guidance(bundleID: result.bundleID), privacy: .public)"
      )
    case .menuDominated:
      AppLogger.transcription.warning(
        "ScreenContext exposure: menu-dominated tree for \(result.bundleID ?? "pid:\(targetPID)", privacy: .public); dismiss menus and focus the editor. \(guidance(bundleID: result.bundleID), privacy: .public)"
      )
    }
    return result
  }

  // MARK: - Classification

  private static func classify(
    snapshot: ScreenContextSnapshot,
    metrics: ScanMetrics,
    bundleID: String?
  ) -> Level {
    let queryChars = snapshot.queryText.trimmingCharacters(in: .whitespacesAndNewlines).count
    let chunkCount = snapshot.corpusChunks.count

    if metrics.menuItemCount > metrics.visitedNodes / 2, metrics.webAreaCount == 0 {
      return .menuDominated
    }

    if metrics.webAreaCount >= 1, metrics.staticTextCount >= 15 || queryChars >= 20 || chunkCount >= 3 {
      return .rich
    }

    let electronLikely = isElectronBundle(bundleID)
    let shallowTree = metrics.visitedNodes < 40 && metrics.webAreaCount == 0
    let noEditorSignal = queryChars == 0 && chunkCount <= 1 && metrics.staticTextCount < 5

    if shallowTree || (electronLikely && noEditorSignal) {
      return .limited
    }

    if metrics.webAreaCount >= 1 || queryChars >= 12 || chunkCount >= 2 {
      return .rich
    }

    if electronLikely && metrics.webAreaCount == 0 {
      return .limited
    }

    return .rich
  }

  private static func isElectronBundle(_ bundleID: String?) -> Bool {
    guard let bundleID else { return false }
    return electronBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
  }

  private static func guidance(bundleID: String?) -> String {
    var parts = [
      "The app may not publish editor/chat text via macOS Accessibility (common until the host enables Chromium accessibility).",
      "Use the manual transcription glossary or record while a native app (Notes, TextEdit, Safari) holds the relevant text."
    ]
    if isElectronBundle(bundleID) {
      parts.append(
        "For Cursor: report via in-app Help or https://forum.cursor.com — ask for improved macOS AX / webContents accessibility for third-party tools."
      )
    }
    return parts.joined(separator: " ")
  }

  // MARK: - Quick scan

  private struct ScanMetrics {
    var visitedNodes = 0
    var webAreaCount = 0
    var staticTextCount = 0
    var menuItemCount = 0
  }

  private static func quickScanMetrics(targetPID: pid_t) -> ScanMetrics {
    let appElement = AXUIElementCreateApplication(targetPID)
    var metrics = ScanMetrics()
    var roots: [AXUIElement] = []

    if let window = copyFocusedWindow(from: appElement) {
      roots.append(window)
    }
    if let focused = copyFocusedElement(from: appElement) {
      roots.append(focused)
    }
    if roots.isEmpty {
      roots.append(appElement)
    }

    for root in roots {
      scan(element: root, depth: 0, metrics: &metrics)
      if metrics.visitedNodes >= quickScanMaxNodes { break }
    }
    return metrics
  }

  private static func scan(element: AXUIElement, depth: Int, metrics: inout ScanMetrics) {
    guard depth <= quickScanMaxDepth, metrics.visitedNodes < quickScanMaxNodes else { return }
    metrics.visitedNodes += 1

    if let elementRole = role(of: element) {
      switch elementRole {
      case "AXWebArea": metrics.webAreaCount += 1
      case "AXStaticText": metrics.staticTextCount += 1
      case "AXMenuItem", "AXMenuBarItem": metrics.menuItemCount += 1
      default: break
      }
    }

    guard depth < quickScanMaxDepth else { return }
    let children = copyChildren(element)
    let limit = min(children.count, quickScanMaxChildren)
    for index in 0..<limit {
      scan(element: children[index], depth: depth + 1, metrics: &metrics)
      if metrics.visitedNodes >= quickScanMaxNodes { return }
    }
  }

  private static func copyFocusedWindow(from appElement: AXUIElement) -> AXUIElement? {
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
      let element = window,
      CFGetTypeID(element) == AXUIElementGetTypeID()
    else { return nil }
    // swiftlint:disable:next force_cast
    return (element as! AXUIElement)
  }

  private static func copyFocusedElement(from appElement: AXUIElement) -> AXUIElement? {
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
      let element = focused,
      CFGetTypeID(element) == AXUIElementGetTypeID()
    else { return nil }
    // swiftlint:disable:next force_cast
    return (element as! AXUIElement)
  }

  private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
      let childArray = children as? [AXUIElement]
    else { return [] }
    return childArray
  }

  private static func role(of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
      let value
    else { return nil }
    if let string = value as? String { return string }
    if CFGetTypeID(value) == CFStringGetTypeID() {
      // swiftlint:disable:next force_cast
      return (value as! CFString) as String
    }
    return nil
  }
}
