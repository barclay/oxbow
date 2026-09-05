import AppKit
import SwiftUI
import OxbowKit

struct QueueView: View {
  let content: QueueContent
  let updates: UpdateModel

  /// The Watching list and the sweep that feeds it.
  ///
  /// Both optional for the same reason: `OxbowApp` builds them only once it
  /// has resolved a support directory, behind the same
  /// `AppComposition.isUserSession` guard that keeps `WatchPoller` off the
  /// network during `xcodebuild test` — see the guarded `.task` there. A
  /// test-hosted window simply sees nil here, and the Watching pane below
  /// falls back to `WatchingView`'s own empty state rather than this view
  /// having to invent a second "no data yet" state of its own.
  let watching: WatchingModel?
  let poller: WatchPoller?

  /// Whether `OxbowApp` has resolved a support directory yet, and so has a
  /// `WatchStore` ready for the Add Channel window to write to. `watching`
  /// itself would say the same thing, but reading `watching == nil` here
  /// would tie this button's enabled state to a model whose only other job
  /// is holding the sweep results — a coincidence, not a dependency this
  /// view should be built to notice if it ever stopped holding.
  let canAddChannel: Bool

  /// A Watching finding waiting to be applied, from `OxbowApp`'s own `@State`.
  ///
  /// **This is where `WatchingModel.openIntake` actually opens anything.**
  /// The closure `OxbowApp` hands to `WatchingModel` only sets this binding —
  /// it runs inside a plain `.task`, with no `openWindow` to call — so the
  /// `.onChange` below is what turns "a finding is pending" into the intake
  /// window actually appearing, using the `openWindow` this view already has.
  @Binding var pendingIntake: PendingIntake?

  /// Opens the intake window (`OxbowApp.intakeWindowID`). Intake is a window
  /// rather than a sheet on this one — see `IntakeWindow` for why — so the
  /// toolbar button hands off to the scene instead of presenting anything.
  @Environment(\.openWindow) private var openWindow

  /// Opening the release page is the update banner's whole action.
  @Environment(\.openURL) private var openURL

  @State private var selection: Set<JobID> = []

  /// Which sidebar destination is showing. Optional because `List`'s
  /// selection binding requires it — a `List` reports "nothing selected" as
  /// nil, most visibly when someone command-clicks the current row off — but
  /// the initial value is Queue, and the detail switch below treats a later
  /// nil the same way rather than showing a blank pane.
  @State private var sidebarSelection: SidebarItem? = .queue

  private enum SidebarItem: Hashable {
    case queue
    case watching
  }

  /// A removal waiting on the user, and the dialog's own presentation flag.
  ///
  /// Two pieces of state rather than one optional driving a computed
  /// `Binding(get:set:)`: the binding form has to write `nil` back on dismiss,
  /// which means constructing a binding inside `body` that mutates the state
  /// `body` is reading. Separate flags keep the dismissal SwiftUI's business.
  @State private var isConfirmingRemoval = false
  @State private var jobsPendingRemoval: Set<JobID> = []

  private var controller: QueueController? {
    if case .ready(let controller) = content { return controller }
    return nil
  }

  /// The window's one explanation slot, in precedence order.
  ///
  /// A missing payload outranks a queue file that failed to load: nothing can
  /// run at all, which is the more important thing to say, and the two cannot
  /// both be true anyway — without an engine there is no load to fail.
  private var banner: (title: String, message: String)? {
    switch content {
    case .unavailable(let message):
      return ("Downloads unavailable", message)
    case .ready(let controller):
      guard let failure = controller.startFailure else { return nil }
      return ("Saved queue not loaded", failure)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      if let banner {
        QueueBanner(title: banner.title, message: banner.message)
        Divider()
      }
      // Below the warning, never above it. A missing helper means the app
      // cannot do its job at all, which outranks news about a version that
      // would have the same problem.
      if updates.state != .idle {
        UpdateBanner(
          state: updates.state,
          onOpen: { openURL($0) },
          onDismiss: { updates.dismiss() })
        Divider()
      }
      // Both banners span this whole split view rather than sitting inside
      // the detail pane. They are about the app — a missing helper means
      // nothing can download regardless of which sidebar item is showing —
      // so putting them in the detail pane would hide "Downloads unavailable"
      // behind whichever destination happened to be selected.
      NavigationSplitView {
        List(selection: $sidebarSelection) {
          Label("Queue", systemImage: "tray.full")
            .tag(SidebarItem.queue)
          // `.badge` before `.tag`, not after — verified the hard way. With
          // `.tag` applied first, clicking this row on macOS 26 stopped
          // changing `sidebarSelection` at all: the row highlighted, an
          // AppKit selection action fired, and the binding never saw it. No
          // such regression is on record anywhere the settings.md §7 probe
          // looked, so treat this order as load-bearing rather than
          // stylistic until Apple documents otherwise.
          Label("Watching", systemImage: "eye")
            .badge(watching?.unreadCount ?? 0)
            .tag(SidebarItem.watching)
        }
        .listStyle(.sidebar)
        // Roughly fixed, the way Mail and Finder do it, rather than left to
        // SwiftUI's default proportional split. Unconstrained, the sidebar
        // claimed close to a third of the window at minimum width, which is
        // most of what the queue below needs just to keep a job's title
        // legible.
        .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 240)
      } detail: {
        switch sidebarSelection {
        case .watching:
          WatchingView(
            sections: watching?.sections ?? [],
            isSweeping: poller?.isSweeping ?? false,
            onAdd: { archive, section in watching?.add(archive, from: section.login) },
            onIgnore: { archive, section in watching?.ignore(archive, from: section.login) })
        case .queue, .none:
          queue
        }
      }
    }
    // 480 is the queue's own minimum, not the window's — it is what a job
    // row needs to keep its title legible, from before this view had a
    // sidebar at all. The +180 is the sidebar's ideal column width (set
    // above), added on top rather than carved out of the 480, so the detail
    // pane keeps roughly its designed minimum even if the split view ever
    // shrinks the sidebar down to its own 150pt floor. Height is untouched:
    // a sidebar costs no height.
    .frame(minWidth: 480 + 180, minHeight: 320)
    .toolbar {
      // Two different buttons behind the same placement, switched on which
      // pane is showing — never both, and never neither. `Add Download`
      // opens intake for a brand-new job, which is a Queue action, and a
      // finding row already has its own Add for adding *that* video; leaving
      // it visible next to a highlighted finding would invite the guess that
      // it acts on the row, when it does not. `Add Channel` is the reverse:
      // it is how a person reaches the window at all, including — per
      // `docs/design/channel-watching.md` §3 — the moment nothing is watched
      // yet and `WatchingView`'s own empty state has no control of its own to
      // offer. Living in this toolbar rather than in that empty state is what
      // keeps the button reachable whether the list is empty or full,
      // matching where `Add Download` already sits for the Queue pane.
      if sidebarSelection == .watching {
        ToolbarItem(placement: .primaryAction) {
          Button {
            openWindow(id: OxbowApp.addChannelWindowID)
          } label: {
            Label("Add Channel", systemImage: "plus")
          }
          .help("Watch a Twitch channel for new archives")
          .disabled(!canAddChannel)
        }
      } else {
        ToolbarItem(placement: .primaryAction) {
          Button {
            openWindow(id: OxbowApp.intakeWindowID)
          } label: {
            Label("Add Download", systemImage: "plus")
          }
          // Kept alongside ⌘N deliberately: the shortcut is the fast path for
          // people who know it, and the button is how everyone else finds the
          // feature at all.
          .help("Add Download (⌘N)")
          .disabled(controller == nil)
        }
      }
    }
    // `initial: true` because `poller` and `watching` are built by `OxbowApp`
    // independently of when this view appears — a sweep can finish while the
    // queue is still loading, before this view exists to observe it. Without
    // replaying the current value on appear, that first sweep's results would
    // sit in `poller.results` unseen until a second one arrives, up to an
    // hour later.
    .onChange(of: poller?.results, initial: true) { _, results in
      guard let results else { return }
      watching?.apply(results)
    }
    // See `pendingIntake`'s own doc comment above: this is the one place that
    // turns a finding's Add into the intake window actually opening. If the
    // window is already open, `openWindow` just re-focuses it — `Window`'s
    // own single-instance guarantee — and `IntakeWindow.onAppear` does not
    // fire a second time, so a finding Added while intake was already open on
    // a different video would sit unconsumed until the next close and
    // reopen. Accepted rather than fixed here: `onAppear` firing only on
    // genuine appearance is a SwiftUI `Window` scene's normal behaviour, not
    // a hook this view can ask for a second time, and clicking Add while a
    // different download is already mid-edit in an open intake window is a
    // narrow enough case that a future close/reopen recovering it is an
    // acceptable cost.
    .onChange(of: pendingIntake) { _, newValue in
      guard newValue != nil else { return }
      openWindow(id: OxbowApp.intakeWindowID)
    }
  }

  /// The queue itself. With no controller there are no jobs, so this is the
  /// empty state with its action disabled — the banner above it says why.
  @ViewBuilder
  private var queue: some View {
    if let controller, !controller.jobs.isEmpty {
      List(selection: $selection) {
        ForEach(controller.jobs) { job in
          JobRow(
            job: job,
            onCancel: { Task { await controller.cancel(job: job.id) } },
            onRetryJob: { Task { await controller.retry(job: job.id) } },
            onRetryStep: { step in Task { await controller.retry(step: step) } },
            onRevealRetainedFiles: { id in Task { await controller.revealRetainedFiles(for: id) } },
            checkRevealTarget: { id in await controller.revealTarget(for: id) },
            retainedBytes: { id in await controller.retainedBytes(for: id) })
          .tag(job.id)
        }
      }
      // The system's own alternating row colours, not a colour of our own:
      // rows here vary wildly in height — a collapsed single-step job is one
      // line, an expanded composite is five — and banding is what lets the eye
      // tell where one job ends and the next begins. It costs nothing when
      // there is one job, since the first row is always the unshaded one.
      .alternatingRowBackgrounds()
      // Delete on the selection, which is what a Mac list does. Removal is the
      // thing this window had no way to do at all: every job ever enqueued
      // stayed on screen forever.
      .onDeleteCommand { requestRemoval(of: selection, from: controller) }
      // `forSelectionType:` rather than a per-row `.contextMenu`, so
      // right-clicking a row selects it first and a right-click on a
      // multi-row selection acts on all of it — both of which a per-row menu
      // gets wrong.
      .contextMenu(forSelectionType: JobID.self) { ids in
        QueueActionButtons(
          actions: actions(from: controller), ids: ids, presentation: .contextMenu)
      } primaryAction: { ids in
        // `primaryAction` is the double-click. Get Info, matching ⌘I — the
        // only gesture on a row that had no meaning, and the one Finder gives
        // to the same action.
        guard let id = ids.first, ids.count == 1 else { return }
        openWindow(id: OxbowApp.infoWindowID, value: id)
      }
      // Published for the menu bar. This sits inside the Queue detail pane,
      // so switching the sidebar to Watching tears it down and the Downloads
      // menu greys out — even though the queue still holds jobs. That is
      // accepted, not missed: the menu follows the visible pane, the same way
      // its items are already hidden or disabled based on what is selected
      // within the list. `focusedSceneValue` over `focusedValue` only buys
      // independence from keyboard focus inside this pane, not independence
      // from which pane is showing.
      .focusedSceneValue(\.queueActions, actions(from: controller))
      .confirmationDialog(
        removalConfirmationTitle(for: jobsPendingRemoval, from: controller),
        isPresented: $isConfirmingRemoval)
      {
        Button("Remove", role: .destructive) {
          remove(jobsPendingRemoval, from: controller)
        }
        Button("Cancel", role: .cancel) { jobsPendingRemoval = [] }
      } message: {
        Text("The download will stop. Files already saved are not deleted.")
      }
    } else {
      ContentUnavailableView {
        Label("No downloads", systemImage: "tray")
      } description: {
        Text("Add a Twitch VOD to get started.")
      } actions: {
        Button("Add Download…") { openWindow(id: OxbowApp.intakeWindowID) }
          .disabled(controller == nil)
      }
      // Fills the space the `List` branch would, so the `VStack` above has a
      // child that expands. Without it the stack's children total less than
      // the window and get centred as a block — which left the update banner
      // floating in the middle of an empty window instead of sitting under
      // the toolbar. `ContentUnavailableView` still centres its own content
      // inside this, so the empty state looks unchanged.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Actions

  /// The queue's actions, bound to this controller.
  ///
  /// Removal goes back through `requestRemoval` rather than straight to the
  /// controller, so a Remove from the menu bar gets the same confirmation over
  /// a running download that the Delete key does.
  private func actions(from controller: QueueController) -> QueueActions {
    QueueActions(
      jobs: controller.jobs,
      selection: selection,
      remove: { requestRemoval(of: $0, from: controller) },
      retry: { job in Task { await controller.retry(job: job) } },
      cancel: { job in Task { await controller.cancel(job: job) } },
      showInfo: { openWindow(id: OxbowApp.infoWindowID, value: $0) })
  }

  // MARK: - Removal

  /// Removes immediately, or asks first when something is still running.
  ///
  /// The confirmation is not for the row — a row is cheap to lose — it is for
  /// the work. Removing a running job kills its helper, and a two-hour chat
  /// render deserves better than a mis-hit Delete key. Nothing settled asks.
  private func requestRemoval(of ids: Set<JobID>, from controller: QueueController) {
    guard !ids.isEmpty else { return }

    let running = controller.jobs.filter { ids.contains($0.id) && $0.status == .running }
    guard running.isEmpty else {
      jobsPendingRemoval = ids
      isConfirmingRemoval = true
      return
    }
    remove(ids, from: controller)
  }

  private func remove(_ ids: Set<JobID>, from controller: QueueController) {
    jobsPendingRemoval = []
    selection.subtract(ids)
    Task { await controller.remove(jobs: ids) }
  }

  /// Names what is about to be stopped, rather than asking abstractly. One
  /// running job is worth naming; several are worth counting.
  private func removalConfirmationTitle(
    for ids: Set<JobID>,
    from controller: QueueController)
    -> String
  {
    let running = controller.jobs.filter { ids.contains($0.id) && $0.status == .running }
    guard let only = running.first, running.count == 1 else {
      return "Remove \(running.count) downloads that are still running?"
    }
    return "Remove “\(only.title)” while it is still downloading?"
  }
}

#Preview("Helper missing") {
  QueueView(
    content: .unavailable("""
    The TwitchDownloaderCLI helper is not embedded in this build. Build it \
    with the dotnet publish command in docs/development.md, then build the \
    app again.
    """),
    updates: UpdateModel { .upToDate },
    watching: nil,
    poller: nil,
    canAddChannel: false,
    pendingIntake: .constant(nil))
  .frame(width: 720, height: 420)
}

#Preview("Update available") {
  let updates = UpdateModel {
    .available(
      ReleaseVersion("0.3.0")!,
      URL(string: "https://github.com/LoftiStudios/oxbow/releases/tag/v0.3.0")!)
  }
  return QueueView(
    content: .unavailable("No helper in this build."),
    updates: updates,
    watching: nil,
    poller: nil,
    canAddChannel: false,
    pendingIntake: .constant(nil))
    .frame(width: 720, height: 420)
    .task { await updates.checkAutomatically() }
}
