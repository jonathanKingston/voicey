import Foundation

/// Represents model readiness at runtime in a UI-framework agnostic way.
public enum ModelRuntimeStatus: Equatable, Sendable {
  case notDownloaded
  case loading
  case ready
  case failed(String)

  public var isReady: Bool {
    if case .ready = self { return true }
    return false
  }

  public var isLoading: Bool {
    if case .loading = self { return true }
    return false
  }
}
