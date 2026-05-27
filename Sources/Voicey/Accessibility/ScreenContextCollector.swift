import AppKit
import ApplicationServices
import Foundation
import VoiceyCore
import os

/// Reads accessibility text from the target app for transcription vocabulary steering.
enum ScreenContextCollector {
  private static let maxTreeDepth = 5
  private static let maxTreeDepthWebArea = 9
  private static let maxNodesVisited = 350
  private static let maxNodesVisitedWebArea = 500
  private static let maxChildrenPerNode = 48
  private static let minChunkLength = 8
  private static let maxQueryHarvestNodes = 120
  private static let maxQueryCharacterCount = 4000

  static func capture(targetPID: pid_t) -> ScreenContextSnapshot {
    captureWithExposure(targetPID: targetPID).snapshot
  }

  static func captureWithExposure(targetPID: pid_t) -> (
    snapshot: ScreenContextSnapshot,
    exposure: ScreenContextExposureAssessment.Result
  ) {
    guard AXIsProcessTrusted() else {
      AppLogger.transcription.debug("ScreenContextCollector: Accessibility not trusted")
      let empty = ScreenContextSnapshot.empty
      return (empty, ScreenContextExposureAssessment.evaluate(targetPID: targetPID, snapshot: empty))
    }

    let appElement = AXUIElementCreateApplication(targetPID)
    var queryParts: [String] = []
    var chunks: [String] = []
    var visitState = VisitState()
    var harvestedForLog = ""

    if let focused = copyFocusedElement(from: appElement) {
      queryParts.append(
        contentsOf: textFromElement(focused, includeValue: true, includeSelected: true))
      let directQuery = queryParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      if directQuery.isEmpty {
        let harvested = harvestNearbyVisibleText(from: focused)
        harvestedForLog = harvested
        if !harvested.isEmpty {
          queryParts = [harvested]
        }
      }
      let focusedDepthLimit = role(of: focused) == "AXWebArea" ? maxTreeDepthWebArea : maxTreeDepth
      var focusedVisit = VisitState(maxNodes: maxNodesVisitedWebArea)
      collectChunks(
        from: focused,
        depth: 0,
        maxDepth: focusedDepthLimit,
        visitState: &focusedVisit,
        chunks: &chunks
      )
    }

    if let window = copyFocusedWindow(from: appElement) {
      collectChunks(from: window, depth: 0, maxDepth: maxTreeDepth, visitState: &visitState, chunks: &chunks)
      collectWebAreaChunks(in: window, visitState: &visitState, chunks: &chunks)
    }

    let queryText = String(
      queryParts.joined(separator: " ").prefix(maxQueryCharacterCount)
    )
    let uniqueChunks = dedupeChunks(chunks)

    AppLogger.transcription.info(
      "ScreenContextCollector: pid=\(targetPID) queryChars=\(queryText.count) chunks=\(uniqueChunks.count)"
    )
    if SettingsManager.shared.enableDetailedLogging, !harvestedForLog.isEmpty {
      AppLogger.transcription.info(
        "ScreenContextCollector harvest: \(harvestedForLog, privacy: .private)"
      )
    }

    let snapshot = ScreenContextSnapshot(queryText: queryText, corpusChunks: uniqueChunks)
    let exposure = ScreenContextExposureAssessment.logIfNeeded(targetPID: targetPID, snapshot: snapshot)
    return (snapshot, exposure)
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
    if let placeholder = copyStringAttribute(element, "AXPlaceholderValue" as CFString) {
      parts.append(placeholder)
    }

    return parts
  }

  /// BFS around the focused node (and a few ancestors) for Chromium/Electron `AXStaticText` trees.
  private static func harvestNearbyVisibleText(from root: AXUIElement) -> String {
    var roots: [AXUIElement] = [root]
    roots.append(contentsOf: ancestorElements(from: root, limit: 5))

    var queue: [AXUIElement] = roots
    var visited = 0
    var snippets: [String] = []
    var seenSnippetKeys: Set<String> = []

    while !queue.isEmpty, visited < maxQueryHarvestNodes {
      let element = queue.removeFirst()
      visited += 1

      for part in textFromElement(element, includeValue: true, includeSelected: false) {
        guard part.count >= 2 else { continue }
        let key = part.lowercased()
        guard !seenSnippetKeys.contains(key) else { continue }
        seenSnippetKeys.insert(key)
        snippets.append(part)
      }

      for child in copyChildren(element) {
        queue.append(child)
      }
    }

    if SettingsManager.shared.enableDetailedLogging {
      AppLogger.transcription.info(
        "ScreenContextCollector harvest stats: nodes=\(visited) snippets=\(snippets.count)"
      )
    }

    return String(snippets.joined(separator: " ").prefix(maxQueryCharacterCount))
  }

  private static func ancestorElements(from element: AXUIElement, limit: Int) -> [AXUIElement] {
    var ancestors: [AXUIElement] = []
    var current: AXUIElement? = element
    for _ in 0..<limit {
      guard let el = current else { break }
      var parentRef: CFTypeRef?
      let result = AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef)
      guard result == .success,
        let parentRef,
        CFGetTypeID(parentRef) == AXUIElementGetTypeID()
      else { break }
      // swiftlint:disable:next force_cast
      let parent = parentRef as! AXUIElement
      ancestors.append(parent)
      current = parent
    }
    return ancestors
  }

  private static func collectWebAreaChunks(
    in element: AXUIElement,
    visitState: inout VisitState,
    chunks: inout [String]
  ) {
    guard visitState.visitedNodes < visitState.maxNodes else { return }
    if role(of: element) == "AXWebArea" {
      var webVisit = VisitState(maxNodes: maxNodesVisitedWebArea)
      collectChunks(
        from: element,
        depth: 0,
        maxDepth: maxTreeDepthWebArea,
        visitState: &webVisit,
        chunks: &chunks
      )
      visitState.visitedNodes += webVisit.visitedNodes
    }

    for child in copyChildren(element) {
      collectWebAreaChunks(in: child, visitState: &visitState, chunks: &chunks)
      if visitState.visitedNodes >= visitState.maxNodes { return }
    }
  }

  private static func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success, let value else { return nil }
    guard let string = stringFromAXValue(value) else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func stringFromAXValue(_ value: CFTypeRef) -> String? {
    if let string = value as? String { return string }
    let typeID = CFGetTypeID(value)
    if typeID == CFStringGetTypeID() {
      return (value as! CFString) as String
    }
    if let attributed = value as? NSAttributedString { return attributed.string }
    return nil
  }

  private static func role(of element: AXUIElement) -> String? {
    copyStringAttribute(element, kAXRoleAttribute as CFString)
  }

  private static func collectChunks(
    from element: AXUIElement,
    depth: Int,
    maxDepth: Int,
    visitState: inout VisitState,
    chunks: inout [String]
  ) {
    guard depth <= maxDepth, visitState.visitedNodes < visitState.maxNodes else { return }
    visitState.visitedNodes += 1

    let textParts = textFromElement(element, includeValue: true, includeSelected: false)
    if let chunk = mergedChunk(from: textParts) {
      chunks.append(chunk)
    }

    guard depth < maxDepth else { return }

    let childArray = copyChildren(element)
    let limit = min(childArray.count, maxChildrenPerNode)
    for index in 0..<limit {
      collectChunks(
        from: childArray[index],
        depth: depth + 1,
        maxDepth: maxDepth,
        visitState: &visitState,
        chunks: &chunks
      )
      if visitState.visitedNodes >= visitState.maxNodes { return }
    }
  }

  private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
    var children: CFTypeRef?
    let childrenResult = AXUIElementCopyAttributeValue(
      element,
      kAXChildrenAttribute as CFString,
      &children
    )
    guard childrenResult == .success, let childArray = children as? [AXUIElement] else { return [] }
    return childArray
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
    var maxNodes: Int

    init(maxNodes: Int = ScreenContextCollector.maxNodesVisited) {
      self.maxNodes = maxNodes
    }
  }
}
