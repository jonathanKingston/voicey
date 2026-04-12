import UIKit
import VoiceyCore

final class KeyboardViewController: UIInputViewController {
  private let statusLabel = UILabel()
  private let requestButton = UIButton(type: .system)
  private let refreshButton = UIButton(type: .system)
  private let insertButton = UIButton(type: .system)

  private var store: SharedContainerStore?

  override func viewDidLoad() {
    super.viewDidLoad()
    configureUI()
    configureStore()
    refreshKeyboardState()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refreshKeyboardState()
  }

  private func configureUI() {
    view.backgroundColor = .systemBackground

    statusLabel.text = "Idle"
    statusLabel.numberOfLines = 2
    statusLabel.textAlignment = .center
    statusLabel.font = .preferredFont(forTextStyle: .footnote)

    requestButton.setTitle("Dictate", for: .normal)
    requestButton.addTarget(self, action: #selector(handleRequestTap), for: .touchUpInside)

    refreshButton.setTitle("Refresh", for: .normal)
    refreshButton.addTarget(self, action: #selector(handleRefreshTap), for: .touchUpInside)

    insertButton.setTitle("Insert Latest", for: .normal)
    insertButton.addTarget(self, action: #selector(handleInsertTap), for: .touchUpInside)

    let buttonStack = UIStackView(arrangedSubviews: [requestButton, refreshButton, insertButton])
    buttonStack.axis = .horizontal
    buttonStack.distribution = .fillEqually
    buttonStack.spacing = 8

    let rootStack = UIStackView(arrangedSubviews: [statusLabel, buttonStack])
    rootStack.axis = .vertical
    rootStack.spacing = 8
    rootStack.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(rootStack)
    NSLayoutConstraint.activate([
      rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
      rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
    ])
  }

  private func configureStore() {
    do {
      store = try SharedContainerStore()
    } catch {
      setStatus("App Group unavailable")
      requestButton.isEnabled = false
      insertButton.isEnabled = false
      refreshButton.isEnabled = false
    }
  }

  @objc
  private func handleRequestTap() {
    guard hasFullAccess else {
      setStatus("Enable Full Access in Settings")
      return
    }

    Task { @MainActor [weak self] in
      guard let self, let store else { return }
      do {
        let requestID = UUID().uuidString
        let request = DictationRequest(requestID: requestID)
        let keyboardState = KeyboardWorkflowState(
          isProcessing: true,
          lastSeenRequestID: requestID,
          lastInsertedRequestID: nil
        )

        try await store.saveRequest(request)
        try await store.saveKeyboardState(keyboardState)
        setStatus("Request created")
        openContainingApp()
      } catch {
        setStatus(error.localizedDescription)
      }
    }
  }

  @objc
  private func handleRefreshTap() {
    refreshKeyboardState()
  }

  @objc
  private func handleInsertTap() {
    Task { @MainActor [weak self] in
      guard let self, let store else { return }

      do {
        guard let result = try await store.loadResult() else {
          setStatus("No transcript ready")
          return
        }

        var keyboardState = try await store.loadKeyboardState() ?? KeyboardWorkflowState()
        if keyboardState.lastInsertedRequestID == result.requestID {
          setStatus("Latest transcript already inserted")
          return
        }

        textDocumentProxy.insertText(result.text)
        keyboardState = KeyboardWorkflowState(
          isProcessing: false,
          lastSeenRequestID: result.requestID,
          lastInsertedRequestID: result.requestID
        )
        try await store.saveKeyboardState(keyboardState)
        setStatus("Inserted transcript")
      } catch {
        setStatus("Insert failed")
      }
    }
  }

  private func refreshKeyboardState() {
    Task { @MainActor [weak self] in
      guard let self, let store else { return }
      do {
        try await store.purgeExpiredRequest()
        let request = try await store.loadRequest()
        let result = try await store.loadResult()

        if let request, request.status == .pending || request.status == .processing {
          setStatus("Request \(request.status.rawValue)")
        } else if let result {
          setStatus("Result ready")
          _ = result
        } else {
          setStatus("Idle")
        }
      } catch {
        setStatus("Refresh failed")
      }
    }
  }

  private func openContainingApp() {
    guard let appURL = URL(string: "\(VoiceyiOSConstants.appURLScheme)://dictation/start") else {
      return
    }
    extensionContext?.open(appURL, completionHandler: nil)
  }

  @MainActor
  private func setStatus(_ text: String) {
    statusLabel.text = text
  }
}
