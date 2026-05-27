import Foundation

/// Repairs split or clipped OCR tokens using on-screen vocabulary (no app-specific blocklists).
public enum ScreenTermHealing {
  /// Max characters missing from the start of a vocabulary word when matching a clipped OCR token.
  public static let maxMissingPrefixLength = 3

  /// Tokens split across whitespace/punctuation in OCR (e.g. `st` + `ream` → `stream`).
  public static func mergedAdjacentTokens(in text: String) -> [String] {
    let pieces = lexicalPieces(in: text)
    guard pieces.count >= 2 else { return [] }

    var merged: [String] = []
    for index in 0..<(pieces.count - 1) {
      let left = pieces[index]
      let right = pieces[index + 1]
      let gapEnd = right.range.lowerBound
      let gapStart = left.range.upperBound
      guard isMergeableGap(text, from: gapStart, to: gapEnd) else { continue }
      guard left.string.count <= 4, right.string.count <= 4 else { continue }
      guard left.string.count <= 3 || right.string.count <= 3 else { continue }

      let gap = text[gapStart..<gapEnd]
      let combined = left.string + right.string
      guard combined.count >= ScreenTermFilter.minTokenLength,
        combined.count <= ScreenTermFilter.maxTokenLength,
        appearsAsMergedForm(combined, left: left.string, right: right.string, gap: gap, in: text)
      else { continue }
      merged.append(combined)
    }
    return merged
  }

  /// Maps a clipped token to a full anchor word when it matches a short missing prefix (e.g. `ranscription` → `transcription`).
  public static func anchorCompletion(for token: String, anchors: [String]) -> String? {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= ScreenTermFilter.minTokenLength else { return nil }
    let lower = trimmed.lowercased()

    for anchor in anchors {
      let anchorLower = anchor.lowercased()
      guard anchorLower.count > lower.count else { continue }
      let missing = anchorLower.count - lower.count
      guard missing <= maxMissingPrefixLength, anchorLower.hasSuffix(lower) else { continue }
      return anchor
    }
    return nil
  }

  /// True when `token` is a strict substring of an anchor and cannot be completed (interior OCR clip).
  public static func isInteriorFragment(_ token: String, anchors: [String]) -> Bool {
    if anchorCompletion(for: token, anchors: anchors) != nil { return false }

    let lower = token.lowercased()
    guard lower.count >= ScreenTermFilter.minTokenLength else { return true }

    for anchor in anchors {
      let anchorLower = anchor.lowercased()
      guard anchorLower.count > lower.count, anchorLower.contains(lower) else { continue }
      if anchorLower.hasSuffix(lower), anchorLower.count - lower.count <= maxMissingPrefixLength {
        return false
      }
      return true
    }
    return false
  }

  /// Single-token and merged adjacent tokens, with anchor completion applied when possible.
  public static func enrichedTokens(in text: String, anchors: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []

    func append(_ raw: String) {
      let canonical = anchorCompletion(for: raw, anchors: anchors) ?? raw
      guard ScreenTermFilter.appearsWithWordBoundaries(canonical, in: text) else { return }
      guard !ScreenTermFilter.isSteeringNoiseToken(canonical) else { return }
      let key = canonical.lowercased()
      guard !seen.contains(key) else { return }
      seen.insert(key)
      result.append(canonical)
    }

    for token in ScreenTermFilter.tokenize(text) {
      append(token)
    }
    for merged in mergedAdjacentTokens(in: text) {
      append(merged)
    }
    return result
  }

  public static func canonicalTerm(_ term: String, anchors: [String]) -> String {
    anchorCompletion(for: term, anchors: anchors) ?? term
  }

  // MARK: - Private

  private struct LexicalPiece {
    let string: String
    let range: Range<String.Index>
  }

  private static func lexicalPieces(in text: String) -> [LexicalPiece] {
    let pattern = #"[A-Za-z0-9][A-Za-z0-9\-_'/]*[A-Za-z0-9]|[A-Za-z0-9]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

    let nsRange = NSRange(text.startIndex..., in: text)
    var pieces: [LexicalPiece] = []
    regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
      guard let match, let range = Range(match.range, in: text) else { return }
      pieces.append(LexicalPiece(string: String(text[range]), range: range))
    }
    return pieces
  }

  private static func appearsAsMergedForm(
    _ combined: String,
    left: String,
    right: String,
    gap: Substring,
    in text: String
  ) -> Bool {
    if ScreenTermFilter.appearsWithWordBoundaries(combined, in: text) {
      return true
    }
    guard !gap.contains(where: \.isWhitespace) else { return false }
    let tight = left + gap + right
    return text.range(of: tight, options: .caseInsensitive) != nil
  }

  private static func isMergeableGap(_ text: String, from start: String.Index, to end: String.Index)
    -> Bool {
    guard start <= end else { return false }
    let gap = text[start..<end]
    guard !gap.contains(where: \.isWhitespace) else { return false }
    return gap.allSatisfy { character in
      !character.isLetter && !character.isNumber
    }
  }
}
