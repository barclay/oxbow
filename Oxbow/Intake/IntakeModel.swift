import Foundation
import Observation
import OxbowKit

/// Everything the intake sheet knows and every decision it makes.
///
/// The sheet's rules are not presentation: which outputs are legal, what each
/// one is called, where it lands, and whether Add may fire at all come from
/// the design doc (§2 intake, §4 filenames, §6 quality, §8 clips). They live
/// here so they can be tested without a window, and `IntakeSheet` is left as
/// a rendering of this type.
///
/// The two collaborators are closures rather than a `QueueController` so a
/// test can supply a metadata failure or capture an enqueued template without
/// standing up an engine; `init(controller:)` wires the real ones.
@Observable
final class IntakeModel {

  /// Where the one metadata fetch per link has got to.
  ///
  /// `.failed` is a usable state, not a dead end: the name falls back to the
  /// id or slug and the sheet still composes a job (design doc §3 — the fetch
  /// exists to name files and offer qualities, and both have an answer
  /// without it). Only `.idle` and `.loading` disable Add.
  enum Metadata {
    case idle
    case loading
    case loaded(VideoInfo)
    case failed(String)
  }

  // MARK: - What the user types and picks

  var linkText = ""

  /// The shared base name for this job's outputs, pre-filled from the video's
  /// own metadata and then the user's to edit.
  var name = ""

  /// Chat included by default, and listed first: it is the reason to reach
  /// for Oxbow rather than any of the video-only downloaders, and a user who
  /// wanted only the video loses nothing but one click.
  var output: DownloadOutput = .default

  /// How large the composited chat text is. Only meaningful for
  /// `.videoWithChat` — a plain video has no render to size — and only shown
  /// then (see `IntakeWindow`). `CompositeGeometry.fontSize(for:)` turns this
  /// into an actual point size proportional to the chosen quality's chat
  /// column, so the same choice reads the same way at 1080p or 480p.
  var chatSize: ChatSize = .default

  /// The empty string means "best available" — the behaviour proven against
  /// the real CLI, which selects source when `-q` is absent (design doc §6).
  /// Video-only keeps that behaviour; a composite cannot leave it unresolved
  /// (see `compositeQuality`) because the chat column's height must equal the
  /// video's.
  var quality = ""

  var folder: URL?

  /// The preference-shaped quality value, as distinct from `quality`, which
  /// names a rendition of *this* video.
  ///
  /// Both exist because `QualityLadder.resolve` and `.bucket` are not
  /// inverses (docs/design/settings.md §3.3): a cap of `.p720` against a
  /// video offering only 1080p resolves to `1080p60`, and re-deriving the cap
  /// from that would quietly raise the user's standing preference because of
  /// one unusual video. Keeping the cap means an untouched picker saves back
  /// exactly what was seeded.
  var qualityCap: QualityCap

  /// The checkbox. **Always false at seed, on every run including the first**
  /// — see §2.2. A box that stays ticked is last-used-wins with extra steps.
  var wantsToSaveDefaults = false

  /// The stored destination was gone and `~/Downloads` was used instead. Shown
  /// inline, because the disk preflight measures the destination's volume and
  /// a silent fallback would change what its estimate means.
  private(set) var destinationFellBack = false

  /// Whether the options panel is open.
  ///
  /// Writes through to the store, so a collapse sticks — except the
  /// transient expansion in `isOptionsEffectivelyExpanded`, which must not.
  var isOptionsExpanded: Bool {
    didSet { preferences.optionsPanelIsExpanded = isOptionsExpanded }
  }

  /// What the panel actually shows.
  ///
  /// Forced open whenever a refusal is on screen. Both `chatProblem` and
  /// `compositeProblem` render inside this panel and both disable Add, so a
  /// closed panel would grey Add out with the explanation sealed inside it —
  /// the exact failure those messages exist to prevent. Transient by
  /// construction: it never reaches `isOptionsExpanded`, so a clip with an
  /// expired broadcast cannot permanently reopen the drawer.
  var isOptionsEffectivelyExpanded: Bool {
    isOptionsExpanded || chatProblem != nil || compositeProblem != nil
  }

  /// Reads the effective value, writes the stored one. A user's collapse
  /// sticks; a refusal's forced expansion does not.
  ///
  /// **The setter ignores writes while a refusal is forcing the panel
  /// open.** Without this, tapping the triangle while
  /// `chatProblem` or `compositeProblem` is showing calls this setter with
  /// `false`, which writes through to `isOptionsExpanded` and so to the
  /// store — but the getter above still returns `true` regardless, because
  /// the refusal is still there. The drawer visibly does not move, so the
  /// tap reads as a dead control either way; the difference is whether it
  /// is *also* silently rewriting a stored preference for every future
  /// intake behind that dead control. An inert triangle is honest about
  /// what just happened; one that quietly changes state nothing on screen
  /// reflects is not.
  var isOptionsEffectivelyExpandedBinding: Bool {
    get { isOptionsEffectivelyExpanded }
    set {
      guard chatProblem == nil, compositeProblem == nil else { return }
      isOptionsExpanded = newValue
    }
  }

  /// The collapsed header's summary. Collapsed is the steady state, so a
  /// header that says only "Download Options" hides where the file is going
  /// on most downloads.
  ///
  /// **Named through `isClip`, which the expanded picker below already used**
  /// ("Clip + chat"/"Clip" rather than "Video + chat"/"Video") — this summary
  /// used to compute the label independently and disagree with it, so a
  /// clip's collapsed header read "Video + chat" for the exact same state its
  /// own expanded picker called "Clip + chat". `isClip` moved onto the model
  /// (from `IntakeWindow`, which had its own private copy) so both call sites
  /// share one answer instead of two copies that can drift.
  var optionsSummary: String {
    let outputLabel: String
    switch (output, isClip) {
    case (.videoWithChat, true): outputLabel = "Clip + chat"
    case (.videoWithChat, false): outputLabel = "Video + chat"
    case (.video, true): outputLabel = "Clip"
    case (.video, false): outputLabel = "Video"
    }
    let folderName = folder?.lastPathComponent ?? "No folder"
    return "\(outputLabel) · \(qualityCap.label) · \(folderName)"
  }

  /// Whether `target` is a clip rather than a VOD. Lives here rather than
  /// only in `IntakeWindow` (where a private copy used to compute the same
  /// thing for the output picker's labels) because `optionsSummary` above
  /// needs the same answer, and two independent copies of a one-line
  /// predicate are two copies that can silently disagree.
  var isClip: Bool {
    if case .clip = target { return true }
    return false
  }

  private var preferences: Preferences

  /// Trim times as typed, parsed by `Timecode`. Kept as text rather than
  /// `Duration?` so a half-typed value is a visible error rather than
  /// silently reading as no trim at all.
  var trimStartText = ""
  var trimEndText = ""

  private(set) var metadata: Metadata = .idle

  /// The id or slug the settled `metadata` actually describes.
  ///
  /// Metadata outlives the link it was fetched for — the user can paste
  /// another one at any point — and everything derived from it (the name, the
  /// quality list, and Add itself) has to stop trusting it the moment the two
  /// disagree, or a job gets composed for one video out of another's details.
  private(set) var metadataIdentifier: String?

  /// Set when Add refused. Only reachable if `canAdd` and
  /// `composedTemplate()` ever disagreed, which they cannot — but a sheet
  /// that closes on a job that was never composed is exactly the silent
  /// failure this whole path exists to avoid, so the refusal says so out loud
  /// instead of dismissing.
  private(set) var addFailure: String?

  // MARK: - Collaborators

  private let fetchInfo: (String) async throws -> VideoInfo
  private let enqueue: (JobTemplate, String) async -> Void
  private let calendar: Calendar
  /// Injected so the collision rule is testable without touching a real
  /// folder; production passes `FileManager`'s check. The app is not
  /// sandboxed, so probing the user's chosen folder needs no further
  /// ceremony.
  private let fileExists: (URL) -> Bool
  /// Injected for the same reason as `fileExists`: filling a volume to test a
  /// warning is not a test anyone runs twice.
  private let volumeSpace: VolumeSpace
  /// A path on the volume the job's workspace lives on.
  ///
  /// Only the *volume* matters — free space is a property of the volume and
  /// every path on it shares the answer — so this is Application Support
  /// rather than the workspace's exact directory. Deriving that exact path
  /// here would duplicate `AppComposition`'s, and a second copy is a copy that
  /// drifts.
  private let workspaceVolumePath: URL

  /// Where `apply(_:)` falls back to when a watch's frozen destination no
  /// longer resolves — mirrors `Preferences.factoryDestination`, which needs
  /// the same injected value for the same reason: a test cannot depend on
  /// the real `~/`.
  private let homeDirectory: URL

  /// Distinguishes the fetch in flight from one the user has already
  /// superseded by editing the link. Without it a slow fetch for the previous
  /// link lands last and names the job after the wrong video.
  private var generation = 0

  init(
    fetchInfo: @escaping (String) async throws -> VideoInfo,
    enqueue: @escaping (JobTemplate, String) async -> Void,
    calendar: Calendar = .current,
    fileExists: @escaping (URL) -> Bool = {
      FileManager.default.fileExists(atPath: $0.path)
    },
    volumeSpace: VolumeSpace = .live,
    workspaceVolumePath: URL = URL.applicationSupportDirectory,
    homeDirectory: URL = .homeDirectory,
    preferences: Preferences)
  {
    self.fetchInfo = fetchInfo
    self.enqueue = enqueue
    self.calendar = calendar
    self.fileExists = fileExists
    self.volumeSpace = volumeSpace
    self.workspaceVolumePath = workspaceVolumePath
    self.homeDirectory = homeDirectory
    self.preferences = preferences
    self.qualityCap = preferences.qualityCap
    self.output = preferences.output
    self.chatSize = preferences.chatSize
    self.folder = preferences.destination
    self.destinationFellBack = preferences.storedDestinationIsMissing
    self.isOptionsExpanded = preferences.optionsPanelIsExpanded
  }

  /// Wires the real collaborators. Everything about where a freshly opened
  /// window starts — the folder, the quality cap, the output and the chat
  /// size — is seeded by the designated init from `preferences`, which
  /// defaults to the live `UserDefaults.standard`-backed store here.
  ///
  /// This used to seed only the folder, from a `defaultDestination` that
  /// computed `~/Downloads` and said in its own doc comment that "last
  /// used" was deliberately not persisted. That question now has a real
  /// answer — see `docs/design/settings.md` §2.2.
  convenience init(
    controller: QueueController,
    calendar: Calendar = .current,
    preferences: Preferences = Preferences())
  {
    self.init(
      fetchInfo: { try await controller.fetchInfo(for: $0) },
      enqueue: { await controller.enqueue($0, title: $1) },
      calendar: calendar,
      preferences: preferences)
  }

  // MARK: - Starting over

  /// Returns the form to its opening state, keeping what is a standing
  /// preference rather than this video's business.
  ///
  /// Add Download is a `Window` rather than a `WindowGroup` — one scene for
  /// the app's whole run, so that half-filled copies cannot stack — which
  /// means the model that survives a close is also the one the next open
  /// inherits. Without this, the second open shows the first link again.
  ///
  /// Worse than merely reappearing: the clipboard prefill is guarded on the
  /// link field being empty, so a link left behind here stops the next open
  /// from reading the clipboard *at all*. The staleness and the dead prefill
  /// are the same bug, and this is the one place that fixes both.
  ///
  /// `folder`, `output`, `chatSize`, `qualityCap` and `isOptionsExpanded`
  /// come back from the preference store rather than surviving in place —
  /// see `reseedFromPreferences()`, which is what actually does that read.
  /// They used to be preserved here with a paragraph explaining that they
  /// answer how the user works rather than anything about this video — which
  /// was right, and which this is the conclusion of: that was a
  /// within-one-run approximation of a preference store, and there is a real
  /// one now.
  func reset() {
    linkText = ""
    name = ""
    quality = ""
    reseedFromPreferences()
    wantsToSaveDefaults = false
    isTrimExpanded = false
    trimStartText = ""
    trimEndText = ""
    metadata = .idle
    metadataIdentifier = nil
    addFailure = nil
    // Invalidates a fetch still in flight the same way a new link does, so a
    // late arrival cannot settle metadata into the form it just emptied.
    generation += 1
  }

  /// Re-reads the four standing preferences — plus the panel's own persisted
  /// expansion and the stale-destination flag derived from it — from the
  /// store, touching nothing about whatever video is currently on screen.
  ///
  /// **Why `reset()` on close is not enough by itself.** Add Download is a
  /// `Window`, not a `WindowGroup` (see `reset()`'s own comment), so it is
  /// only ever seeded once, at construction, and re-seeded whenever `reset()`
  /// fires — which is `.onDisappear`, i.e. once per *close*. That reseeds a
  /// window that is about to show a blank form for its next video, which is
  /// exactly right when the next thing to happen is a fresh Add. But it does
  /// nothing for the ordinary sequence of close the intake, open Settings,
  /// change something, close Settings, reopen the intake: the reseed already
  /// happened at the first close, nothing re-runs it before the second open,
  /// and the model sits on the Settings change every field it seeded from
  /// still describes the value *before* that edit. `IntakeWindow` calls this
  /// from `.onAppear`, before the clipboard prefill, so every open re-reads
  /// the store regardless of whether anything changed.
  ///
  /// **Deliberately narrower than `reset()`.** `reset()` also clears
  /// `linkText`, `name`, `quality`, the trim fields and
  /// `wantsToSaveDefaults` — all correct there, because `reset()` only ever
  /// runs between one video and the next. An open, by contrast, can land on
  /// a window that already has a link typed or a fetch in flight (the
  /// window does not always start from a close), and clobbering that would
  /// be a second bug in the same neighbourhood as the one this fixes. So this
  /// touches only the fields a fresh video does not own: the four
  /// preferences, the panel's persisted expansion, and the fallback flag
  /// that is a pure function of the destination the store just handed back.
  func reseedFromPreferences() {
    qualityCap = preferences.qualityCap
    output = preferences.output
    chatSize = preferences.chatSize
    folder = preferences.destination
    destinationFellBack = preferences.storedDestinationIsMissing
    isOptionsExpanded = preferences.optionsPanelIsExpanded
  }

  /// Carries a Watching finding into this form: the archive id becomes the
  /// link, and its channel's frozen settings are applied over whatever this
  /// window was seeded with.
  ///
  /// **Before any `load()`, deliberately — the same ordering
  /// `IntentSubmission.submit` already depends on, for the same reason (see
  /// that type's own comment).** `load()` reads `output` to decide whether
  /// resolution must skip a rendition a composite cannot use, and reads
  /// `qualityCap` to pick the rendition at all. This method only ever sets
  /// properties — it never calls `load()` itself — so the caller has to run
  /// it first: `IntakeWindow` does, in `.onAppear`, before its own
  /// `.task(id: model.linkText)` fires `load()` for the newly-set link.
  /// Applied afterwards, `quality` would resolve against whichever policy was
  /// already in place and end up naming a rendition nobody asked for.
  /// **The destination gets the same unreachable-folder check
  /// `Preferences.destination` gives the standing default, not a second,
  /// unchecked assignment.** `Watch.Settings.destination` is a bare
  /// `URL(filePath:)` — it has no opinion about whether that path still
  /// resolves, because freezing a channel's settings at add-time (this
  /// type's own doc comment) has nothing to do with whether the drive is
  /// mounted months later when a finding fires. Skipping this check would
  /// hand `folder` a dead path silently: `QueueEngine.move` creates any
  /// destination it is given with `withIntermediateDirectories: true`, so an
  /// unplugged `/Volumes/Archive/SomeChannel` would come back as a brand-new
  /// empty directory on the boot volume instead of a warning (design doc
  /// §6.2). Reuses `fileExists`, the same injected check `destinationCollision`
  /// already uses, rather than a second mechanism — and reuses
  /// `destinationFellBack`/`Preferences.factoryDestination`, the same flag and
  /// fallback `reseedFromPreferences()` already surfaces, so `IntakeWindow`'s
  /// existing "Oxbow will use Downloads" warning fires here for free.
  func apply(_ pending: PendingIntake) {
    linkText = pending.archiveID
    qualityCap = pending.settings.qualityCap
    output = pending.settings.output
    chatSize = pending.settings.chatSize
    let destination = pending.settings.destination
    if fileExists(destination) {
      folder = destination
      destinationFellBack = false
    } else {
      folder = Preferences.factoryDestination(homeDirectory: homeDirectory)
      destinationFellBack = true
    }
  }

  // MARK: - The link

  var target: TwitchLink.Target? { TwitchLink.parse(linkText) }

  /// Something was typed and it is not a Twitch address. An empty field is
  /// not an error, it is the starting state.
  var isLinkUnrecognized: Bool {
    !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && target == nil
  }

  var isLoadingMetadata: Bool {
    if case .loading = metadata { return true }
    return false
  }

  var metadataFailure: String? {
    guard describesCurrentLink, case .failed(let message) = metadata else { return nil }
    return message
  }

  var info: VideoInfo? {
    guard describesCurrentLink, case .loaded(let info) = metadata else { return nil }
    return info
  }

  /// Whether the settled metadata is this link's, rather than the one it
  /// replaced.
  private var describesCurrentLink: Bool {
    guard let identifier = metadataIdentifier, let target else { return false }
    return identifier == target.identifier
  }

  /// Fetches the pasted link's metadata, outside the queue (design doc §3),
  /// and settles into `.loaded` or `.failed`. Both settled states fill in a
  /// name — from the video's own metadata, or from the id or slug when the
  /// fetch failed.
  func load() async {
    guard let target else {
      metadata = .idle
      metadataIdentifier = nil
      return
    }

    generation += 1
    let issued = generation
    metadata = .loading

    do {
      let info = try await fetchInfo(target.identifier)
      guard issued == generation else { return }
      metadata = .loaded(info)
      metadataIdentifier = target.identifier
      // Resolve the standing cap against what this video actually offers.
      // Replaces the blanket clear: whatever was picked for the last video is
      // still not necessarily on offer here, and the cap is what survives.
      quality = QualityLadder.resolve(
        qualityCap, in: info.qualities, forComposite: output == .videoWithChat)
      // And the trim with it, for the same reason but more so: a quality that
      // does not exist is merely ignored, while a trim from a longer video
      // fails its bounds check and leaves the window refusing to add a job it
      // never described. Cleared explicitly — collapsing the section no longer
      // empties it, by design, so this cannot lean on that any more.
      trimStartText = ""
      trimEndText = ""
      isTrimExpanded = false
      name = OutputNaming.baseName(
        streamer: info.streamer,
        date: info.createdAt,
        title: info.title,
        calendar: calendar,
        reservingSuffixBytes: OutputSuffix.longestBytes)
    } catch is CancellationError {
      // The user typed on and this fetch was superseded. Not a failure to
      // report: the replacement is already on its way and will settle the
      // state, and `generation` cannot be relied on to hide this — the
      // replacement has not necessarily incremented it yet.
      return
    } catch {
      guard issued == generation else { return }
      metadata = .failed(Self.message(for: error))
      metadataIdentifier = target.identifier
      quality = ""
      name = OutputNaming.sanitized(
        target.identifier, reservingSuffixBytes: OutputSuffix.longestBytes)
    }
  }

  // MARK: - Quality

  /// Empty until metadata arrives, and empty after a failure — which the
  /// picker renders as nothing but "Best available", the same thing an empty
  /// `quality` means to the CLI.
  var qualities: [StreamQuality] { info?.qualities ?? [] }

  /// The quality picker's setter. Sets the rendition **and** re-derives the
  /// cap, which is what keeps an explicit pick from being lost on the next
  /// video and what makes an untouched picker a no-op for the store.
  func selectQuality(_ name: String) {
    quality = name
    guard !name.isEmpty else {
      qualityCap = .best
      return
    }
    guard let picked = qualities.first(where: { $0.name == name }),
          let bucketed = QualityLadder.bucket(picked)
    else { return }
    qualityCap = bucketed
  }

  /// The rung a save would write, when it differs from what is on screen.
  /// Nil when the two agree, which is the common case — so the footnote only
  /// appears when it has something to say (§3.8).
  ///
  /// **Always `qualityCap` itself, never a recomputation from `quality`** —
  /// that is the value `saveDefaultsIfRequested()` actually writes, and a
  /// note that re-bucketed the on-screen rendition instead could name a rung
  /// other than the one that gets saved.
  ///
  /// Two distinct ways the two can disagree, both checked: the pick can be an
  /// inexact rendition of a rung it does resolve to (`picked.shortSide !=
  /// ceiling` — `900p30` picked under a `.p720` cap, still bucketing to
  /// `.p720`, but not itself the canonical 720-line rendition), or the seeded
  /// cap can simply differ from what this pick would bucket to (`bucketed !=
  /// qualityCap` — an *untouched* picker whose cap resolved upward because
  /// the video offers nothing at or under the ceiling: §3.3's own example,
  /// cap `.p720` against a video offering only `1080p60`). Accept the second
  /// case deliberately: the note reads "Saved as Up to 720p" next to a
  /// visible `1080p60` selection, which is exactly true, and surfacing that
  /// gap is the entire purpose of this footnote.
  var savedQualityNote: QualityCap? {
    guard !quality.isEmpty,
          let picked = qualities.first(where: { $0.name == quality }),
          let bucketed = QualityLadder.bucket(picked),
          let ceiling = bucketed.ceiling,
          picked.shortSide != ceiling || bucketed != qualityCap
    else { return nil }
    return qualityCap
  }

  /// `bitsPerSecond x duration`, matching what the WPF app offers (§6). Nil
  /// without metadata, because there is no duration to multiply by — a
  /// zero would read as a real estimate of nothing.
  func estimatedBytes(for quality: StreamQuality) -> Int? {
    guard let duration = effectiveDuration else { return nil }
    return quality.estimatedBytes(over: duration)
  }

  /// One row of the quality picker.
  ///
  /// The pixel size is shown alongside the name because the name does not
  /// always imply it. A VOD's `480p30` is 852x480, not 854 or 640; a clip's
  /// name comes from upstream's `{quality}p{framerate}` and degenerates to
  /// things like `720p0` on older clips, where the resolution is the only
  /// legible part. And when a clip carries no bitrate there is no size
  /// estimate at all, so without it the row would be a bare `720p0-1`.
  ///
  /// Here rather than in the view so it can be tested, like every other rule
  /// the sheet obeys.
  func label(for quality: StreamQuality) -> String {
    var label = quality.name
    if !quality.resolution.isEmpty { label += " · \(quality.resolution)" }
    // `bytes == 0` is not an estimate of nothing, it is the absence of one:
    // older clips carry `bitrate: 0` for every rendition, and "about Zero KB"
    // reads as a fact rather than as a missing input.
    guard let bytes = estimatedBytes(for: quality), bytes > 0 else { return label }
    // "about", because it is bitrate x duration and nothing more (§6).
    return "\(label) — about \(Int64(bytes).formatted(.byteCount(style: .file)))"
  }

  // MARK: - Trim

  /// Clips have no trim options, so they are hidden rather than disabled
  /// (design doc §8). Nothing to hide before a link parses, either.
  var showsTrimOptions: Bool {
    if case .video = target { return true }
    return false
  }

  /// Off by default, and turning it off clears the fields rather than merely
  /// ignoring them. A trim that survives behind an unchecked box is state the
  /// window is not showing, and the job would trim for a reason nothing on
  /// screen explains.
  /// Whether the trim section is open. **Presentation only — a closed section
  /// still trims.**
  ///
  /// It began as a switch that cleared both fields when turned off, which was
  /// right for a checkbox and wrong for a disclosure triangle: that reads as
  /// "hide the details", so collapsing it to reclaim window space silently
  /// destroyed a trim the user had set. Neither does closing it *disable* the
  /// trim, which would be worse — a set value that quietly stops applying is
  /// hidden state, and the collapsed row shows the range precisely so there is
  /// none. What you set is what you get; the triangle only decides whether you
  /// can see the controls.
  var isTrimExpanded = false

  /// Both conditions, not either: a clip has no trim options at all, and an
  /// unchecked box means the whole video.
  /// Clips have no trim at all; a VOD always may. The section being closed is
  /// not part of this — see `isTrimExpanded`.
  private var isTrimming: Bool { showsTrimOptions }

  var trimStart: Duration? { isTrimming ? Timecode.parse(trimStartText) : nil }
  var trimEnd: Duration? { isTrimming ? Timecode.parse(trimEndText) : nil }

  /// `info.duration`, narrowed to the trim window when one is set. Every
  /// duration-based estimate — the size shown per quality here, and the
  /// composite's own `duration` in `composedTemplate()` below, which
  /// `FFmpegProgressParser` divides by for its fraction and ETA — has to use
  /// this instead of `info.duration` directly, or a trimmed job's numbers
  /// describe the untrimmed VOD.
  var effectiveDuration: Duration? {
    guard let fullDuration = info?.duration else { return nil }
    return (trimEnd ?? fullDuration) - (trimStart ?? .zero)
  }

  /// What the trim section says about itself when it is closed, or nil when it
  /// is not trimming at all. The collapsed row has to carry this: a section
  /// that is applying a range while showing nothing is exactly the hidden
  /// state the disclosure was accused of creating.
  var trimSummary: String? {
    guard isTrimming, !trimIsInvalid else { return nil }
    switch (trimStart, trimEnd) {
    case (nil, nil): return nil
    case (let start?, let end?): return "\(Timecode.format(start)) – \(Timecode.format(end))"
    case (let start?, nil): return "from \(Timecode.format(start))"
    case (nil, let end?): return "up to \(Timecode.format(end))"
    }
  }

  /// A typed trim time that is neither empty nor a time, or an end at or
  /// before the start. Either would reach the CLI as an argument that fails
  /// minutes into a download, so Add refuses first.
  var trimIsInvalid: Bool {
    guard isTrimming else { return false }
    if !Timecode.isBlankOrValid(trimStartText) || !Timecode.isBlankOrValid(trimEndText) {
      return true
    }
    if let start = trimStart, let end = trimEnd, end <= start { return true }
    // Against the video's own length, not just against each other. Without
    // this a start past the end is "valid", Add stays enabled, and the
    // refusal arrives from the CLI minutes into a download.
    if let total = info?.duration {
      if let start = trimStart, start >= total { return true }
      if let end = trimEnd, end > total { return true }
    }
    return false
  }

  // MARK: - Composing the job

  /// `quality` translated to what `-q` actually needs — see
  /// `StreamQuality.commandLineValue`. `quality` itself stays the picker's
  /// name (matched against `qualities` by `compositeQuality` and used to
  /// look the row back up for its label), so this is resolved only where a
  /// request is actually built. Falls back to `quality` unchanged — which is
  /// only ever `""`, "best available" — when it names no known rendition.
  private var commandLineQuality: String {
    qualities.first(where: { $0.name == quality })?.commandLineValue ?? quality
  }

  /// The quality a composite will actually download. "Best available" leaves
  /// the resolution unknown, which is fatal when the chat's height must equal
  /// the video's — so a composite resolves it to a concrete rendition and
  /// passes it explicitly. Video-only keeps today's behaviour, where empty
  /// means the CLI picks.
  ///
  /// **An explicit pick is honoured even when it cannot be composited — never
  /// silently swapped for one that can.** `docs/design/chat-and-render.md`
  /// already records the cost of that shortcut: a name carrying a
  /// disambiguating `-<digits>` suffix (`-q 480p30-1`) silently downloads the
  /// highest rendition instead when passed unstripped, exit 0, no warning —
  /// handing someone the wrong video and calling it a success, which is worse
  /// than either honest outcome. (`StreamQuality.commandLineValue` strips
  /// that suffix before it reaches `-q`; this comment is about the hazard of
  /// silent substitution in general, not that specific one.) So this only
  /// falls back to the first rendition `CompositeGeometry` can parse when
  /// `quality` is empty, meaning the user asked for "best available" and
  /// never named a rendition to begin with. An explicit pick that turns out
  /// unparseable (`CompositeGeometry.init?(quality:)` fails for a rendition
  /// with no pixel width — see `compositeProblem`) is returned as-is;
  /// `composedTemplate()` then refuses rather than substituting, and
  /// `compositeProblem` is what says why.
  private var compositeQuality: StreamQuality? {
    if !quality.isEmpty, let named = qualities.first(where: { $0.name == quality }) {
      return named
    }
    return qualities.first { CompositeGeometry(quality: $0) != nil }
  }

  /// Why `.videoWithChat` cannot be added right now, or nil when it can (or
  /// when `.video` is selected, where no quality decision is even made).
  ///
  /// This is only reachable for a clip. A VOD's `VideoInfo.parseQualities`
  /// skips any m3u8 variant with no `RESOLUTION` attribute outright, so every
  /// `StreamQuality` it emits already has one. A clip's `clipResolution` has
  /// no such filter — Twitch does not always backfill dimensions on an older
  /// clip's rendition, and that rendition still reaches the picker with an
  /// empty `resolution`. Picking exactly that one is a silent dead end
  /// without this: `compositeQuality` honours the explicit pick (by design,
  /// see its doc comment), `CompositeGeometry` then fails to parse it, and
  /// `composedTemplate()` returns nil with nothing on screen explaining why.
  ///
  /// An odd width or height in the metadata is not a failure case here:
  /// `CompositeGeometry.init?` rounds those down to even itself (see its doc
  /// comment — Twitch's clip API derives dimensions arithmetically and can
  /// report an odd value for a stream that decodes even), so a rendition
  /// like `480p30-Portrait`'s nominal `480x853` composes fine.
  var compositeProblem: String? {
    guard output == .videoWithChat,
          let selected = compositeQuality,
          CompositeGeometry(quality: selected) == nil
    else { return nil }
    return """
      Twitch never recorded pixel dimensions for \(selected.name), so its \
      chat column cannot be sized to match. Pick another quality.
      """
  }

  /// Why `.videoWithChat` cannot be added for this video, or nil when it can
  /// (and always nil for `.video`, which needs no chat at all).
  ///
  /// Two reasons, both refusals on the facts rather than guesses about them.
  ///
  /// **The metadata fetch failed.** The composite is derived from metadata
  /// end to end — a rendition to size the chat column against, a duration to
  /// report encoding progress against — so without it there is nothing to
  /// build. The sheet stays usable for `.video`, which is the whole point of
  /// the id-derived fallback name: the download still works, only the chat
  /// does not. This case matters more since `.videoWithChat` became the
  /// default (docs/design/compositing.md §3): before, a failed fetch left
  /// the sheet sitting on an output that still worked.
  ///
  /// **The clip's broadcast is gone.** A clip carries no chat of its own — it
  /// is reconstructed from the broadcast the clip was cut from — so when
  /// Twitch has expired that broadcast there is nothing to download.
  /// `VideoInfo.hasDownloadableChat` reads upstream's own predicate off the
  /// same `info` payload the chat downloader will read.
  ///
  /// **Refusing up front is worth more here than explaining afterwards.**
  /// `JobTemplate.makeJob` appends the chat step first, deliberately, so it
  /// claims the network slot ahead of the video download. The chat step would
  /// abort in seconds; the video step, which has no `dependsOn`, would then
  /// download in full into a workspace intermediate carrying no destination;
  /// and the render, composite and assemble steps would all sit blocked
  /// behind the failed chat. Only `assemble` ever delivers a file, so the
  /// user would wait out an entire video download and receive nothing.
  ///
  /// Deliberately does *not* disable the clip: only its chat is unavailable,
  /// and `.video` downloads it perfectly well. Saying which of the two
  /// choices still works is the difference between an explanation and a dead
  /// end — the same reason `compositeProblem` ends in "Pick another quality".
  var chatProblem: String? {
    guard output == .videoWithChat else { return nil }

    if metadataFailure != nil {
      return """
        Without this video's details, Oxbow cannot size the chat column or \
        time the encode. Choose "Video" to download the video itself.
        """
    }

    guard let info, !info.hasDownloadableChat else { return nil }
    return """
      This clip's original broadcast is no longer on Twitch, so its chat \
      cannot be downloaded. Choose "Video" to download the clip itself.
      """
  }

  /// Spec §2.7. While chat is unavailable, the output on screen is a
  /// workaround for this video's defect rather than a statement of
  /// preference — and saving it would turn chat off for every future
  /// download from one tick of an opt-in box.
  ///
  /// **Mirrors `chatProblem`'s own two conditions, not just one of them** —
  /// this has to hold whenever `chatProblem` would be showing, which is
  /// deliberately checked without `chatProblem`'s `output == .videoWithChat`
  /// guard: the whole point is to catch the moment *after* the user has
  /// already switched away to `.video` because of the problem, which is
  /// exactly when `chatProblem` itself goes back to nil. A version that
  /// only checked `info.hasDownloadableChat` missed the metadata-failure
  /// case entirely: a failed fetch leaves `info` nil, so a stored
  /// `.videoWithChat` default, switched to `.video` only because this
  /// video's details never arrived, would otherwise be saved as `.video`
  /// permanently the moment the checkbox was ticked.
  var withholdsOutputFromSave: Bool {
    if metadataFailure != nil { return true }
    guard let info else { return false }
    return !info.hasDownloadableChat
  }

  /// Spec §3.7's shape, for a different field: the chat text size picker only
  /// renders while `output == .videoWithChat` (see `IntakeWindow`), so
  /// saving it while `.video` is selected would write a value from a control
  /// nobody on screen can currently see. Unlike `withholdsOutputFromSave`,
  /// this reads the plain `output` on screen rather than accounting for
  /// `chatProblem` — there is no equivalent workaround case here: switching
  /// to `.video` because of a refusal hides the same picker for the same
  /// reason a deliberate switch does, so one condition covers both.
  var withholdsChatSizeFromSave: Bool { output != .videoWithChat }

  /// True once *this link's* fetch has settled either way. `.failed` counts:
  /// the sheet stays usable, with a name derived from the id or slug.
  var hasSettledMetadata: Bool {
    guard describesCurrentLink else { return false }
    switch metadata {
    case .loaded, .failed: return true
    case .idle, .loading: return false
    }
  }

  /// The file already sitting where this job would deliver, if there is one.
  ///
  /// This is what the sheet warns about and what `composedTemplate()` turns
  /// into `JobTemplate.replacesExistingFile` — one definition, so the
  /// warning the user is shown and the permission the job carries cannot
  /// drift apart. A job can never authorize replacing a file over a warning
  /// nobody saw.
  ///
  /// Gated on settled metadata because before that the name is a
  /// placeholder, and a warning about a file this job will never write is
  /// just noise. Deliberately NOT gated on `canAdd`: that is defined as
  /// `composedTemplate()` returning something, and `composedTemplate()`
  /// reads this — the pair would recurse forever.
  ///
  /// One `stat` per evaluation, on a path the user chose. Cheap enough to
  /// stay derived rather than cached, and derived is what keeps it honest
  /// when `name` changes under it — from a fresh `load()`, or from a name
  /// picked in the Save panel (`IntakeWindow.chooseFolder()`).
  var destinationCollision: URL? {
    guard hasSettledMetadata, let folder else { return nil }
    let destination = folder.appending(path: outputBaseName + OutputSuffix.video)
    return fileExists(destination) ? destination : nil
  }

  // MARK: - Not enough room

  /// A volume that will not hold this job, and the cheapest way out of it.
  struct SpaceWarning: Equatable {
    var needed: Int64
    var available: Int64
    var volumeName: String
    /// A lower rendition that would actually fit, or nil when none would.
    var remedy: Remedy?

    struct Remedy: Equatable {
      var qualityName: String
      var needed: Int64
    }
  }

  /// What this job needs against what the volume has, when the first exceeds
  /// the second.
  ///
  /// **Advisory, never a gate.** `canAdd` does not read this, deliberately:
  /// the estimate behind it is soft (`docs/design/disk-preflight.md` §3.2),
  /// the user knows things it does not — a snapshot about to be thinned, a
  /// drive about to be plugged in — and refusing them would be refusing on
  /// worse information than they have. It is the same contract
  /// `destinationCollision` carries, and having one warning that blocks and
  /// one that does not would teach the user that neither can be trusted.
  ///
  /// Gated on settled metadata for the same reason as the collision warning:
  /// before that the duration is a placeholder and any number derived from it
  /// is fiction.
  ///
  /// One volume read per evaluation, on a path the user chose. Derived rather
  /// than cached, which is what keeps it honest as the quality, trim and
  /// output toggle move under it — all three change the answer.
  var spaceWarning: SpaceWarning? {
    guard hasSettledMetadata,
          let folder,
          let duration = effectiveDuration,
          let quality = estimatedQuality,
          let shortfall = shortfall(for: quality, over: duration, in: folder)
    else { return nil }

    return SpaceWarning(
      needed: shortfall.needed,
      available: shortfall.available,
      volumeName: shortfall.volumeName,
      remedy: remedy(under: quality, over: duration, in: folder))
  }

  /// The rendition this job will actually download, which is what the estimate
  /// has to be about. A composite has its own answer already — the geometry
  /// must parse — and a plain download takes the picker's selection, falling
  /// back to the first on offer for "best available".
  private var estimatedQuality: StreamQuality? {
    switch output {
    case .videoWithChat: return compositeQuality
    case .video: return qualities.first { $0.name == quality } ?? qualities.first
    }
  }

  private func estimate(for quality: StreamQuality, over duration: Duration) -> SpaceEstimate {
    SpaceEstimate(
      quality: quality,
      duration: duration,
      // A plain download renders no chat and composites nothing, so both of
      // those terms must be absent rather than merely small.
      composite: output == .videoWithChat ? CompositeGeometry(quality: quality) : nil)
  }

  private func shortfall(
    for quality: StreamQuality,
    over duration: Duration,
    in folder: URL) -> VolumeSpace.Shortfall?
  {
    let estimate = estimate(for: quality, over: duration)
    return volumeSpace.shortfall(
      needingWorkspace: estimate.total,
      delivered: estimate.delivered,
      workspace: workspaceVolumePath,
      destination: folder)
  }

  /// The largest rendition smaller than `quality` that would actually fit.
  ///
  /// **Offering one that also does not fit is worse than offering none** — it
  /// costs the user a click to learn nothing — so each candidate is run
  /// through the same check rather than assumed to help. Largest-that-fits
  /// rather than smallest, because the point is to lose as little quality as
  /// the disk allows.
  private func remedy(
    under quality: StreamQuality,
    over duration: Duration,
    in folder: URL) -> SpaceWarning.Remedy?
  {
    let current = estimate(for: quality, over: duration).total
    let fitting = qualities
      .filter { $0.name != quality.name }
      .map { (candidate: $0, needed: estimate(for: $0, over: duration).total) }
      .filter { $0.needed < current }
      .filter { shortfall(for: $0.candidate, over: duration, in: folder) == nil }

    guard let best = fitting.max(by: { $0.needed < $1.needed }) else { return nil }
    return SpaceWarning.Remedy(qualityName: best.candidate.name, needed: best.needed)
  }

  /// Exactly the condition under which `composedTemplate()` returns
  /// something — one definition, so the button's enabled state and what Add
  /// can actually build cannot drift apart.
  var canAdd: Bool { composedTemplate() != nil }

  /// The name every output of this job shares, sanitized and with room
  /// reserved for the longest suffix any of them can take.
  ///
  /// The reservation is over the suffix regardless of the current `output`:
  /// that setting can change after the name is derived, and a base name that
  /// had to be recomputed when it did would be a base name a rename could
  /// disagree with itself about (design doc §4).
  var outputBaseName: String {
    OutputNaming.sanitized(name, reservingSuffixBytes: OutputSuffix.longestBytes)
  }

  /// The job this sheet would add, or `nil` if it is not in a state to add
  /// one. Every disabled-Add rule in the design doc is a `guard` here.
  func composedTemplate() -> JobTemplate? {
    guard
      let target,
      let folder,
      hasSettledMetadata,
      !trimIsInvalid
    else { return nil }

    let base = outputBaseName
    func destination(_ suffix: String) -> URL { folder.appending(path: base + suffix) }

    var media: JobTemplate.Media?
    var chat: ChatRequest?
    var render: RenderRequest?
    var composite: CompositeRequest?

    switch output {
    case .video:
      switch target {
      case .video(let id):
        media = .video(VideoRequest(
          videoID: id,
          quality: commandLineQuality,
          trimStart: trimStart,
          trimEnd: trimEnd,
          destination: destination(OutputSuffix.video)))
      case .clip(let slug):
        media = .clip(ClipRequest(
          clipSlug: slug,
          quality: commandLineQuality,
          destination: destination(OutputSuffix.video)))
      }

    case .videoWithChat:
      // A clip whose parent broadcast Twitch has expired has no chat to
      // download, so this cannot produce the one file it promises.
      // `chatProblem` is the sentence for the refusal; the refusal itself
      // has to live here, or `canAdd` — which is defined as this returning
      // something — would admit a job that cannot deliver. One condition
      // read two ways, never two conditions that can drift apart.
      guard chatProblem == nil else { return nil }

      // The composite needs a concrete rendition to derive its geometry from
      // (see `compositeQuality`), and a duration to report FFmpeg progress
      // against. Neither is available without settled metadata.
      // The video and chat requests below get the trim window; the
      // composite's own `duration` has to match `effectiveDuration`, since
      // it is the total `FFmpegProgressParser` divides by for every
      // fraction and ETA it reports. The untrimmed `info.duration` would
      // leave the composite step's progress bar stuck around 15-20% when
      // the actual (trimmed) encode is nearly done, with an ETA counting
      // down against content that was never going to be encoded.
      guard let selected = compositeQuality,
            let geometry = CompositeGeometry(quality: selected),
            let duration = effectiveDuration
      else { return nil }

      // One file out: the media and the render are intermediates, so neither
      // gets a destination of its own — only the composite does, below.
      //
      // Clips get the same two choices as VODs (design doc §3). A clip has no
      // trim, and `chatdownload --id` takes a slug as readily as a VOD id, so
      // the only difference is which request type carries the identifier.
      switch target {
      case .video(let id):
        media = .video(VideoRequest(
          videoID: id, quality: selected.commandLineValue,
          trimStart: trimStart, trimEnd: trimEnd, destination: nil))
        chat = ChatRequest(
          videoID: id, trimStart: trimStart, trimEnd: trimEnd,
          format: .json, destination: nil)
      case .clip(let slug):
        media = .clip(ClipRequest(
          clipSlug: slug, quality: selected.commandLineValue, destination: nil))
        chat = ChatRequest(videoID: slug, format: .json, destination: nil)
      }
      render = RenderRequest(
        width: geometry.chatWidth,
        height: geometry.videoHeight,
        framerate: geometry.chatFramerate,
        fontSize: geometry.fontSize(for: chatSize),
        // Transient and immediately re-encoded, so encode it well: at the old
        // 3 Mbps default the composite carried two generations of lossy H.264
        // over text on flat backgrounds. VideoToolbox's speed is independent
        // of bitrate, so this costs only workspace disk.
        bitrateMbps: 12,
        destination: nil)
      composite = CompositeRequest(
        framerate: geometry.videoFramerate,
        duration: duration,
        destination: destination(OutputSuffix.video))
    }

    return JobTemplate(
      media: media,
      chat: chat,
      render: render,
      composite: composite,
      replacesExistingFile: destinationCollision != nil)
  }

  /// Adds the job. Returns whether it landed, so the sheet dismisses on a
  /// fact rather than on a hope: `QueueController.enqueue` is awaited all the
  /// way into the engine, and a refusal leaves the sheet open with
  /// `addFailure` saying why.
  @discardableResult
  func add() async -> Bool {
    guard let template = composedTemplate() else {
      addFailure = """
        Oxbow could not build that download. Check the link, the outputs, and \
        the destination folder.
        """
      return false
    }
    addFailure = nil
    await enqueue(template, outputBaseName)
    return true
  }

  /// Called by the window after a successful enqueue and never before it.
  /// Cancel discards, and `addFailure` is a job that was never composed —
  /// persisting the settings of either would be persisting a decision the
  /// user did not complete.
  func saveDefaultsIfRequested() {
    guard wantsToSaveDefaults else { return }
    // Read before any of the writes below — they all call
    // `Preferences.recordSave()`, which flips `hasSavedDefaults` to true, so
    // reading it after even one of them would make every save look like the
    // first.
    let isFirstSave = !preferences.hasSavedDefaults
    if let folder { preferences.destination = folder }
    if !withholdsChatSizeFromSave { preferences.chatSize = chatSize }
    if !withholdsOutputFromSave { preferences.output = output }
    // Writes `qualityCap` itself, never a recomputation from `quality`.
    // `selectQuality` is the only thing that ever changes `qualityCap`, and
    // it already handles every case correctly (§3.3, §3.7): a bucketable
    // pick sets a bucketed cap, an unbucketable one leaves the cap alone, and
    // clearing the pick sets `.best`. Re-deriving here from whatever
    // `quality` happens to be on screen reintroduces exactly the bug
    // `qualityCap` exists to prevent — an untouched picker whose resolved
    // rendition sits above or below the seeded cap would silently overwrite
    // it with that rendition's own bucket.
    preferences.qualityCap = qualityCap
    // The visible payoff for opting in, tied to an explicit act so it reads
    // as cause and effect rather than as the app moving furniture. Once
    // only, on the save that first sets `hasSavedDefaults` — a later save
    // must leave the panel exactly where the user put it, or every
    // subsequent Add would quietly re-collapse a panel someone had
    // deliberately reopened.
    if isFirstSave { isOptionsExpanded = false }
  }

  // MARK: - Failure text

  private static func message(for error: Error) -> String {
    switch error {
    case VideoInfoFetchError.helperFailed(_, let standardError) where !standardError.isEmpty:
      return "Oxbow could not read that video's details: \(firstLine(of: standardError))"
    case VideoInfoFetchError.helperFailed:
      return "Oxbow could not read that video's details. The link may be wrong, or the video private."
    case VideoInfoFetchError.unparseableOutput:
      return "Oxbow could not make sense of that video's details."
    default:
      return "Oxbow could not read that video's details: \(error.localizedDescription)"
    }
  }

  /// The CLI's useful sentence is the first line; the rest is a stack trace.
  private static func firstLine(of text: String) -> String {
    text
      .split(separator: "\n", omittingEmptySubsequences: true)
      .first
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? text
  }

}

/// The per-output suffix from the design doc, §4.
///
/// One case now, not five: intake no longer offers a bare chat download or a
/// bare chat render (see `DownloadOutput`), so the video suffix — shared
/// by a plain video and a composite alike, since a composite replaces the
/// video it stacks rather than accompanying it — is the only one left.
nonisolated enum OutputSuffix {
  static let video = ".mp4"

  /// The longest suffix any output can take, in UTF-8 bytes, computed from
  /// the suffixes themselves — a literal would quietly stop being the longest
  /// the first time one of them grows.
  static let longestBytes: Int = {
    let all = [video]
    return all.map(\.utf8.count).max() ?? 0
  }()
}

extension TwitchLink.Target {
  /// What the CLI's `--id` takes for either kind: upstream's `chatdownload`
  /// and `info` both accept a VOD id and a clip slug in the same parameter
  /// (design doc §8).
  var identifier: String {
    switch self {
    case .video(let id): id
    case .clip(let slug): slug
    }
  }
}
