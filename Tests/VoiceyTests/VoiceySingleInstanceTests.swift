import XCTest

@testable import Voicey

final class VoiceySingleInstanceTests: XCTestCase {
  func testEvaluateLockOutcomeAllowsDevelopmentOverride() {
    XCTAssertEqual(
      VoiceySingleInstance.evaluateLockOutcome(
        allowMultipleInstances: true,
        directoryCreationFailed: true,
        fileDescriptor: -1,
        flockReturnValue: -1,
        lockErrno: EPERM
      ),
      .multipleInstancesAllowed
    )
  }

  func testEvaluateLockOutcomeFailsClosedOnDirectoryError() {
    XCTAssertEqual(
      VoiceySingleInstance.evaluateLockOutcome(
        allowMultipleInstances: false,
        directoryCreationFailed: true,
        fileDescriptor: 3,
        flockReturnValue: 0,
        lockErrno: 0
      ),
      .unavailable(.directoryCreationFailed)
    )
  }

  func testEvaluateLockOutcomeFailsClosedOnOpenFailure() {
    XCTAssertEqual(
      VoiceySingleInstance.evaluateLockOutcome(
        allowMultipleInstances: false,
        directoryCreationFailed: false,
        fileDescriptor: -1,
        flockReturnValue: -1,
        lockErrno: ENOENT
      ),
      .unavailable(.lockOpenFailed)
    )
  }

  func testEvaluateLockOutcomeDetectsContention() {
    XCTAssertEqual(
      VoiceySingleInstance.evaluateLockOutcome(
        allowMultipleInstances: false,
        directoryCreationFailed: false,
        fileDescriptor: 3,
        flockReturnValue: -1,
        lockErrno: EWOULDBLOCK
      ),
      .alreadyRunning
    )
    XCTAssertEqual(
      VoiceySingleInstance.evaluateLockOutcome(
        allowMultipleInstances: false,
        directoryCreationFailed: false,
        fileDescriptor: 3,
        flockReturnValue: -1,
        lockErrno: EAGAIN
      ),
      .alreadyRunning
    )
  }

  func testEvaluateLockOutcomeFailsClosedOnUnexpectedFlockError() {
    XCTAssertEqual(
      VoiceySingleInstance.evaluateLockOutcome(
        allowMultipleInstances: false,
        directoryCreationFailed: false,
        fileDescriptor: 3,
        flockReturnValue: -1,
        lockErrno: EPERM
      ),
      .unavailable(.flockFailed(errno: EPERM))
    )
  }

  func testEvaluateLockOutcomeAcquiresOnSuccess() {
    XCTAssertEqual(
      VoiceySingleInstance.evaluateLockOutcome(
        allowMultipleInstances: false,
        directoryCreationFailed: false,
        fileDescriptor: 3,
        flockReturnValue: 0,
        lockErrno: 0
      ),
      .acquired
    )
  }

  func testAcquireLockAppliesDescriptorWhenAcquired() {
    var appliedFD: Int32 = -1
    let operations = SingleInstanceLockOperations(
      createLockDirectory: {},
      openLockFile: { 7 },
      lockFilePath: { "/tmp/voicey-test.lock" },
      tryExclusiveLock: { _ in 0 },
      currentErrno: { 0 }
    )

    let result = VoiceySingleInstance.acquireLock(operations: operations) { fd in
      appliedFD = fd
    }

    XCTAssertEqual(result, .acquired)
    XCTAssertEqual(appliedFD, 7)
  }

  func testAcquireLockDoesNotApplyDescriptorWhenUnavailable() {
    var appliedFD: Int32 = -1
    let operations = SingleInstanceLockOperations(
      createLockDirectory: { throw NSError(domain: "test", code: 1) },
      openLockFile: { -1 },
      lockFilePath: { "/tmp/voicey-test.lock" },
      tryExclusiveLock: { _ in -1 },
      currentErrno: { EPERM }
    )

    let result = VoiceySingleInstance.acquireLock(operations: operations) { fd in
      appliedFD = fd
    }

    XCTAssertEqual(result, .unavailable(.directoryCreationFailed))
    XCTAssertEqual(appliedFD, -1)
  }
}
