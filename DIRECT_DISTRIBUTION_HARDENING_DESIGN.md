# Direct Distribution Hardening Design

## Status

Draft design for the direct-distribution build of Voicey.

## Implementation status

Work already landed or in flight elsewhere — do not re-implement in this PR:

| Item | Status | Where |
| --- | --- | --- |
| Qwen HF listing + download moved out of main app | Done | PR #56 (`voicey-fetch` hardened contract) |
| Qwen fetch worker seatbelt profile + launch plumbing | Done | PR #56 (`Resources/Sandbox/VoiceyFetch.sb`) |
| Main app off Qwen HF tree API hot path | Done | PR #56 |

This PR covers the remaining direct-build hardening scope:

- enable App Sandbox on `VoiceyDirect` with Sparkle mach-lookup exceptions;
- remove Granite runtime PyPI bootstrap;
- consolidate Qwen cache paths under `Application Support/Voicey/Models/qwen3-speech`;
- design + evidence documentation.

When PR #56 merges, update `VoiceyFetch.sb` write rules to match the app-managed
Qwen cache under Application Support (PR #56's profile currently allows
`~/Library/Caches/qwen3-speech` only).

## Goals

- Preserve the current direct-build UX, especially auto-paste into arbitrary apps.
- Lock down network access as much as possible.
- Strongly constrain filesystem access for model download and Granite inference paths.
- Prefer Apple-supported primitives where they do not break the product.
- Use custom seatbelt only where it materially improves isolation.

## Non-goals

- Make the direct build acceptable for Mac App Store submission.
- Guarantee a pure Apple-supported solution for every direct-build feature.
- Build a kernel-level firewall replacement inside the app.

## Current constraints

### Paste compatibility

The direct build does more than copy to the clipboard:

- It activates the target app.
- It tries Accessibility-based paste actions.
- It falls back to synthetic `Cmd+V` keyboard events.
- Terminal/TUI targets prefer the keyboard path first.

This matters because direct-build auto-paste quality depends on CGEvent fallback for
the hardest targets. If App Sandbox breaks that path, the direct build loses one of
its key differentiators.

### Current network paths

The direct build intentionally needs outbound network for:

- Sparkle appcast/update traffic.
- Whisper model download.
- Qwen model download (via `voicey-fetch` helper; see PR #56).
- Granite model download.

Granite no longer bootstraps Python packages at runtime. That PyPI egress path is
disabled in this PR.

### Current filesystem paths

The code is already moving toward app-owned storage:

- Whisper models live under `Application Support/Voicey/Models`.
- Qwen models are now resolved under the app-managed models tree as well.
- Granite models live under the same app-managed models area.
- Granite inference uses temporary audio files in the process temp directory.

## Key question: can seatbelt lock down network access?

### Short answer

Yes, but only coarsely.

Seatbelt can be useful to:

- deny all networking for a process;
- allow broad outbound networking;
- allow localhost networking for a process.

Seatbelt is not sufficient to express:

- allow only `voicey.work`;
- allow only Hugging Face and its CDN;
- allow only HTTPS to a fixed host list;
- allow Sparkle but deny every other remote destination.

In practice, seatbelt is a process sandbox, not a domain-aware firewall.

### What "network unboxing" actually means here

Seatbelt can be used to give a process broad permission to use networking or to
deny it altogether. That is the useful part of seatbelt for this project.

However, "network unboxing" should not be interpreted as a granular firewall
primitive. On its own, seatbelt is not the mechanism that will answer questions
like:

- "Can this process only talk to `voicey.work`?"
- "Can this process talk to Hugging Face but not any other HTTPS destination?"
- "Can this process only reach a signed allowlist of CDN hosts?"

For those requirements, seatbelt must be combined with:

- process separation;
- application-level destination allowlisting; and optionally
- a localhost proxy that becomes the only seatbelt-allowed network peer.

## Key question: can Apple primitives solve this by themselves?

### App Sandbox

App Sandbox is the Apple-supported mechanism, but it is not enough for the direct
build if CGEvent-based paste fallback is required.

What App Sandbox is good at:

- filesystem containment;
- coarse network capability declarations;
- shipping a supported, notarizable sandboxed app;
- sandboxed XPC services with separate entitlements.

What App Sandbox does not give us:

- a host allowlist for outbound network;
- confidence that synthetic keyboard fallback remains usable in the direct build.

### ATS

ATS is still useful, but it is transport-hardening, not network allowlisting.

ATS can help enforce:

- HTTPS;
- TLS requirements;
- certificate policy.

ATS cannot express:

- only these model hosts;
- only this appcast host;
- deny every other domain.

### XPC services and helper bundles

These are the most important Apple-supported building blocks for tightening the
direct build without forcing the entire app into App Sandbox.

Useful patterns:

- bundled XPC services with their own entitlements;
- bundled helper executables launched with `Process`;
- Sparkle's existing helper/XPC structure.

The important idea is process separation:

- keep the UI/paste-sensitive process separate;
- move risky network or filesystem-heavy work into smaller helpers.

### Important Apple constraint: embedded helpers do not provide a breakout

Apple's embedded-helper guidance for sandboxed apps is specifically about running
an extra process *inside* the sandbox model, not bypassing it.

For a helper launched from a sandboxed app with sandbox inheritance:

- the helper target must enable `com.apple.security.app-sandbox`;
- the helper target must enable `com.apple.security.inherit`;
- and it must not carry additional App Sandbox entitlements beyond that inherited
  model.

That means an embedded command-line helper launched from a sandboxed app is not a
valid way to keep the host app sandboxed while letting the helper "break out" to
perform paste.

Likewise, a bundled XPC service in a sandboxed app is normally treated as another
sandboxed executable, not an unsandboxed exception target.

## Key question: can a tiny helper break paste out of a sandboxed app?

### Embedded helper in the app bundle

No, not in the simple Apple-supported embedded-helper model.

If the main app is sandboxed and the helper is just:

- a bundled command-line tool, or
- a bundled XPC service

then the helper is expected to participate in the sandbox model as well. That
does not create the "tiny unsandboxed paste broker" you want.

### Separately installed helper or daemon

Yes, but this is a different class of design.

For direct distribution, the realistic breakout pattern is:

- sandbox the main app if desired;
- install a separate helper/daemon outside the app bundle;
- communicate with that helper over XPC or another IPC channel;
- let that helper own the less-confined paste behavior.

This is conceptually closer to:

- `SMJobBless`; or
- a modern `SMAppService`-registered helper/daemon model

than it is to a small embedded bundle executable.

### User interaction and approval implications

This is the main product risk with the installed-helper approach.

In practice, Apple-supported installed helper paths usually introduce explicit user
friction:

- `SMJobBless`-style privileged helper installation typically requires an admin
  authorization prompt;
- `SMAppService`-managed agents/daemons typically introduce background-item
  registration and approval behavior;
- a separately installed helper changes install/update behavior even if the main UI
  tries to hide it.

That means the installed-helper approach is a bad fit for the requirement that the
UI and user workflow must not materially change.

### Trade-offs of the breakout-helper design

Pros:

- the main app can remain more tightly sandboxed;
- the breakout surface is narrow and explicit;
- the paste broker can be audited as a separate component.

Cons:

- helper install/update lifecycle becomes much more complex;
- signing and notarization become more complex;
- helper approval and background-item prompts may become user-visible;
- user trust/review burden increases for a background helper;
- you now have a local privileged or less-confined IPC boundary to secure;
- this is much heavier than a simple bundled helper.

## Design options

### Option A: sandbox the whole direct app

#### Pros

- most Apple-supported;
- simplest compliance story;
- Sparkle supports sandboxed integration.

#### Cons

- known regression risk for direct-build auto-paste;
- likely loss of terminal/TUI reliability because the keyboard fallback is the
  fragile part;
- still no host allowlist for outbound networking.

### Option B: do not sandbox the main direct app, isolate helpers aggressively

#### Pros

- preserves the best chance of full auto-paste compatibility;
- still lets us strongly constrain the riskiest code paths;
- gives us room to use both Apple primitives and seatbelt where each fits best.

#### Cons

- the main app remains the least confined process;
- requires more architecture work;
- network enforcement becomes a helper/process design problem, not an entitlement
  checkbox.

### Option C: custom seatbelt around the whole direct app

#### Pros

- stronger than doing nothing if it works;
- gives broad allow/deny control over networking and filesystem access.

#### Cons

- not the preferred Apple shipping model;
- still does not solve host allowlisting;
- high risk of breaking Accessibility, CGEvent posting, Sparkle, or other UI/system
  interactions in hard-to-debug ways;
- process-wide blast radius if the profile is too strict.

This is not the recommended first step.

### Option D: sandboxed host app plus installed paste broker helper

#### Pros

- keeps most of the app inside Apple's App Sandbox model;
- isolates the breakout behavior to one narrowly scoped helper;
- gives the clearest architectural boundary for paste-specific risk.

#### Cons

- requires an installed helper/daemon, not just a bundled executable;
- operationally the most complex option;
- likely introduces approval or authorization UX that conflicts with a zero-friction
  requirement;
- may still be fragile for Accessibility / CGEvent behavior;
- significantly raises implementation and support burden for direct distribution.

## Recommended architecture

### Chosen direction

If the project wants the strongest practical network control without changing the
direct-build UX, the preferred direction is:

- keep the main direct app outside whole-app App Sandbox;
- extract network-capable work into helpers;
- run those helpers under seatbelt;
- route helper egress through a localhost policy proxy when strict destination
  control is required.

This is the best fit for the current constraints.

### Recommendation

Use a mixed model:

- **main direct app:** remain outside App Sandbox unless the project is willing to
  accept an installed paste broker helper;
- **Sparkle:** keep current direct-build Sparkle integration;
- **model download:** move into a dedicated helper process;
- **Granite inference worker:** isolate further as its own helper process;
- **seatbelt:** apply to the helpers, not the main UI process.

This is the best balance between product requirements and containment.

### Why this wins over the Linux container option

Apple's Linux container technology is designed for Linux workloads running in
lightweight virtual machines on macOS. That makes it a poor fit for the parts of
Voicey that matter here:

- paste uses native macOS APIs like Accessibility, `NSWorkspace`, and CGEvent
  fallback;
- Sparkle is a native macOS updater integration;
- the direct-build UI process is a native AppKit process, not a Linux workload.

In other words, Linux containerization is interesting for isolated auxiliary
compute, but it is not a realistic solution for the network-constrained helper that
still needs tight integration with native macOS app behavior.

For this project, a seatbelted native helper plus localhost proxy is the more
direct, lower-risk architecture.

## Recommended process split

### 1. Main app (`VoiceyDirect.app`)

Responsibilities:

- menu bar UI;
- hotkeys;
- audio capture orchestration;
- clipboard handling;
- Accessibility interactions;
- CGEvent fallback paste path;
- invoking constrained helpers.

Security posture:

- no custom seatbelt initially;
- minimize direct networking in app code;
- do not add new general-purpose URL loading here.

### 2. Model download helper

Responsibilities:

- Whisper model download;
- Qwen model download (**done** for bundled Rust path via `voicey-fetch`; PR #56);
- Granite model download.

Security posture:

- run as a dedicated helper process;
- custom seatbelt profile or a sandboxed XPC service (**done** for `voicey-fetch`; PR #56);
- filesystem restricted to:
  - app-owned models directory;
  - temp directory;
  - read-only bundle resources;
- network restricted as far as seatbelt can support.

### 3. Granite inference helper

Responsibilities:

- Python runtime launch;
- Granite model loading;
- inference on temp audio files.

Security posture:

- dedicated helper process;
- separate profile from downloader helper;
- deny outbound network entirely during inference;
- filesystem limited to:
  - bundled Python runtime/dependencies;
  - Granite model directory;
  - temp directory;
  - IPC endpoint.

## How to lock down network as much as possible

### What is realistically enforceable

If the direct build must keep paste compatibility, the strongest practical plan is:

1. keep network-capable work out of the main app process;
2. run download-related helpers under seatbelt or sandboxed XPC;
3. bundle Granite Python dependencies so there is no PyPI path;
4. keep Sparkle as an explicit, separate allowed path;
5. add application-level host allowlisting inside the download helper;
6. optionally route helper egress through a localhost policy proxy if strict
   destination control is required.

### Why application-level allowlisting is still required

Because seatbelt cannot express a remote host allowlist, the helper itself must own
the destination policy.

The downloader helper should explicitly allow only:

- Sparkle appcast/update endpoints, if that helper owns update traffic;
- Hugging Face endpoints needed for model download;
- any CDN endpoints that are part of the signed model-download manifest.

Everything else should be rejected in code before a request is made.

### Strongest available design: localhost proxy model

If true host-level enforcement is required, the only practical design is:

- download helpers may connect only to `localhost`;
- a local policy proxy enforces the remote host allowlist;
- the proxy validates:
  - destination host;
  - HTTPS/TLS policy;
  - signed manifest metadata;
  - optional certificate pinning/public key checks.

This is the only design in this space that approximates "seatbelt-enforced network
allowlist" because the actual seatbelt rule becomes "localhost only."

### Recommended network-control stack

For the direct build, the recommended stack is:

1. native helper process for model download / network-capable work;
2. seatbelt profile that permits only localhost networking for that helper;
3. localhost policy proxy that:
   - enforces the remote destination allowlist,
   - enforces HTTPS/TLS policy,
   - validates signed manifests / pinned metadata where needed;
4. separate no-network helper profile for Granite inference;
5. bundled Granite dependencies to remove PyPI egress entirely.

This gives the closest practical approximation to a granular outbound firewall while
keeping the main app out of the blast radius.

### Trade-off

The localhost proxy design is the most secure, but also the most complex.

It should only be chosen if the project truly needs host-level enforcement beyond:

- signed updates;
- application-level allowlists;
- bundled Python/runtime dependencies.

## Filesystem hardening plan

### Main app

Reduce direct filesystem responsibilities over time:

- no arbitrary user path writes;
- no model download logic in the UI process;
- no Python bootstrap in the UI process.

### Download helper

Allow only:

- read-only access to bundle resources;
- read/write access to the models directory;
- read/write access to a temporary staging directory;
- IPC channel back to the main app.

Everything else should be denied.

### Granite inference helper

Allow only:

- read-only access to bundled Python/runtime assets;
- read-only access to Granite model files;
- read/write access to temp audio files;
- IPC channel back to the main app.

Outbound network should be denied entirely.

## Dependency strategy for Granite

### Preferred: bundle/vendor dependencies

Bundle these with the direct build:

- Python runtime, if needed;
- `mlx_audio`;
- `huggingface_hub`;
- `numpy`;
- any pinned transitive dependencies needed for Granite execution.

Benefits:

- removes PyPI network egress;
- makes the direct build reproducible;
- simplifies seatbelt profiles for the Granite worker;
- improves notarization and supportability.

### Fallback: pinned, hashed artifacts

If bundling is too much work immediately:

- download only pinned wheel artifacts;
- verify hashes before installation/use;
- fetch from a signed manifest;
- keep this logic in the constrained download helper only.

This is still weaker than bundling because it keeps a wider network path alive.

## Apple-supported pieces we should lean on

### Keep

- Sparkle for direct-build updates.
- Notarization and hardened runtime.
- XPC/helper separation where it fits.
- ATS for transport policy.

### Avoid overusing

- whole-app App Sandbox on the direct build, because it conflicts with the proven
  paste requirement;
- whole-app custom seatbelt first, because it is the highest-risk place to apply it.

## Rollout plan

### Phase 1: direct-build policy decision

- Decide that the direct build keeps paste reliability as the top-level constraint.
- Keep App Sandbox for the App Store build.
- Stop trying to force the main direct app under App Sandbox if it breaks paste.

### Phase 2: helper extraction

- Extract a dedicated model-download helper.
- Move Whisper and Qwen download logic out of the main process.
  - **Qwen:** done via `voicey-fetch` (PR #56).
  - **Whisper / Granite:** still in main process.
- Keep Granite download in the helper too.

### Phase 3: Granite packaging

- Bundle Granite Python dependencies.
- Remove "install it yourself" as the desired steady state for direct builds.
- **Partial:** runtime PyPI bootstrap removed in this PR; bundling still open.

### Phase 4: seatbelt helper confinement

- Apply a custom seatbelt profile to the download helper.
  - **Qwen fetch worker:** done (PR #56).
- Apply a stricter "no network" profile to the Granite inference helper.

### Phase 5: optional strict network control

- Add a localhost policy proxy only if host-level egress control is still required.
- Restrict the download helper to localhost-only networking.

## Final recommendation

For the direct build:

- **do not rely on App Sandbox for the main app process** if auto-paste fidelity is a
  hard requirement;
- **do not expect seatbelt alone to provide host-level network allowlisting**;
- **use seatbelt on helper processes** to confine model download and Granite work;
- **bundle Granite dependencies** to remove PyPI egress;
- **treat localhost proxying as the only serious option** if strict remote-host
  enforcement is mandatory.

If the project is willing to pay the complexity cost of a separate installed helper,
there is an alternate path:

- keep the host app sandboxed;
- move paste into a dedicated broker helper outside the host sandbox;
- keep downloads/inference in constrained helpers;
- and secure the IPC boundary tightly.

That is the only realistic way to have "everything else sandboxed, but paste breaks
out" without depending on undefined behavior from a bundled helper.

## Reference points for validation

Useful external references to validate the claims in this design:

- Apple App Sandbox entitlement reference, especially `network.client`,
  `app-sandbox`, and `inherit`.
- Apple guidance for embedding a command-line tool in a sandboxed app, which shows
  the helper inheriting sandbox constraints rather than escaping them.
- Apple QA1773, which states that Mach-O executables included in a sandboxed app
  bundle must themselves be sandboxed.
- Apple helper-tool guidance such as `SMJobBless`, which represents the separate
  installed-helper model rather than a bundled helper breakout.

In other words:

- Apple primitives are best for the App Store build and for helper/XPC structure.
- Seatbelt is best as an extra confinement tool for direct-build helpers.
- Neither App Sandbox nor seatbelt alone can express the full direct-build network
  policy you want without process separation and application-level policy.
