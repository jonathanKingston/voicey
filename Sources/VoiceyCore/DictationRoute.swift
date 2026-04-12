import Foundation

public enum DictationRoute: Equatable, Sendable {
  case startDictation

  public static func parse(url: URL) -> DictationRoute? {
    guard url.scheme == VoiceyiOSConstants.appURLScheme else {
      return nil
    }

    guard url.host == "dictation" else {
      return nil
    }

    switch url.path {
    case "/start":
      return .startDictation
    default:
      return nil
    }
  }
}
