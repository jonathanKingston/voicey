import Foundation

#if VOICEY_DIRECT_DISTRIBUTION || VOICEY_MEDIA_REMOTE_PROBE

  /// Uses `/usr/bin/perl` plus bundled [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
  /// so MediaRemote runs under a system binary’s entitlements; Voicey reads JSON from stdout.
  ///
  /// **Currently unused:** `MediaRemotePlaybackProbe` uses `MediaRemoteJXAAdapter` instead. Kept for optional
  /// re-enable if JXA proves insufficient on some macOS versions.
  enum MediaRemotePerlAdapter {
    private static let perlPath = "/usr/bin/perl"
    private static let scriptName = "mediaremote-adapter.pl"
    private static let frameworkName = "MediaRemoteAdapter.framework"
    private static let subprocessTimeoutSeconds: TimeInterval = 3.5

    /// `true` / `false` when `get --no-artwork` returned JSON with a `playing` field; `nil` if the adapter
    /// is not bundled, the subprocess failed, or the payload was JSON `null`.
    static func snapshotPlayingState() -> Bool? {
      guard let bundleDir = bundledAdapterDirectoryURL() else {
        let diag = perlSearchDiagnostics()
        logPerlOnce(
          "MediaRemote Perl: adapter directory not found. Run make mediaremote-adapter, then rebuild. Diagnostics: \(diag)"
        )
        return nil
      }
      let scriptURL = bundleDir.appendingPathComponent(scriptName, isDirectory: false)
      let frameworkURL = bundleDir.appendingPathComponent(frameworkName, isDirectory: true)
      let frameworkBinary = frameworkURL.appendingPathComponent("MediaRemoteAdapter", isDirectory: false)

      guard FileManager.default.fileExists(atPath: scriptURL.path),
        FileManager.default.fileExists(atPath: frameworkBinary.path)
      else {
        logPerlOnce(
          "MediaRemote Perl: missing \(scriptName) or \(frameworkName)/MediaRemoteAdapter under \(bundleDir.path) — run make mediaremote-adapter then swift build"
        )
        return nil
      }

      let process = Process()
      process.executableURL = URL(fileURLWithPath: perlPath)
      process.arguments = [
        scriptURL.path,
        frameworkURL.path,
        "get",
        "--no-artwork"
      ]
      let outPipe = Pipe()
      let errPipe = Pipe()
      process.standardOutput = outPipe
      process.standardError = errPipe

      let done = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in done.signal() }

      do {
        try process.run()
      } catch {
        AppLogger.general.warning("MediaRemote Perl: failed to launch perl: \(error.localizedDescription)")
        return nil
      }

      let waitResult = done.wait(timeout: .now() + subprocessTimeoutSeconds)
      if waitResult == .timedOut {
        process.terminate()
        _ = done.wait(timeout: .now() + 1)
        AppLogger.general.warning("MediaRemote Perl: subprocess timed out")
        return nil
      }

      guard process.terminationStatus == 0 else {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        AppLogger.general.warning(
          "MediaRemote Perl: exit \(process.terminationStatus)\(errText.isEmpty ? "" : " — \(errText)")"
        )
        return nil
      }

      let data = outPipe.fileHandleForReading.readDataToEndOfFile()
      guard !data.isEmpty else {
        AppLogger.general.warning("MediaRemote Perl: empty stdout")
        return nil
      }

      let trimmed =
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard let jsonData = trimmed.data(using: .utf8) else {
        AppLogger.general.warning("MediaRemote Perl: stdout not UTF-8")
        return nil
      }

      guard let root = try? JSONSerialization.jsonObject(with: jsonData) else {
        let snippet = String(trimmed.prefix(200))
        AppLogger.general.warning("MediaRemote Perl: stdout not JSON (snippet: \(snippet, privacy: .public))")
        return nil
      }

      if root is NSNull {
        AppLogger.general.info(
          "MediaRemote Perl: get returned null (no Now Playing row or adapter rejected payload); falling back to in-process MR"
        )
        return nil
      }

      guard let dict = root as? [String: Any] else {
        return nil
      }

      if let playing = dict["playing"] as? Bool {
        if SettingsManager.shared.enableDetailedLogging {
          AppLogger.general.info("MediaRemote Perl: playing=\(playing, privacy: .public)")
        }
        return playing
      }
      if let num = dict["playing"] as? NSNumber {
        let playing = num.boolValue
        if SettingsManager.shared.enableDetailedLogging {
          AppLogger.general.info("MediaRemote Perl: playing=\(playing, privacy: .public) (NSNumber)")
        }
        return playing
      }

      if SettingsManager.shared.enableDetailedLogging {
        AppLogger.general.info("MediaRemote Perl: JSON missing \"playing\" key")
      }
      return nil
    }

    private static let perlDiagLock = NSLock()
    private static var lastPerlDiagMessage: String?

    private static func logPerlOnce(_ message: String) {
      perlDiagLock.lock()
      defer { perlDiagLock.unlock() }
      guard lastPerlDiagMessage != message else { return }
      lastPerlDiagMessage = message
      AppLogger.general.info("\(message, privacy: .public)")
    }

    private static func bundledAdapterDirectoryURL() -> URL? {
      let fm = FileManager.default
      let proof = scriptName

      if let fromBundleAPI = adapterDirectoryFromBundleResourceAPI() {
        return fromBundleAPI
      }

      if let fromApp = scanAppBundleContentsResources() {
        return fromApp
      }

      var candidates: [URL] = []

      if let resource = Bundle.main.resourceURL {
        candidates.append(resource.appendingPathComponent("MediaRemoteAdapterBundled", isDirectory: true))
        candidates.append(resource)
      }

      let appStyle = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/MediaRemoteAdapterBundled", isDirectory: true)
      candidates.append(appStyle)

      if let execDir = resolvedExecutableDirectory() {
        candidates.append(execDir.appendingPathComponent("MediaRemoteAdapterBundled", isDirectory: true))
        for bundleStem in [
          "Voicey_Voicey",
          "Voicey_MediaRemoteAdapterBundled",
          "MediaRemoteAdapterBundled",
          "Voicey"
        ] {
          let aux = execDir.appendingPathComponent("\(bundleStem).bundle", isDirectory: true)
          if let found = mediaRemoteBundledFolderIfPresent(inAuxiliaryBundle: aux) {
            return found
          }
          let resRoot = aux.appendingPathComponent("Contents/Resources", isDirectory: true)
          candidates.append(resRoot.appendingPathComponent("MediaRemoteAdapterBundled", isDirectory: true))
          candidates.append(resRoot)
        }

        if let scanned = scanResourceBundlesForAdapter(execDir: execDir) {
          return scanned
        }

        let parent = execDir.deletingLastPathComponent()
        if parent != execDir, let scanned = scanResourceBundlesForAdapter(execDir: parent) {
          return scanned
        }
      }

      for root in candidates {
        let nested = root.appendingPathComponent("MediaRemoteAdapterBundled", isDirectory: true).appendingPathComponent(
          proof,
          isDirectory: false
        )
        let flat = root.appendingPathComponent(proof, isDirectory: false)
        if fm.fileExists(atPath: nested.path) {
          return root.appendingPathComponent("MediaRemoteAdapterBundled", isDirectory: true)
        }
        if fm.fileExists(atPath: flat.path) {
          return root
        }
      }
      return nil
    }

    /// Resolves `mediaremote-adapter.pl` when Xcode or SwiftPM embeds it under `Contents/Resources/...`.
    private static func adapterDirectoryFromBundleResourceAPI() -> URL? {
      let fm = FileManager.default
      let subdirs: [String?] = ["MediaRemoteAdapterBundled", nil]
      for subdir in subdirs {
        let scriptURL: URL?
        if let sub = subdir {
          scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl", subdirectory: sub)
        } else {
          scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
        }
        guard let scriptURL else { continue }
        let dir = scriptURL.deletingLastPathComponent()
        let fwBinary = dir.appendingPathComponent(frameworkName, isDirectory: true)
          .appendingPathComponent("MediaRemoteAdapter", isDirectory: false)
        if fm.fileExists(atPath: fwBinary.path) {
          return dir
        }
      }
      return nil
    }

    /// Packaged `.app` builds place SwiftPM resource bundles under `Contents/Resources`, not next to the Mach-O file.
    private static func scanAppBundleContentsResources() -> URL? {
      let fm = FileManager.default
      let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
      guard fm.fileExists(atPath: resources.path) else { return nil }

      let nestedDir = resources.appendingPathComponent("MediaRemoteAdapterBundled", isDirectory: true)
      if fm.fileExists(atPath: nestedDir.appendingPathComponent(scriptName, isDirectory: false).path) {
        return nestedDir
      }
      if fm.fileExists(atPath: resources.appendingPathComponent(scriptName, isDirectory: false).path) {
        return resources
      }
      return scanResourceBundlesForAdapter(execDir: resources)
    }

    private static func resolvedExecutableDirectory() -> URL? {
      if let exec = Bundle.main.executableURL {
        return exec.deletingLastPathComponent()
      }
      guard let argv0 = ProcessInfo.processInfo.arguments.first else { return nil }
      return URL(fileURLWithPath: argv0, isDirectory: false).standardizedFileURL.deletingLastPathComponent()
    }

    private static func perlSearchDiagnostics() -> String {
      let fm = FileManager.default
      var parts: [String] = []
      if let execDir = resolvedExecutableDirectory() {
        let names = (try? fm.contentsOfDirectory(atPath: execDir.path))?.sorted() ?? []
        let bundles = names.filter { $0.hasSuffix(".bundle") }.joined(separator: ", ")
        parts.append("exeDir=\(execDir.path)")
        parts.append("bundles=[\(bundles)]")
      } else {
        parts.append("exeDir=(unknown)")
      }
      let appRes = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true).path
      parts.append("bundlePath=\(Bundle.main.bundlePath)")
      parts.append("resourceURL=\(Bundle.main.resourceURL?.path ?? "(nil)")")
      parts.append("appResourcesExists=\(fm.fileExists(atPath: appRes))")
      let line = parts.joined(separator: "; ")
      if line.count > 450 {
        return String(line.prefix(450)) + "…"
      }
      return line
    }

    /// SwiftPM 5.10+ often uses `TargetName_Target.bundle/<copied-folder>/` at the **bundle root** (no `Contents/Resources`).
    /// Xcode “Copy Bundle Resources” still uses `*.bundle/Contents/Resources/`. Check both.
    private static func scanResourceBundlesForAdapter(execDir: URL) -> URL? {
      let fm = FileManager.default
      guard let entries = try? fm.contentsOfDirectory(
        at: execDir,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ) else {
        return nil
      }

      for entry in entries {
        guard entry.hasDirectoryPath, entry.pathExtension == "bundle" else { continue }
        if let found = mediaRemoteBundledFolderIfPresent(inAuxiliaryBundle: entry) {
          return found
        }
      }
      return nil
    }

    /// Looks for `MediaRemoteAdapterBundled` inside an auxiliary resource bundle (e.g. `Voicey_Voicey.bundle`).
    private static func mediaRemoteBundledFolderIfPresent(inAuxiliaryBundle auxiliary: URL) -> URL? {
      let fm = FileManager.default
      guard fm.fileExists(atPath: auxiliary.path) else { return nil }

      let spmLayout = auxiliary.appendingPathComponent("MediaRemoteAdapterBundled", isDirectory: true)
      let spmScript = spmLayout.appendingPathComponent(scriptName, isDirectory: false)
      if fm.fileExists(atPath: spmScript.path) {
        return spmLayout
      }

      let resources = auxiliary.appendingPathComponent("Contents/Resources", isDirectory: true)
      guard fm.fileExists(atPath: resources.path) else { return nil }

      let nested = resources.appendingPathComponent("MediaRemoteAdapterBundled", isDirectory: true)
      let nestedScript = nested.appendingPathComponent(scriptName, isDirectory: false)
      if fm.fileExists(atPath: nestedScript.path) {
        return nested
      }

      let flatScript = resources.appendingPathComponent(scriptName, isDirectory: false)
      if fm.fileExists(atPath: flatScript.path) {
        return resources
      }
      return nil
    }
  }

#else

  enum MediaRemotePerlAdapter {
    static func snapshotPlayingState() -> Bool? { nil }
  }

#endif
