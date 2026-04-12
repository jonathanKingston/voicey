import Foundation

public enum SharedContainerStoreError: LocalizedError {
  case appGroupUnavailable(String)
  case concurrentRequestNotAllowed
  case invalidRequestText

  public var errorDescription: String? {
    switch self {
    case .appGroupUnavailable(let identifier):
      return "Unable to access App Group container: \(identifier)"
    case .concurrentRequestNotAllowed:
      return "A dictation request is already in flight."
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

  public func saveRequest(_ request: DictationRequest) throws {
    if let existing = try loadRequest(),
      existing.status == .pending || existing.status == .processing {
      throw SharedContainerStoreError.concurrentRequestNotAllowed
    }
    try write(request, as: .request)
  }

  public func saveResult(_ result: DictationResult) throws {
    guard result.text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else {
      throw SharedContainerStoreError.invalidRequestText
    }
    try write(result, as: .result)
  }

  public func saveKeyboardState(_ state: KeyboardWorkflowState) throws {
    try write(state, as: .keyboardState)
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

  private func saveRequestForce(_ request: DictationRequest) throws {
    try write(request, as: .request)
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
