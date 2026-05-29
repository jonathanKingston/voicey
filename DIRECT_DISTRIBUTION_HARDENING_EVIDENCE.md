# Direct Distribution Hardening Evidence

This note captures the specific external references that back the main design
constraints discussed in `DIRECT_DISTRIBUTION_HARDENING_DESIGN.md`.

## 1. Evidence that `SMJobBless` introduces user/admin authorization UI

### Apple `SMJobBless` sample Read Me

Source:

- <https://developer.apple.com/library/archive/samplecode/SMJobBless/Listings/ReadMe_txt.html>

Relevant excerpts:

- "Once you run the sample you'll be prompted for an admin user name and password."
- "Requiring the user to authorize the privileged helper tool only once the first
  time it's used."

Interpretation:

- The canonical Apple sample explicitly describes an admin username/password prompt.
- This is direct evidence that the installed-helper path is not a zero-friction
  background mechanism.

### Apple `SMJobBless` API reference

Source:

- <https://developer.apple.com/documentation/servicemanagement/smjobbless(_:_:_:_:)>

Relevant excerpts:

- The API requires: "An authorization reference containing the
  `kSMRightBlessPrivilegedHelper` right."
- The function installs a privileged executable as a `launchd` job.

Interpretation:

- Even before looking at the sample UI, the API contract itself is an
  authorization-flow API, not a silent helper-registration primitive.

## 2. Evidence that embedded helpers in a sandboxed app do not provide breakout

### Apple embedded helper tool guidance

Source:

- <https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app?changes=la>

Relevant excerpts:

- The helper tool target should add both App Sandbox and Hardened Runtime.
- The helper tool should include `com.apple.security.app-sandbox` and
  `com.apple.security.inherit`.
- "Adding other entitlements to the tool can cause problems."

Interpretation:

- Apple’s bundled-helper model is about inherited sandbox participation, not
  "sandboxed host, unsandboxed helper breakout."

### Apple QA1773

Source:

- <https://developer.apple.com/library/archive/qa/qa1773/_index.html>

Relevant excerpts:

- "Make sure you have enabled sandboxing on all Mach-O executables included in your
  application's bundle."
- "Every Mach-O executable must have an entitlements file, and request the
  `com.apple.security.app-sandbox` entitlement."

Interpretation:

- This reinforces that bundled executables are expected to be sandboxed too.

## 2b. Evidence for the nearest adjacent helper direction: `SMAppService`

### Apple `SMAppService` overview

Source:

- <https://developer.apple.com/documentation/servicemanagement/smappservice>

Relevant excerpts:

- `SMAppService` controls helper executables that live inside the app’s main bundle.
- `register()` is documented as: "Registers the service so it can begin launching
  subject to user approval."
- Apple exposes `openSystemSettingsLoginItems()`, which is an explicit indicator
  that approval may require user action in System Settings.

Interpretation:

- This is the most relevant adjacent pattern to `SMJobBless` for modern macOS.
- It is not a silent "install and run forever" path.

### Apple `SMAppService.register()`

Source:

- <https://developer.apple.com/documentation/servicemanagement/smappservice/register()>

Relevant excerpts:

- "`register()` ... can begin launching subject to user approval."
- For `LaunchDaemon`: "the system won’t bootstrap the LaunchDaemon until an admin
  approves the LaunchDaemon in System Preferences."
- "If the service isn’t approved by the user, this method returns
  `kSMErrorLaunchDeniedByUser`."

Interpretation:

- `SMAppService` is similar in spirit to `SMJobBless` in that it still introduces an
  approval boundary.
- While the UX is different from an admin-password prompt, it is still not a
  zero-friction breakout-helper mechanism.

## 3. Evidence for seatbelt network limitations

### Seatbelt host filtering limitation

Source:

- <https://security.stackexchange.com/questions/133624/native-os-x-sandbox-profile-to-control-network-access-ip-host-based>

Relevant excerpts:

- Attempting host filtering yields: "host must be * or localhost in network
  address"
- Reverse-engineered sandbox documentation is quoted as:
  "[network*] ... has no support for IP filtering, it must be localhost or *"

Interpretation:

- This is the clearest concrete evidence that seatbelt is not a per-host outbound
  firewall primitive.

### Seatbelt documentation from `nono`

Source:

- <https://docs.nono.sh/docs/cli/internals/seatbelt>

Relevant excerpts:

- "Seatbelt supports filtering by protocol (TCP/UDP), direction
  (inbound/outbound), and even IP address via `remote ip` filters. However, it does
  not provide per-hostname or per-domain filtering."
- "For now, nono uses binary network control (all or nothing)."

Interpretation:

- Modern third-party seatbelt tooling documents the same practical constraint:
  seatbelt is useful for coarse network control, but not domain allowlisting.

## 3b. Evidence that the Linux container option is not a good fit here

### Apple containerization scope

Sources:

- Apple open-source `container` / `containerization` documentation and technical
  overview.

Relevant excerpts from the retrieved material:

- Apple's container tooling is for "running Linux containers on macOS."
- The architecture uses lightweight virtual machines for each container.
- It is framed around OCI images, Linux runtime management, and VM-backed
  isolation.

Interpretation:

- This technology is aimed at Linux workloads, not native macOS helper processes.
- It is not a direct answer for native AppKit / Accessibility / CGEvent / Sparkle
  integration.
- For Voicey's direct build, the Linux container route is less suitable than a
  native helper plus seatbelt/proxy design.

## 4. Practical conclusion supported by the evidence

The combined evidence supports these claims:

- `SMJobBless` is not silent; it is tied to authorization flow and Apple’s own
  sample shows an admin-password prompt.
- `SMAppService` is the closest modern alternative, but it still launches helpers
  subject to user approval and may require admin/user action in System Settings.
- A bundled helper in a sandboxed app is expected to be sandboxed/inherited, not a
  built-in breakout path.
- Seatbelt can be used for coarse network confinement, but not for a true
  destination allowlist like "only Sparkle and Hugging Face."
- Apple's Linux container technology is for Linux workloads on macOS, not a clean
  substitute for native macOS helper confinement in this app.

That is why the main design doc recommends either:

- keeping the direct UI process outside whole-app App Sandbox and confining helper
  processes; or
- accepting the significant UX/operational cost of a separate installed helper if a
  true sandbox breakout is still required.

## 5. Evidence for "last ditch" sandbox-preserving paste alternatives

### A. Accessibility-first paste remains the main sandbox-compatible path

Current repo evidence:

- `AccessibilityPaster` already tries `AXPaste`, selected-text replacement, cursor
  insertion, direct value replacement, and only then falls back to CGEvent.
- `OutputManager` explicitly prefers keyboard simulation first for terminal/TUI
  targets because those are the hardest cases.

Interpretation:

- The obvious sandbox-compatible route is already implemented in the product:
  Accessibility-based insertion.
- The remaining gap is not lack of API coverage; it is reliability across difficult
  targets.

### B. CGEvent is still the hard stop for a sandboxed app

Sources:

- Apple discussion / App Sandbox wording surfaced via Apple Developer Forums and QA
  search results.

Relevant excerpt from the retrieved material:

- "You cannot sandbox an app that controls another app. Posting keyboard or mouse
  events using functions like CGEventPost offers a way to circumvent this
  restriction, and is therefore not allowed from a sandboxed app."

Interpretation:

- The terminal/TUI fallback path is exactly the part that conflicts with the
  sandbox model.
- This is the biggest reason the direct build does not have an obvious
  sandbox-preserving paste solution.

### C. `NSUserAppleScriptTask` is not a clean reliable replacement

Sources:

- Research results for `NSUserAppleScriptTask` and Apple sandbox automation.

What the research suggests:

- `NSUserAppleScriptTask` is the sandbox-compatible way to run user scripts outside
  the app sandbox.
- However, it is still AppleScript-based automation of other apps, not a
  first-class paste API.
- It depends on script files and automation behavior rather than giving a new
  guaranteed text-insertion primitive.

Interpretation:

- This is interesting as a fallback experiment, but not strong enough to replace
  the current direct-build paste path with confidence.

### D. `NSPerformService` / Services are not a reliable escape hatch

Sources:

- Research results around `NSPerformService` and service invocation behavior.

What the research suggests:

- Services do not magically gain access to the frontmost app's selected text when
  invoked from a background app.
- They are not a dependable cross-app text injection primitive for this use case.

Interpretation:

- Services are not the missing "music playing hack" equivalent for paste.

### E. No convincing new private-framework analogue was found

What the research suggests:

- Media control hacks are special because they rely on media-specific private/system
  interfaces, not a general-purpose "write text into another app" primitive.
- No comparable modern Apple-supported or widely adopted private framework was found
  that provides reliable paste into arbitrary apps while preserving sandboxing.

Interpretation:

- There is no strong evidence of a newer paste hack that changes the basic
  conclusion.

### Practical research conclusion

After reviewing the current implementation and external references, the realistic
paste options still reduce to:

- Accessibility-based insertion for the cases where it works;
- CGEvent-style keyboard fallback for the cases where it does not.

No newly researched option clearly provides:

- broad reliability across native apps, Electron apps, and terminals;
- preserved App Sandbox for the host app; and
- no new user-visible workflow or approval burden.
