import Foundation

public enum SharedContainerStoreError: LocalizedError {
  case appGroupUnavailable(String)
  case concurrentRequestNotAllowed
  case requestNotFound
  case requestIdentifierMismatch(expected: String, found: String)
  case invalidRequestTransition(from: DictationRequestStatus, to: DictationRequestStatus)
  case invalidRequestText

  public var errorDescription: String? {
    switch self {
    case .appGroupUnavailable(let identifier):
      return "Unable to access App Group container: \(identifier)"
    case .concurrentRequestNotAllowed:
      return "A dictation request is already in flight."
    case .requestNotFound:
      return "No request exists for this transition."
    case .requestIdentifierMismatch(let expected, let found):
      return "Request identifier mismatch. Expected \(expected), found \(found)."
    case .invalidRequestTransition(let from, let to):
      return "Invalid request transition from \(from.rawValue) to \(to.rawValue)."
    case .invalidRequestText:
      return "Dictation text is empty."
    }
  }
}

public actor SharedContainerStore {
  private let fileManager: FileManager
  private let baseDirectory: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(
    appGroupIdentifier: String = VoiceyiOSConstants.appGroupIdentifier,
    fileManager: FileManager = .default
  ) throws {
    self.fileManager = fileManager
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()

    guard let containerURL = fileManager.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    else {
      throw SharedContainerStoreError.appGroupUnavailable(appGroupIdentifier)
    }

    self.baseDirectory = containerURL.appendingPathComponent("dictation-shared", isDirectory: true)
    if !fileManager.fileExists(atPath: baseDirectory.path) {
      try fileManager.createDirectory(
        at: baseDirectory,
        withIntermediateDirectories: true
      )
    }
  }

  public init(
    baseDirectory: URL,
    fileManager: FileManager = .default
  ) throws {
    self.fileManager = fileManager
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    self.baseDirectory = baseDirectory

    if !fileManager.fileExists(atPath: baseDirectory.path) {
      try fileManager.createDirectory(
        at: baseDirectory,
        withIntermediateDirectories: true
      )
    }
  }

  public func saveRequest(_ request: DictationRequest) throws {
    if let existing = try loadRequest() {
      let hasInFlightRequest = existing.status == .pending || existing.status == .processing
      let isSameRequest = existing.requestID == request.requestID

      if hasInFlightRequest && !isSameRequest {
        throw SharedContainerStoreError.concurrentRequestNotAllowed
      }
    }
    try write(request, as: .request)
  }

  public func saveResult(_ result: DictationResult) throws {
    let hasTextPayload = result.text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
    guard hasTextPayload || result.error != nil else {
      throw SharedContainerStoreError.invalidRequestText
    }
    try write(result, as: .result)
  }

  public func saveKeyboardState(_ state: KeyboardWorkflowState) throws {
    try write(state, as: .keyboardState)
  }

  @discardableResult
  public func markKeyboardProcessing(requestID: String) throws -> KeyboardWorkflowState {
    let existing = try loadKeyboardState()
    let updated = KeyboardWorkflowState(
      isProcessing: true,
      lastSeenRequestID: requestID,
      lastInsertedRequestID: existing?.lastInsertedRequestID
    )
    try saveKeyboardState(updated)
    return updated
  }

  @discardableResult
  public func markKeyboardIdle(lastSeenRequestID: String?) throws -> KeyboardWorkflowState {
    let existing = try loadKeyboardState()
    let updated = KeyboardWorkflowState(
      isProcessing: false,
      lastSeenRequestID: lastSeenRequestID ?? existing?.lastSeenRequestID,
      lastInsertedRequestID: existing?.lastInsertedRequestID
    )
    try saveKeyboardState(updated)
    return updated
  }

  @discardableResult
  public func markKeyboardInserted(requestID: String) throws -> KeyboardWorkflowState {
    let updated = KeyboardWorkflowState(
      isProcessing: false,
      lastSeenRequestID: requestID,
      lastInsertedRequestID: requestID
    )
    try saveKeyboardState(updated)
    return updated
  }

  public func loadRequest() throws -> DictationRequest? {
    try read(DictationRequest.self, from: .request)
  }

  public func loadResult() throws -> DictationResult? {
    try read(DictationResult.self, from: .result)
  }

  public func loadKeyboardState() throws -> KeyboardWorkflowState? {
    try read(KeyboardWorkflowState.self, from: .keyboardState)
  }

  public func clearAllRecords() throws {
    for record in DictationSharedRecord.allCases {
      let fileURL = url(for: record)
      if fileManager.fileExists(atPath: fileURL.path) {
        try fileManager.removeItem(at: fileURL)
      }
    }
  }

  public func purgeExpiredRequest(
    now: Date = Date(),
    timeout: TimeInterval = VoiceyiOSConstants.dictationRequestTimeoutSeconds
  ) throws {
    guard let request = try loadRequest() else {
      return
    }

    guard now.timeIntervalSince(request.createdAt) >= timeout else {
      return
    }

    let cancelled = DictationRequest(
      requestID: request.requestID,
      createdAt: request.createdAt,
      source: request.source,
      status: .cancelled
    )
    try saveRequestForce(cancelled)
  }

  @discardableResult
  public func markRequestProcessing(requestID: String) throws -> DictationRequest {
    try updateRequest(requestID: requestID, to: .processing)
  }

  public func markRequestCompleted(
    requestID: String,
    text: String,
    language: String = "auto",
    model: String = "unknown"
  ) throws {
    let updatedRequest = try updateRequest(requestID: requestID, to: .completed)
    let result = DictationResult(
      requestID: requestID,
      text: text,
      language: language,
      model: model
    )
    try saveResult(result)
    try saveRequestForce(updatedRequest)
  }

  public func markRequestFailed(
    requestID: String,
    errorMessage: String,
    language: String = "auto",
    model: String = "unknown"
  ) throws {
    let updatedRequest = try updateRequest(requestID: requestID, to: .failed)
    let result = DictationResult(
      requestID: requestID,
      text: "",
      language: language,
      model: model,
      error: errorMessage
    )
    try saveResult(result)
    try saveRequestForce(updatedRequest)
  }

  private func saveRequestForce(_ request: DictationRequest) throws {
    try write(request, as: .request)
  }

  private func updateRequest(
    requestID: String,
    to nextStatus: DictationRequestStatus
  ) throws -> DictationRequest {
    guard let request = try loadRequest() else {
      throw SharedContainerStoreError.requestNotFound
    }
    guard request.requestID == requestID else {
      throw SharedContainerStoreError.requestIdentifierMismatch(
        expected: requestID,
        found: request.requestID
      )
    }

    guard isValidTransition(from: request.status, to: nextStatus) else {
      throw SharedContainerStoreError.invalidRequestTransition(from: request.status, to: nextStatus)
    }

    let updated = DictationRequest(
      requestID: request.requestID,
      createdAt: request.createdAt,
      source: request.source,
      status: nextStatus
    )
    try saveRequestForce(updated)
    return updated
  }

  private func isValidTransition(from current: DictationRequestStatus, to next: DictationRequestStatus)
    -> Bool
  {
    switch (current, next) {
    case (.pending, .processing), (.pending, .completed), (.pending, .failed), (.pending, .cancelled),
      (.processing, .completed), (.processing, .failed), (.processing, .cancelled):
      return true
    case let (lhs, rhs) where lhs == rhs:
      return true
    default:
      return false
    }
  }

  private func write<T: Codable>(_ value: T, as record: DictationSharedRecord) throws {
    let targetURL = url(for: record)
    let tempURL = targetURL.deletingLastPathComponent()
      .appendingPathComponent("\(record.rawValue).tmp")

    let data = try encoder.encode(value)
    try data.write(to: tempURL, options: .atomic)

    if fileManager.fileExists(atPath: targetURL.path) {
      try fileManager.removeItem(at: targetURL)
    }
    try fileManager.moveItem(at: tempURL, to: targetURL)
  }

  private func read<T: Decodable>(_ type: T.Type, from record: DictationSharedRecord) throws -> T? {
    let fileURL = url(for: record)
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return nil
    }
    let data = try Data(contentsOf: fileURL)
    return try decoder.decode(type, from: data)
  }

  private func url(for record: DictationSharedRecord) -> URL {
    baseDirectory.appendingPathComponent("\(record.rawValue).json")
  }
}
