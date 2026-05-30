# Single Instance Fail-Closed Behavior

## Status

Exploratory proposal.

## Summary

Voicey has a single-instance lock to prevent multiple app processes from registering the same
global shortcut. Some lock infrastructure failures currently return success, which means the app
can continue without actually proving it owns the lock.

## Evidence

- `VoiceySingleInstance.acquireLockOrQuit(...)` returns `true` if the Application Support
  directory cannot be created.
- The same method returns `true` if the lock file cannot be opened.
- A non-contention `flock` failure logs an error but still applies the file descriptor and
  returns `true`.
- Only `EWOULDBLOCK` and `EAGAIN` terminate the duplicate instance.

Relevant files:

- `Sources/Voicey/App/VoiceySingleInstance.swift`
- `Sources/Voicey/App/VoiceyApp.swift`
- `Sources/Voicey/App/AppDelegate.swift`

## Risks

- Two Voicey processes can both register global hotkeys if lock setup fails.
- Duplicate hotkey handling can start overlapping recordings or double-deliver text.
- Users get no clear remediation when lock infrastructure is broken.
- Returning success on unknown lock failure undermines the point of the guard.

## Proposed direction

Fail closed when Voicey cannot establish single-instance ownership. A deliberate environment
override can still support development workflows, but production should not silently continue
after lock infrastructure errors.

Possible implementation shape:

1. Split results into `.acquired`, `.alreadyRunning`, and `.lockUnavailable(error)`.
2. Terminate or run in a clearly degraded mode when the lock is unavailable.
3. Avoid registering global shortcuts unless the lock is acquired.
4. Show a user-facing alert with the lock path and remediation guidance.
5. Add injectable lock operations for tests.

## Acceptance criteria

- Directory, `open`, and non-contention `flock` failures do not silently continue as success.
- Duplicate-instance detection remains user-friendly.
- Development override remains explicit and documented.
- Global hotkey registration happens only when the instance lock is acquired or override is set.
- Tests cover lock acquisition, contention, and infrastructure failure.

## Validation plan

- Unit-test the lock decision logic using injected file and flock operations.
- On macOS, simulate lock contention and verify the second instance exits cleanly.
- On macOS, simulate lock infrastructure failure and verify no global hotkey is registered.
