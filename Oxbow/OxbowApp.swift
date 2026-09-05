import AppKit
import SwiftUI
import OxbowKit

@main
struct OxbowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var content: QueueContent?

  /// Built eagerly: unlike the engine it needs nothing resolved first, and
  /// the launch-time check should not queue behind helper discovery.
  @State private var updates = UpdateModel.live()

  /// Built once a support directory is known, inside the guarded `.task`
  /// below rather than here — unlike `updates`, it needs a resolved path and
  /// must never exist during a test run. See that `.task` for why.
  @State private var poller: WatchPoller?

  /// The Watching list. Built alongside `poller`, from a `WatchStore` over
  /// the same `watches.json` — `WatchPoller` only ever reads that file, and
  /// `WatchingModel` is the one writer (see its own doc comment), so both
  /// need to agree on the same path rather than each deriving it separately.
  @State private var watching: WatchingModel?

  /// The same `WatchStore` `watching` was built from, kept alongside it so
  /// `AddChannelWindow` can open a second writer over `watches.json` without
  /// resolving the support directory a second time. Optional, and nil for
  /// the identical reason `watching` is: both are built together, behind the
  /// same `AppComposition.isUserSession` guard, in the `.task` below.
  @State private var watchStore: WatchStore?

  /// A Watching finding waiting to be applied the next time intake opens.
  ///
  /// Set by `WatchingModel.openIntake` (below) and consumed by
  /// `IntakeWindow.onAppear`, which clears it back to `nil` immediately after
  /// applying it — see that clearing's own comment for why leaving it set
  /// would be the Add Channel window's missing-reset bug all over again.
  /// Held here, rather than on `WatchingModel` itself, for the same reason
  /// `watching` and `poller` are: this is the one instance of intake's state
  /// across the app's whole run (`Window`, not `WindowGroup`), and the value
  /// has to outlive whichever `WatchingModel` happened to set it.
  @State private var pendingIntake: PendingIntake?

  /// Read once. Nothing in it can change while the app runs — it is all
  /// stamped into the bundle at build time — and both the menu item and the
  /// window title need the name.
  private let about = AboutInfo.main

  /// Handed to `AddChannelWindow`'s `init` below, hoisted here rather than
  /// built with `Preferences()` inline at that call site. `body` is a
  /// computed property SwiftUI re-evaluates on every state change this scene
  /// depends on, and `AddChannelWindow.init` only keeps its `preferences`
  /// argument long enough to seed `AddChannelModel`'s own `@State` — so a
  /// fresh `Preferences()` built inline there was constructed and discarded
  /// on every re-render for no reason. `Preferences()`'s default init is
  /// cheap (it wraps `.standard` and two closures, nothing eager), but a
  /// value with no reason to be rebuilt should not be.
  @State private var addChannelPreferences = Preferences()

  var body: some Scene {
    // `Window`, not `WindowGroup`. The engine is built once at launch
    // (design §2) and the app is single-window (design §4), and a
    // `WindowGroup` enforces neither: ⌘N stays live, and each new window
    // gets its own `@State`.
    //
    // That second `@State` used to be the whole danger. A second window ran
    // `setUp()` again and built a second `QueueController` — a second
    // `QueueEngine` over the same queue.json and the same workspace — and
    // `QueueEngine.start()` sweeps that workspace unconditionally, so
    // opening a window would delete the working files of a download already
    // in flight while the first engine's pending save never flushed. That
    // particular disaster is now prevented twice: `setUp()` awaits
    // `QueueHost.shared`, which resolves once and hands every later caller
    // the same controller, so a second window would share the engine rather
    // than construct one. `Window` is no longer the only thing standing
    // between the app and two engines — but nothing else here changed: ⌘N
    // would still be live, each window would still carry its own `@State`,
    // and single-instance is still the guarantee this app wants.
    //
    // Removing the New Window command from the group would hide the menu
    // item while leaving the scene duplicable by anything else that opens
    // one. `Window` makes single-instance the scene's own guarantee, and
    // drops the menu item as a consequence rather than as the fix.
    Window("Oxbow", id: Self.queueWindowID) {
      Group {
        // One view for both outcomes. `QueueView` owns the toolbar and the
        // banner, so a payload-missing launch gets the `+`-disabled window
        // design §6 describes rather than a bare page with no chrome.
        if let content {
          QueueView(
            content: content, updates: updates, watching: watching, poller: poller,
            canAddChannel: watchStore != nil, pendingIntake: $pendingIntake)
        } else {
          // This spinner covers `QueueEngine.start()` too, deliberately.
          // `QueueHost.ready()` answers only after the saved queue is loaded
          // and the workspace swept, so that nothing can enqueue into an
          // engine `start()` is about to overwrite — see `liveController`.
          // Showing rows before that would mean showing a queue that is still
          // being reconciled underneath them.
          ProgressView().frame(minWidth: 480, minHeight: 320)
        }
      }
      .task { await setUp() }
      // Screenshot framing only. Has to be AppKit rather than `.defaultSize`
      // below, which frame restoration overrides — see `ScreenshotFixture`.
      #if DEBUG
      .background {
        ScreenshotWindowSizer()
        ScreenshotIntakeOpener(
          windowID: Self.intakeWindowID,
          infoWindowID: Self.infoWindowID)
      }
      #endif
      // Its own task, not a step inside `setUp()`: the two are unrelated,
      // and a check that waits for the helper to be found would be a check
      // that never runs on the builds most in need of an update.
      //
      // Guarded, because `OxbowTests` is hosted by this app: without it every
      // `xcodebuild test` made a live GitHub request and wrote the real
      // preferences. See `AppComposition.isUserSession`.
      .task {
        guard AppComposition.isUserSession else { return }
        await updates.checkAutomatically()
      }
      // Its own task for the same reason the update check has one: unrelated
      // work, on an unrelated schedule.
      //
      // Guarded the same way and for the same reason: `OxbowTests` is hosted
      // by this app, so `xcodebuild test` launches it for real, and an
      // unguarded sweep would make a live Twitch request on every test run.
      // See `AppComposition.isUserSession`.
      .task {
        guard AppComposition.isUserSession else { return }
        guard poller == nil else { return }
        guard let support = try? AppComposition.defaultSupportDirectory() else { return }
        let store = WatchStore(fileURL: AppComposition.watchStoreURL(supportDirectory: support))
        watching = WatchingModel(
          store: store,
          // Only sets the state — opening the window itself is `QueueView`'s
          // job, via the `.onChange(of: pendingIntake)` beside its own
          // `openWindow`. This closure has no environment to call it from:
          // it runs inside a plain `.task`, not a view's own body.
          openIntake: { archive, watch in
            pendingIntake = PendingIntake(archiveID: archive.id, settings: watch.settings)
          })
        watchStore = store
        poller = WatchPoller.live(supportDirectory: support)
        poller?.start()
      }
    }
    // 720 was chosen for the queue alone, the same way its old 480pt minimum
    // was (see `QueueView`'s `.frame`) — pre-sidebar, that gave the queue
    // 240pt of room above its floor. Grown by the sidebar's own 180pt ideal
    // width for the same reason as the minimum: without it, the queue opens
    // at only 60pt above its new floor instead of the 240pt it used to get,
    // which is the same truncation this task exists to fix, just at launch
    // instead of at minimum width.
    .defaultSize(width: 900, height: 480)
    .windowResizability(.contentMinSize)
    .commands {
      // Replace, not add. The stock item calls
      // `orderFrontStandardAboutPanel`, whose one small credits scroller has
      // no room for the licence text this app is obliged to make reachable
      // (see `AboutView`). Leaving it in place would put two About items in
      // the menu, one of them insufficient.
      CommandGroup(replacing: .appInfo) {
        AboutCommand(applicationName: about.applicationName)
        // Where a Mac app puts it, and the only way to get a definitive
        // answer: the automatic check is silent unless it finds something,
        // so without this there is no way to tell "up to date" from "broken".
        CheckForUpdatesCommand(updates: updates)
      }
      // ⌘N is free: the queue is a `Window`, so there is no New Window item to
      // collide with. It opens intake, which is the only thing in this app a
      // person creates. The toolbar `+` in `QueueView` opens the same window —
      // the shortcut is a second path to it, never the only one.
      CommandGroup(replacing: .newItem) {
        AddDownloadCommand(isEnabled: controller != nil)
      }
      // Its own top-level menu, the way Transmission gives transfers one.
      // Everything here is also reachable by right-clicking a row; the menu is
      // what makes it discoverable, and what gives it key equivalents.
      DownloadsCommands()
    }

    // Intake as its own window, not a sheet on the queue.
    //
    // A sheet cannot exceed its host window, and this form legitimately wants
    // most of a screen once the render options are open — which made the queue
    // window's minimum size a function of its own modal. A window sizes itself,
    // remembers what the user dragged it to, and closes with ⌘W.
    //
    // `Window`, so ⌘N and the `+` re-focus the one that exists rather than
    // stacking half-filled copies of a form that each hold their own
    // `IntakeModel` and their own in-flight metadata fetch.
    Window("Add Download", id: Self.intakeWindowID) {
      // Unreachable without a controller — both the menu item and the toolbar
      // button are disabled in that case — but the window needs one, and there
      // is no honest thing to put here instead.
      if let controller {
        IntakeWindow(controller: controller, pendingIntake: $pendingIntake)
      }
    }
    .defaultSize(width: 560, height: 680)
    .windowResizability(.contentMinSize)
    .defaultPosition(.center)
    // Not restored on launch. macOS reopens whatever windows were open at
    // quit, which for a half-filled form means every launch starts with an
    // Add Download window nobody asked for — and its `IntakeModel` is
    // rebuilt empty anyway, so what reappears is a blank form, not the one
    // that was there.
    .restorationBehavior(.disabled)

    // Add Channel, its own window for the same reasons intake is one — a
    // form that can legitimately grow (§3.3's priced backfill line joins the
    // usual settings) belongs in something that sizes to its own content
    // rather than a sheet capped by the queue window's height.
    //
    // `Window`, so the toolbar button on the Watching pane re-focuses the one
    // that exists rather than stacking a second lookup on top of the first.
    Window("Add Channel", id: Self.addChannelWindowID) {
      // Unreachable before `watchStore` resolves — the same guard `intake`
      // above puts on `controller` — and there is nothing honest to show in
      // its place: this window exists to write `watches.json`, and until the
      // support directory is known there is no file to write to.
      if let watchStore {
        AddChannelWindow(store: watchStore, preferences: addChannelPreferences)
      }
    }
    .defaultSize(width: 480, height: 640)
    .windowResizability(.contentMinSize)
    .defaultPosition(.center)
    // Not restored, matching intake: a channel half-typed into a login field
    // is not a form worth resurrecting on the next launch, and its
    // `AddChannelModel` is rebuilt empty regardless.
    .restorationBehavior(.disabled)

    // Get Info, one window per download.
    //
    // `WindowGroup(for:)` rather than a single inspector window: asking for
    // info on the same job twice focuses the window that is already open
    // instead of stacking duplicates, and two downloads can be compared side
    // by side — which is what Finder's ⌘I does and what a single
    // follows-the-selection panel cannot.
    WindowGroup(id: Self.infoWindowID, for: JobID.self) { $jobID in
      if let jobID, let controller {
        JobInfoWindow(jobID: jobID, controller: controller)
      }
    }
    .defaultSize(width: 460, height: 620)
    .windowResizability(.contentMinSize)
    // Same reasoning as intake: macOS reopens what was open at quit, and a
    // restored info window would be pointing at a job whose queue has since
    // been reconciled — or removed entirely.
    .restorationBehavior(.disabled)

    // `Window`, so the About box is single-instance for the same reason the
    // queue and intake are: choosing the menu item twice brings the existing
    // one forward instead of stacking copies.
    //
    // `commandsRemoved()` drops the menu commands this scene would otherwise
    // contribute. The About box should be reachable only from the menu item,
    // the way a Mac About box is.
    Window("About \(about.applicationName)", id: Self.aboutWindowID) {
      AboutView(info: about)
    }
    .windowResizability(.contentSize)
    .commandsRemoved()
    .defaultPosition(.center)
    // Nothing here is worth restoring, and an About box reappearing on launch
    // is the same unasked-for window intake would be.
    .restorationBehavior(.disabled)

    // ⌘, and the app-menu item, for free — this is the whole scene.
    // `SettingsView` reads and writes `Preferences()`'s default `.standard`
    // domain itself; nothing here needs to be threaded through.
    //
    // macOS 26 auto-icons *system-provided* menu items (design doc §7.1):
    // `About Oxbow` and `Check for Updates…` above both needed an explicit
    // `Label` because they are ours, not the system's, and drew bare without
    // one. `Settings…` is a scene macOS itself generates the menu item for,
    // the same way it generates `Quit` and `Hide` — so it may already be
    // auto-iconed, unlike those two. **Unverified**: this cannot be checked
    // without opening the built app's menu bar, which this change does not
    // do. If it turns out to draw bare, replace this scene's content with
    // `CommandGroup(replacing: .appSettings) { ... Label("Settings…",
    // systemImage: "gearshape") ... }`, the same shape as the `CommandGroup`
    // above, plus an `@Environment(\.openSettings)` action.
    Settings {
      SettingsView()
    }
  }

  /// The id the About menu item opens.
  static let aboutWindowID = "about"

  /// The queue itself — the window the update banner appears in.
  static let queueWindowID = "queue"

  /// The id `QueueView` and the Downloads menu open Get Info with.
  static let infoWindowID = "info"

  /// The id both the menu item and `QueueView`'s toolbar button open.
  static let intakeWindowID = "intake"

  /// The id `QueueView`'s toolbar button opens from the Watching pane.
  static let addChannelWindowID = "addChannel"

  private var controller: QueueController? {
    if case .ready(let controller) = content { return controller }
    return nil
  }

  private func setUp() async {
    guard content == nil else { return }
    content = await QueueHost.shared.ready()
  }
}

/// The File ▸ Add Download… item.
///
/// A `View` rather than a `Button` written inline in the `CommandGroup`,
/// because `openWindow` is an environment value and an `App` has no
/// environment to read it from. Command content is a view builder, so a view
/// placed there does have one — this is the supported way for a menu item to
/// open a scene.
private struct AddDownloadCommand: View {
  let isEnabled: Bool

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      openWindow(id: OxbowApp.intakeWindowID)
    } label: {
      Label("Add Download…", systemImage: "plus")
    }
    .keyboardShortcut("n")
    .disabled(!isEnabled)
  }
}

/// The Oxbow ▸ Check for Updates… item.
///
/// Opens the queue window before checking, because the queue window is where
/// the answer is drawn. Choosing this from the menu bar with every window
/// closed would otherwise run a check whose result nothing displays.
private struct CheckForUpdatesCommand: View {
  let updates: UpdateModel

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      openWindow(id: OxbowApp.queueWindowID)
      Task { await updates.checkManually() }
    } label: {
      Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
    }
  }
}

/// The Oxbow ▸ About Oxbow item.
///
/// A `View` for the same reason `AddDownloadCommand` is one: `openWindow` is
/// an environment value, and an `App` has no environment to read it from.
private struct AboutCommand: View {
  let applicationName: String

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      openWindow(id: OxbowApp.aboutWindowID)
    } label: {
      Label("About \(applicationName)", systemImage: "info.circle")
    }
  }
}

/// Delays app termination until the running helpers have been killed and the
/// queue's pending debounced save is on disk.
///
/// `QueueController.shutDown()` is async; `applicationWillTerminate(_:)` is
/// not, and by the time it runs the app is already committed to quitting, so
/// there is nothing left to await it against. `applicationShouldTerminate(_:)`
/// is the hook that is allowed to say "not yet": returning `.terminateLater`
/// suspends the quit, and `NSApp.reply(toApplicationShouldTerminate:)` resumes
/// it once the shutdown actually completes. This blocks no thread — the work
/// runs to completion on `QueueEngine`'s own actor, and the reply is sent only
/// after that `await` returns, which is what guarantees both the kills and the
/// write land before the process is allowed to exit.
///
/// **Both halves have to happen here, and in that order.** Quitting mid-
/// download used to leave `TwitchDownloaderCLI` and its FFmpeg running as
/// orphans, because `HelperProcessing.cancel()` is the only thing that signals
/// their process group and nothing on the quit path called it. The delay this
/// adds is bounded by one ~2s SIGTERM grace period however many steps are in
/// flight, because `shutDown()` signals them concurrently — and the scheduler
/// admits at most one `.network` and one `.compute` step, so it is never more
/// than two.
///
/// Verified directly, not assumed, against a real VOD download in the built
/// app: quit while both `TwitchDownloaderCLI` and the `ffmpeg` it had spawned
/// were running, then `pgrep`'d for each from outside. Before this change the
/// app exited in ~0.3s and both survived, reparented to `launchd` with their
/// cwd still inside the job workspace that the next launch's
/// `Workspace.removeAll()` sweep deletes. After it, the app takes ~2.4s to go
/// — one SIGTERM grace period, externally observable proof that
/// `.terminateLater` really does hold the process open for the awaited work —
/// and `pgrep` finds neither. Relaunching then showed the step reconciled to
/// `.failed(.interrupted)`, as designed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Two things, and the order between them is the point.
  ///
  /// **The delegate registration is synchronous and unconditional**, because
  /// `UNUserNotificationCenter` requires its delegate before the app finishes
  /// launching — that is what makes a notification response which *cold-
  /// launches* Oxbow get delivered instead of dropped. Someone who queued a
  /// six-hour composite from Spotlight, walked away and quit is exactly the
  /// person who clicks "Show in Finder" on a launched-from-cold app, and the
  /// failure is silent. Deferring it into the `Task` below would not do:
  /// unstructured work cannot begin until this method returns. Routing it
  /// through resolution would not do either — the notifier is otherwise only
  /// built on `ready()`'s `.ready` branch, so a `helperMissing` launch would
  /// register no delegate at all.
  ///
  /// **The resolution nudge is fire-and-forget**, because this method cannot
  /// await and nothing here needs the result. `ready()` is idempotent, so the
  /// scene's own `.task` joins this resolution rather than starting a second
  /// one.
  func applicationDidFinishLaunching(_ notification: Notification) {
    QueueHost.shared.registerNotificationDelegate()
    Task { _ = await QueueHost.shared.ready() }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // `resolvedController`, not `ready()`: quitting must never *start* a
    // resolution in order to discover there is nothing to shut down.
    guard let controller = QueueHost.shared.resolvedController else { return .terminateNow }
    Task {
      await controller.shutDown()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
