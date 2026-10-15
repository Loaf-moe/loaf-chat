import Cocoa
import FlutterMacOS
import Sparkle

/// Sparkle, with no windows of its own. Sparkle asks its user driver what
/// to show at each step; this one shows nothing and answers for itself,
/// reporting to Dart instead, where the rail's notice is the only UI.
/// Both directions are typed by Pigeon (`pigeons/sparkle.dart` →
/// `Sparkle.g.swift`); the other end is `lib/update/macos/sparkle_updater.dart`.
final class UpdaterBridge: NSObject, SparkleHost, SPUUpdaterDelegate, SPUUserDriver {
  private let events: SparkleEvents
  private var updater: SPUUpdater?

  /// Set once an update is staged: either Sparkle's quiet install-on-quit
  /// path, or its ready-to-relaunch prompt. Calling it installs and relaunches.
  private var install: (() -> Void)?

  /// Checks asked for by hand, answered together by whatever ends the session.
  private var checks: [CheckedContinuation<SparkleCheck, Never>] = []

  /// The last event on its way to Dart. Each waits for the one before, so
  /// Dart hears preparing before ready, as it happened.
  private var sending: Task<Void, Never>?

  init(messenger: FlutterBinaryMessenger) {
    events = SparkleEvents(binaryMessenger: messenger)
    super.init()
    SparkleHostSetup.setUp(binaryMessenger: messenger, api: self)
  }

  // MARK: SparkleHost

  func start() {
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
  @MainActor func check() async -> SparkleCheck {
    guard let updater else { return .failed }
    if install != nil { return .found }
    return await withCheckedContinuation { done in
      checks.append(done)
      if !updater.sessionInProgress { updater.checkForUpdates() }
    }
  }

  func restart() throws {
    guard let install else {
      throw PigeonError(code: "not-ready", message: "nothing is staged", details: nil)
    }
    install()
  }

  private func answer(_ outcome: SparkleCheck) {
    let waiting = checks
    checks = []
    waiting.forEach { $0.resume(returning: outcome) }
  }

  private func send(_ event: @escaping @MainActor (SparkleEvents) async throws -> Void) {
    let previous = sending
    let events = self.events
    sending = Task { @MainActor in
      await previous?.value
      do {
        try await event(events)
      } catch {
        NSLog("[loaf update] Dart did not hear an update event: \(error)")
      }
    }
  }

  private func staged(_ item: SUAppcastItem?, install: @escaping () -> Void) {
    self.install = install
    let version = item?.displayVersionString
    send { try await $0.ready(version: version) }
  }

  private var found: SUAppcastItem?

  // MARK: SPUUpdaterDelegate

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    found = item
    if install == nil { send { try await $0.preparing() } }
    answer(.found)
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
    if install == nil { send { try await $0.idle() } }
    answer(.upToDate)
  }

  func updater(
    _ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error
  ) {
    NSLog("[loaf update] download failed: \(error)")
    if install == nil { send { try await $0.idle() } }
  }

  /// Also follows not-found, which has answered already by then.
  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    if install == nil { send { try await $0.idle() } }
    answer(.failed)
  }

  /// The backstop: a session that ended without saying how still answers.
  func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
  ) {
    answer(install != nil ? .found : .failed)
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
