import Cocoa
import FlutterMacOS
import Sparkle

/// Sparkle, with no windows of its own. Sparkle asks its user driver what
/// to show at each step; this one shows nothing and answers for itself,
/// reporting to Dart instead, where the rail's notice is the only UI.
/// The other end is `lib/update/sparkle_updater.dart`.
final class UpdaterBridge: NSObject, SPUUpdaterDelegate, SPUUserDriver {
  private let channel: FlutterMethodChannel
  private var updater: SPUUpdater?

  /// Set once an update is staged: either Sparkle's quiet install-on-quit
  /// path, or its ready-to-relaunch prompt. Calling it installs and relaunches.
  private var install: (() -> Void)?

  /// Checks asked for by hand, answered together by whatever ends the
  /// session: "found", "upToDate" or "failed".
  private var checks: [FlutterResult] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "moe.loaf.chat/updater", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "start":
        self?.start()
        result(nil)
      case "check":
        guard let self else {
          result("failed")
          return
        }
        self.check(result)
      case "restart":
        guard let install = self?.install else {
          result(FlutterError(code: "not-ready", message: nil, details: nil))
          return
        }
        install()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func start() {
    guard updater == nil else { return }
    let sparkle = SPUUpdater(
      hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
    do {
      try sparkle.start()
      updater = sparkle
      sparkle.checkForUpdatesInBackground()
    } catch {
      NSLog("[loaf update] Sparkle did not start: \(error)")
    }
  }

  /// A session already under way, a background check included, answers
  /// this one too: starting a second is not allowed while it runs.
  private func check(_ result: @escaping FlutterResult) {
    guard let updater else {
      result("failed")
      return
    }
    if install != nil {
      result("found")
      return
    }
    checks.append(result)
    if !updater.sessionInProgress { updater.checkForUpdates() }
  }

  private func answer(_ outcome: String) {
    let waiting = checks
    checks = []
    waiting.forEach { $0(outcome) }
  }

  private func send(_ state: String, version: String? = nil) {
    channel.invokeMethod("state", arguments: ["state": state, "version": version])
  }

  private func staged(_ item: SUAppcastItem?, install: @escaping () -> Void) {
    self.install = install
    send("ready", version: item?.displayVersionString)
  }

  private var found: SUAppcastItem?

  // MARK: SPUUpdaterDelegate

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    found = item
    if install == nil { send("preparing") }
    answer("found")
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
    if install == nil { send("idle") }
    answer("upToDate")
  }

  func updater(
    _ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error
  ) {
    NSLog("[loaf update] download failed: \(error)")
    if install == nil { send("idle") }
  }

  /// Also follows not-found, which has answered already by then.
  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    if install == nil { send("idle") }
    answer("failed")
  }

  /// The backstop: a session that ended without saying how still answers.
  func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
  ) {
    answer(install != nil ? "found" : "failed")
  }

  /// The quiet path: downloaded and verified, waiting for the app to quit.
  /// Returning true keeps the timing ours; the block restarts on request.
  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    staged(item, install: immediateInstallHandler)
    return true
  }

  // MARK: SPUUserDriver — every prompt answered without showing anything.

  func show(
    _ request: SPUUpdatePermissionRequest,
    reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

  func showUpdateFound(
    with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    found = appcastItem
    reply(.install)
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    NSLog("[loaf update] \(error)")
    acknowledgement()
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {}

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

  func showDownloadDidReceiveData(ofLength length: UInt64) {}

  func showDownloadDidStartExtractingUpdate() {}

  func showExtractionReceivedProgress(_ progress: Double) {}

  /// The other path to staged: Sparkle asks before relaunching. The answer
  /// waits for the rail's restart.
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    staged(found, install: { reply(.install) })
  }

  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {}

  func showUpdateInstalledAndRelaunched(
    _ relaunched: Bool, acknowledgement: @escaping () -> Void
  ) {
    acknowledgement()
  }

  func showUpdateInFocus() {}

  func dismissUpdateInstallation() {}
}
