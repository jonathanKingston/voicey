import AppKit
import ApplicationServices
import Foundation
import VoiceyCore
import os

/// Reads accessibility text from the target app for transcription vocabulary steering.
enum ScreenContextCollector {
  private static let maxTreeDepth = 4
  private static let maxNodesVisited = 200
  private static let maxChildrenPerNode = 40
  private static let minChunkLength = 12

  static func capture(targetPID: pid_t) -> ScreenContextSnapshot {
    guard AXIsProcessTrusted() else {
      AppLogger.transcription.debug("ScreenContextCollector: Accessibility not trusted")
      return .empty
    }

    let appElement = AXUIElementCreateApplication(targetPID)
    var queryParts: [String] = []
    var chunks: [String] = []
    var visitState = VisitState()

    if let focused = copyFocusedElement(from: appElement) {
      queryParts.append(
        contentsOf: textFromElement(focused, includeValue: true, includeSelected: true))
      collectChunks(from: focused, depth: 0, visitState: &visitState, chunks: &chunks)
    }

    if let window = copyFocusedWindow(from: appElement) {
      collectChunks(from: window, depth: 0, visitState: &visitState, chunks: &chunks)
    }

    let queryText = queryParts.joined(separator: " ")
    let uniqueChunks = dedupeChunks(chunks)

    AppLogger.transcription.info(
      "ScreenContextCollector: pid=\(targetPID) queryChars=\(queryText.count) chunks=\(uniqueChunks.count)"
    )

    return ScreenContextSnapshot(queryText: queryText, corpusChunks: uniqueChunks)
  }

  // MARK: - AX navigation

  private static func copyFocusedElement(from appElement: AXUIElement) -> AXUIElement? {
    var focused: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedUIElementAttribute as CFString,
      &focused
    )
    guard result == .success,
      let element = focused,
      CFGetTypeID(element) == AXUIElementGetTypeID()
    else {
      return nil
    }
    // swiftlint:disable:next force_cast
    return (element as! AXUIElement)
  }

  private static func copyFocusedWindow(from appElement: AXUIElement) -> AXUIElement? {
    var window: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedWindowAttribute as CFString,
      &window
    )
    guard result == .success,
      let element = window,
      CFGetTypeID(element) == AXUIElementGetTypeID()
    else {
      return nil
    }
    // swiftlint:disable:next force_cast
    return (element as! AXUIElement)
  }

  // MARK: - Text extraction

  private static func textFromElement(
    _ element: AXUIElement,
    includeValue: Bool,
    includeSelected: Bool
  ) -> [String] {
    var parts: [String] = []

    if includeValue, let value = copyStringAttribute(element, kAXValueAttribute as CFString) {
      parts.append(value)
    }
    if includeSelected, let selected = copyStringAttribute(element, kAXSelectedTextAttribute as CFString) {
      parts.append(selected)
    }
    if let title = copyStringAttribute(element, kAXTitleAttribute as CFString) {
      parts.append(title)
    }
    if let description = copyStringAttribute(element, kAXDescriptionAttribute as CFString) {
      parts.append(description)
    }

    return parts
  }

  private static func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success, let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func collectChunks(
    from element: AXUIElement,
    depth: Int,
    visitState: inout VisitState,
    chunks: inout [String]
  ) {
    guard depth <= maxTreeDepth, visitState.visitedNodes < maxNodesVisited else { return }
    visitState.visitedNodes += 1

    let textParts = textFromElement(element, includeValue: true, includeSelected: false)
    if let chunk = mergedChunk(from: textParts) {
      chunks.append(chunk)
    }

    guard depth < maxTreeDepth else { return }

    var children: CFTypeRef?
    let childrenResult = AXUIElementCopyAttributeValue(
      element,
      kAXChildrenAttribute as CFString,
      &children
    )
    guard childrenResult == .success, let childArray = children as? [AXUIElement] else { return }

    let limit = min(childArray.count, maxChildrenPerNode)
    for index in 0..<limit {
      collectChunks(
        from: childArray[index], depth: depth + 1, visitState: &visitState, chunks: &chunks)
      if visitState.visitedNodes >= maxNodesVisited { return }
    }
  }

  private static func mergedChunk(from parts: [String]) -> String? {
    let merged = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard merged.count >= minChunkLength else { return nil }
    return merged
  }

  private static func dedupeChunks(_ chunks: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for chunk in chunks {
      let key = chunk.lowercased()
      guard !seen.contains(key) else { continue }
      seen.insert(key)
      result.append(chunk)
    }
    return result
  }

  private struct VisitState {
    var visitedNodes = 0
  }
}
