import UIKit
import VoiceyCore

final class KeyboardViewController: UIInputViewController {
  private let statusLabel = UILabel()
  private let requestButton = UIButton(type: .system)
  private let refreshButton = UIButton(type: .system)
  private let insertButton = UIButton(type: .system)

  private var store: SharedContainerStore?
  private var currentUIState = KeyboardWorkflowPresentation(
    statusMessage: "Idle",
    canRequestDictation: true,
    canInsertLatest: false
  )

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
      applyUIState(
        KeyboardWorkflowPresentation(
          statusMessage: "App Group unavailable",
          canRequestDictation: false,
          canInsertLatest: false
        ))
      requestButton.isEnabled = false
      insertButton.isEnabled = false
      refreshButton.isEnabled = false
    }
  }

  @objc
  private func handleRequestTap() {
    guard currentUIState.canRequestDictation else {
      applyUIState(
        KeyboardWorkflowPresentation(
          statusMessage: "Enable Full Access in Settings",
          canRequestDictation: false,
          canInsertLatest: false
        ))
      return
    }

    Task { @MainActor [weak self] in
      guard let self, let store else { return }
      do {
        let requestID = UUID().uuidString
        let request = DictationRequest(requestID: requestID)
        try await store.saveRequest(request)
        _ = try await store.markKeyboardProcessing(requestID: requestID)
        applyUIState(
          KeyboardWorkflowPresentation(
            statusMessage: "Request created",
            canRequestDictation: false,
            canInsertLatest: false
          ))
        openContainingApp()
      } catch {
        applyUIState(
          KeyboardWorkflowPresentation(
            statusMessage: error.localizedDescription,
            canRequestDictation: hasFullAccess,
            canInsertLatest: false
          ))
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
        guard currentUIState.canInsertLatest else {
          if currentUIState.statusMessage == "Result ready" {
            applyUIState(
              KeyboardWorkflowPresentation(
                statusMessage: "No transcript ready",
                canRequestDictation: hasFullAccess,
                canInsertLatest: false
              ))
          } else {
            applyUIState(currentUIState)
          }
          return
        }

        guard let result = try await store.loadResult() else {
          applyUIState(
            KeyboardWorkflowPresentation(
              statusMessage: "No transcript ready",
              canRequestDictation: hasFullAccess,
              canInsertLatest: false
            ))
          return
        }

        textDocumentProxy.insertText(result.text)
        _ = try await store.markKeyboardInserted(requestID: result.requestID)
        let refreshedKeyboardState = try await store.loadKeyboardState()
        let refreshedState = KeyboardWorkflowResolver.resolve(
          hasFullAccess: hasFullAccess,
          request: try await store.loadRequest(),
          result: try await store.loadResult(),
          keyboardState: refreshedKeyboardState
        )
        applyUIState(refreshedState)
      } catch {
        applyUIState(
          KeyboardWorkflowPresentation(
            statusMessage: "Insert failed",
            canRequestDictation: hasFullAccess,
            canInsertLatest: false
          ))
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
        let keyboardState = try await store.loadKeyboardState()

        let state = KeyboardWorkflowResolver.resolve(
          hasFullAccess: hasFullAccess,
          request: request,
          result: result,
          keyboardState: keyboardState
        )
        applyUIState(state)
      } catch {
        applyUIState(
          KeyboardWorkflowPresentation(
            statusMessage: "Refresh failed",
            canRequestDictation: hasFullAccess,
            canInsertLatest: false
          ))
      }
    }
  }

  private func openContainingApp() {
    let route = "\(VoiceyiOSConstants.appURLScheme)://\(VoiceyiOSConstants.dictationRouteHost)\(VoiceyiOSConstants.dictationRouteStartPath)"
    guard let appURL = URL(string: route) else {
      return
    }
    extensionContext?.open(appURL, completionHandler: nil)
  }

  @MainActor
  private func setStatus(_ text: String) {
    statusLabel.text = text
  }

  @MainActor
  private func applyUIState(_ state: KeyboardWorkflowPresentation) {
    currentUIState = state
    setStatus(state.statusMessage)
    requestButton.isEnabled = state.canRequestDictation
    insertButton.isEnabled = state.canInsertLatest
    refreshButton.isEnabled = true
  }
}
