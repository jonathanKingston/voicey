import XCTest

@testable import VoiceyCore

final class PasteAttemptTests: XCTestCase {
  func testFocusedWebAreaDescendsToTextboxInsteadOfReturningContainer() {
    let textbox = SearchNode(role: "AXTextArea", focused: true)
    let webArea = SearchNode(role: "AXWebArea", focused: true, children: [textbox])
    XCTAssertTrue(findInput(webArea) === textbox)
  }

  func testSearchSkipsUnfocusedFieldsAndFocusedGroups() {
    let textbox = SearchNode(role: "AXTextField", focused: true)
    let root = SearchNode(role: "AXGroup", focused: true, children: [
      SearchNode(role: "AXTextField"), textbox
    ])
    XCTAssertTrue(findInput(root) === textbox)
    XCTAssertNil(findInput(SearchNode(role: "AXWebArea", focused: true)))
  }

  func testSearchBudgetStopsCycles() {
    let root = SearchNode(role: "AXGroup")
    root.children = [root]
    XCTAssertNil(findInput(root))
    root.children = []
  }

  private func findInput(_ root: SearchNode) -> SearchNode? {
    FocusedTextInputSearch.find(
      in: root, role: { $0.role }, isFocused: { $0.focused }, children: { $0.children }
    )
  }

  func testExpectedInsertionPreservesDraftAndUsesUTF16Offsets() {
    let before = PasteTextSnapshot(value: "🦊 draft\nend", selection: NSRange(location: 3, length: 5))
    XCTAssertEqual(
      before.inserting("hello 🌍\n"),
      PasteTextSnapshot(value: "🦊 hello 🌍\n\nend", selection: NSRange(location: 12, length: 0))
    )
  }

  func testEmptyAndCaretInsertionPreserveSurroundingsAndChipMarker() {
    XCTAssertEqual(
      PasteTextSnapshot(value: "", selection: NSRange(location: 0, length: 0)).inserting("hello"),
      PasteTextSnapshot(value: "hello", selection: NSRange(location: 5, length: 0))
    )
    XCTAssertEqual(
      PasteTextSnapshot(value: "a\u{FFFC}b", selection: NSRange(location: 2, length: 0)).inserting("🌍"),
      PasteTextSnapshot(value: "a\u{FFFC}🌍b", selection: NSRange(location: 4, length: 0))
    )
  }

  func testInvalidSelectionCannotConfirm() {
    for selection in [NSRange(location: NSNotFound, length: 0), NSRange(location: 4, length: 0),
                      NSRange(location: 1, length: 4)] {
      XCTAssertNil(PasteTextSnapshot(value: "abc", selection: selection).inserting("hello"))
    }
  }

  @MainActor
  func testDispatchSuccessWithUnchangedValueIsUnconfirmedAndNeverRetried() async {
    let environment = FakePasteEnvironment()
    let outcome = await PasteAttempt.perform(text: "hello", environment: environment, observationLimit: 3)
    XCTAssertEqual(outcome, .unconfirmed)
    XCTAssertEqual(environment.postCount, 1)
  }

  @MainActor
  func testDelayedExactTransitionConfirms() async {
    let environment = FakePasteEnvironment()
    environment.after = environment.before?.inserting("hello")
    environment.changeAtObservation = 2
    let outcome = await PasteAttempt.perform(text: "hello", environment: environment)
    XCTAssertEqual(outcome, .confirmed)
    XCTAssertEqual(environment.postCount, 1)
    XCTAssertEqual(environment.observations, 2)
  }

  @MainActor
  func testMissingAXObservationStillDispatchesOnlyOnce() async {
    let environment = FakePasteEnvironment()
    environment.before = nil
    let outcome = await PasteAttempt.perform(text: "hello", environment: environment, observationLimit: 2)
    XCTAssertEqual(outcome, .unconfirmed)
    XCTAssertEqual(environment.postCount, 1)
  }

  @MainActor
  func testInactiveTargetDoesNotDispatch() async {
    let environment = FakePasteEnvironment()
    environment.targetIsActive = false
    let outcome = await PasteAttempt.perform(text: "hello", environment: environment)
    XCTAssertEqual(outcome, .notAttempted)
    XCTAssertEqual(environment.postCount, 0)
  }

  @MainActor
  func testFocusLossAfterDispatchIsAmbiguousWithoutRetry() async {
    let environment = FakePasteEnvironment()
    environment.loseFocus = true
    let outcome = await PasteAttempt.perform(text: "hello", environment: environment)
    XCTAssertEqual(outcome, .unconfirmed)
    XCTAssertEqual(environment.postCount, 1)
  }

  @MainActor
  func testEventConstructionFailureDoesNotClaimDelivery() async {
    let environment = FakePasteEnvironment()
    environment.canPost = false
    let outcome = await PasteAttempt.perform(text: "hello", environment: environment)
    XCTAssertEqual(outcome, .notAttempted)
  }

  @MainActor
  func testWrongTextOrCaretCannotConfirm() async {
    for after in [
      PasteTextSnapshot(value: "hellohello", selection: NSRange(location: 10, length: 0)),
      PasteTextSnapshot(value: "hello", selection: NSRange(location: 0, length: 0))
    ] {
      let environment = FakePasteEnvironment()
      environment.after = after
      let outcome = await PasteAttempt.perform(text: "hello", environment: environment, observationLimit: 2)
      XCTAssertEqual(outcome, .unconfirmed)
      XCTAssertEqual(environment.postCount, 1)
    }
  }
}

private final class SearchNode {
  let role: String
  let focused: Bool
  var children: [SearchNode]

  init(role: String, focused: Bool = false, children: [SearchNode] = []) {
    self.role = role
    self.focused = focused
    self.children = children
  }
}

@MainActor
private final class FakePasteEnvironment: PasteAttemptEnvironment {
  var targetIsActive = true
  var before: PasteTextSnapshot? = PasteTextSnapshot(value: "", selection: NSRange(location: 0, length: 0))
  var after: PasteTextSnapshot?
  var postCount = 0
  var observations = 0
  var changeAtObservation = 1
  var loseFocus = false
  var canPost = true

  func snapshot() -> PasteTextSnapshot? {
    observations >= changeAtObservation ? (after ?? before) : before
  }

  func postPaste() -> Bool {
    postCount += 1
    return canPost
  }

  func waitForObservation() async {
    observations += 1
    if loseFocus { targetIsActive = false }
  }
}
