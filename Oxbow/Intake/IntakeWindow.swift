import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OxbowKit

/// Paste a link, see what it is, choose which of its outputs you want, and
/// add the job. Every rule this window obeys lives in `IntakeModel`; this is
/// the rendering of it.
///
/// **A window, not a sheet.** A sheet cannot be taller than the window that
/// hosts it, and this form legitimately grew past that with the old render
/// options open — since deleted (docs/design/compositing.md §3, §8), but the
/// shape earned here is kept: a sheet meant either a clipped, scrolling form
/// or a queue window whose minimum size was dictated by its own modal —
/// both of which were tried, and both of which are the tail wagging the dog.
/// A window sizes itself, remembers what the user dragged it to, and closes
/// with ⌘W. This is the shape Transmission uses for the same job.
///
/// `Window` rather than `WindowGroup` in `OxbowApp`, so ⌘N re-focuses the one
/// that exists instead of stacking up five half-filled copies.
///
/// **A `Form`, not a hand-built stack.** The labels, their column, the row
/// spacing and the section grouping are all things macOS has an opinion about,
/// and `.formStyle(.grouped)` is that opinion — the same one System Settings
/// renders with. The previous layout drew its own `Text("Name").font(.caption)`
/// labels above each field and hard-coded a 60pt label column for the trim row,
/// which is how a Mac window ends up looking like a web page.
struct IntakeWindow: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: IntakeModel
  @State private var hostWindow: NSWindow?
  @State private var isAdding = false
  @FocusState private var isLinkFocused: Bool

  /// A finding waiting to be applied, from `OxbowApp`'s own `@State`.
  ///
  /// **A binding, not a plain value, so this window can clear it.** `OxbowApp`
  /// holds the one instance of this scene's worth of state across opens and
  /// closes (see `IntakeModel.reset()`'s own comment on why `Window` rather
  /// than `WindowGroup` matters here), so a pending finding this window does
  /// not clear after consuming would resurrect itself on the next ⌘N — the
  /// exact staleness bug the Add Channel window's missing reset caused.
  @Binding private var pendingIntake: PendingIntake?

  init(controller: QueueController, pendingIntake: Binding<PendingIntake?>) {
    _model = State(initialValue: IntakeModel(controller: controller))
    _pendingIntake = pendingIntake
  }

  /// For previews, and for anything else that wants to drive the sheet without
  /// an engine behind it — `IntakeModel`'s own init takes closures for exactly
  /// this reason, and this is what lets a preview reach them.
  ///
  /// `pendingIntake` defaults to a constant `nil`: no preview below exercises
  /// the Watching hand-off, so none of them need a real binding to clear.
  init(model: IntakeModel, pendingIntake: Binding<PendingIntake?> = .constant(nil)) {
    _model = State(initialValue: model)
    _pendingIntake = pendingIntake
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        source

        if model.hasSettledMetadata {
          // Trim before Download Options: which part of the video you want is
          // a property of the video, like its name, while the options panel
          // is about what to do with it — including where it lands, folded
          // in as of §2.1. Ordering it this way also stops the chat controls
          // inside that panel, which appear and disappear, from shoving the
          // trim section you were just setting down the window.
          if model.showsTrimOptions { trim }
          options
        }
      }
      .formStyle(.grouped)

      Divider()
      footer
    }
    // A minimum, not a size. The window's own size is the user's business and
    // `.defaultSize` in `OxbowApp` sets where it starts; all this view owes is
    // a floor below which its controls would start colliding.
    .frame(minWidth: 460, minHeight: 320)
    .background(HostWindowReader(window: $hostWindow))
    .defaultFocus($isLinkFocused, true)
    // Re-reads the four standing preferences before anything else runs, so a
    // Settings change made while the window was closed is on screen the
    // moment it reopens rather than only after the *next* close — see
    // `IntakeModel.reseedFromPreferences()`. Ordered before the clipboard
    // prefill below on general principle (seed from the store, then let the
    // clipboard override the one field it owns), though the two do not
    // actually touch overlapping fields today.
    .onAppear {
      model.reseedFromPreferences()
      // Seeded like a paste, so the fixture run goes down the same path a
      // person does — the debounced `.task(id:)` below sees the link change
      // and fetches, and `QueueController.fetchInfo` hands back canned
      // metadata. Deliberately ahead of the clipboard, which it stands in for.
      #if DEBUG
      if let link = ScreenshotFixture.link { model.linkText = link }
      #endif
      // A pending finding wins over the clipboard: someone who clicked Add on
      // a specific video did not mean whatever happens to be on their
      // pasteboard. Cleared immediately after applying — this is the one
      // consumption point, and leaving it set would resurrect the same
      // finding on the next ⌘N.
      if let pendingIntake {
        model.apply(pendingIntake)
        self.pendingIntake = nil
      } else {
        prefillFromClipboard()
      }
    }
    // Trim has to be opened *after* the metadata lands, not with the link:
    // `load()` clears `isTrimExpanded` when it arrives, because a trim carried
    // over from a longer video fails its bounds check. `name` is assigned in
    // the same breath as that clear, so it is the signal that the clear has
    // already happened.
    #if DEBUG
    .onChange(of: model.name) { _, newName in
      guard ScreenshotFixture.opensTrim, !newName.isEmpty else { return }
      model.isTrimExpanded = true
    }
    #endif
    // Turning on chat or trim adds a section to a form whose footer is pinned,
    // so the new section arrives below the fold — the one you just asked for is
    // the one you cannot see. Grow the window to meet it.
    .onChange(of: desiredContentHeight) { _, wanted in resize(toFit: wanted) }
    .onChange(of: hostWindow) { _, _ in resize(toFit: desiredContentHeight) }
    // The scene outlives the window, so closing it has to do what dismissing
    // a sheet would have done for free. See `IntakeModel.reset()` — and, for
    // the open half of the same problem, `reseedFromPreferences()` above.
    .onDisappear(perform: model.reset)
    // Debounced here rather than in the model so the model stays synchronous
    // to test: `.task(id:)` already cancels the previous fetch when the link
    // changes, and the sleep keeps a half-typed URL from being fetched.
    .task(id: model.linkText) {
      guard model.target != nil else { return }
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      await model.load()
    }
  }

  // MARK: - Sections

  /// The link, and what came back for it.
  private var source: some View {
    Section {
      // A `Form` turns a `TextField`'s first argument into its label, which is
      // not where this belongs — the field is the whole point of the row and
      // wants the hint inside it. `prompt:` is the placeholder, `"Link"` the
      // label VoiceOver reads.
      TextField("Link", text: $model.linkText, prompt: Text("Twitch VOD or clip link"))
        .focused($isLinkFocused)

      if model.isLinkUnrecognized {
        Label("That does not look like a Twitch VOD or clip address.", systemImage: "xmark.circle")
          .font(.callout)
          .foregroundStyle(.red)
      } else if let failure = model.metadataFailure {
        // A failure, not a dead end: `model.name` has fallen back to the id
        // or slug — visible in the delivered-filename caption further down,
        // in the options panel's footer — and the window still works. The
        // card keeps its place so the failure does not also collapse the
        // layout.
        VideoCard(.unavailable(title: model.name))
        Label(failure, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.orange)
      } else if let info = model.info {
        VideoCard(info: info)
      } else if model.target != nil {
        // The link parses, so a fetch is coming. Draw the card now, in its
        // loading state, rather than letting it appear whole when the network
        // answers and shove everything below it down the window.
        VideoCard(.loading)
      }
    }
  }

  /// Names the folder rather than saying "the destination", so the sentence
  /// is checkable at a glance against wherever the folder itself is showing
  /// — the `Save to` row inside the panel above this footer when it is
  /// expanded, or the collapsed header's own summary when it is not.
  private func collisionWarning(for collision: URL) -> String {
    let folder = collision.deletingLastPathComponent().lastPathComponent
    return "A file with this name is already in \(folder) — adding this will replace it."
  }

  /// Everything that used to be two sections — `Download` and `Save to` —
  /// folded into one collapsible panel with the opt-in checkbox at the
  /// bottom (design doc §2.1). They belong together: both are the same
  /// decision, what this job does and where it lands, and splitting them
  /// across separate always-open sections is what let the destination sit
  /// two screens above the box that claims to remember it.
  ///
  /// **Collapsed is the steady state** (§2.6): the header carries a summary
  /// so a closed drawer never hides where the file is actually going.
  ///
  /// **Forced open whenever `chatProblem` or `compositeProblem` is showing**
  /// (§2.7) — both render inside this panel and both disable Add, so a
  /// closed panel would grey Add out with the explanation sealed inside it.
  /// That forcing is `IntakeModel.isOptionsEffectivelyExpanded`'s job, not
  /// this view's: the view only reads and writes through
  /// `isOptionsEffectivelyExpandedBinding`, which is what keeps the forced,
  /// transient expansion from ever reaching the stored preference.
  ///
  /// **`spaceWarning` is deliberately NOT inside the collapsible section.**
  /// It started there, reasoning that because it is advisory
  /// — it does not gate Add, so it should not join `chatProblem` and
  /// `compositeProblem` in forcing the panel open — it was fine to leave it
  /// wherever else it landed. That reasoning answers the wrong question:
  /// §2.7 governs what forces the panel open, not what a collapsed panel is
  /// allowed to hide. §2.6 makes collapsed the steady state, and §2.5 has
  /// the app collapse the panel itself the first time someone saves
  /// defaults — so a warning shown only while expanded is hidden from
  /// exactly the population most likely to need it: someone whose saved
  /// destination now sits on a volume that is short of space.
  /// `docs/design/disk-preflight.md` §2 grounds the whole warn-don't-block
  /// design on "at intake there is a person" who sees the estimate and
  /// decides; a warning nobody sees collapses back into that document's own
  /// §1 failure mode. So it lives in the `Section`'s footer instead, now
  /// alongside the delivered-filename caption and the collision warning —
  /// both used to sit under the now-deleted Name section (§1) and have moved
  /// down into this same footer, rather than into the drawer, for the
  /// identical reason: none of the three is something a collapsed panel
  /// should be allowed to hide. `destinationFellBack` stays inside
  /// deliberately — see its own comment below.
  ///
  /// **The encode-duration note does NOT join them, unlike an earlier version
  /// of this panel.** It used to: `.videoWithChat` is the factory default and
  /// collapsed is the steady state, so a note only rendered inside the drawer
  /// was hidden on the default path through this window. That reasoning was
  /// sound, and it is reversed here anyway, on the app's author's own
  /// explicit instruction — the note reads as an in-the-moment explanation of
  /// what the checkbox above it is about to commit to, not a standing warning
  /// about the destination the way `spaceWarning` is, and it now sits below
  /// the checkbox, inside the drawer. The cost is real and accepted: it is
  /// invisible on the collapsed path, which is most downloads (§2.6).
  @ViewBuilder
  private var options: some View {
    Section {
      disclosureHeader(
        "Download Options",
        isExpanded: model.isOptionsEffectivelyExpanded,
        trailing: {
          // Only when collapsed: an expanded panel already shows every one
          // of these values in full, so a summary here too would just be
          // saying the same thing twice.
          if !model.isOptionsEffectivelyExpanded {
            Text(model.optionsSummary)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        },
        toggle: { model.isOptionsEffectivelyExpandedBinding.toggle() })

      if model.isOptionsEffectivelyExpanded {
        // Two choices, not three independent toggles: a chat render in
        // isolation has little use, and the composite is what makes it worth
        // producing at all (design doc §3). `DownloadOutput` already
        // narrowed to this pair; this is just its rendering.
        //
        // Deliberately no `.pickerStyle(.radioGroup)` here any more, unlike
        // the section this replaced. §2.1's own mockup draws every row in
        // this panel — including this one — as a single label-and-value
        // line (`Download    Video + chat  ⌄`), matching the `Picker` below
        // it rather than the old pair of radio buttons; a mixed drawer with
        // one row styled differently from its neighbors would read as an
        // afterthought bolted onto the new layout rather than as part of it.
        Picker("Download", selection: $model.output) {
          Text(isClip ? "Clip + chat" : "Video + chat").tag(DownloadOutput.videoWithChat)
          Text(isClip ? "Clip" : "Video").tag(DownloadOutput.video)
        }

        // Directly under the picker: the quality is a property of the media
        // download, and nothing else on this sheet reads it. Bound through
        // `selectQuality` rather than `$model.quality` directly — a bare
        // binding would leave `qualityCap` sitting at whatever seeded it, so
        // an explicit pick here would quietly fail to survive into the next
        // save (§3.3).
        Picker("Quality", selection: qualityBinding) {
          Text("Best available").tag("")
          ForEach(model.qualities, id: \.name) { quality in
            Text(model.label(for: quality)).tag(quality.name)
          }
        }

        // `chatProblem == nil` as well as the output: offering a text size
        // for chat that cannot be downloaded, above a row explaining that it
        // cannot, is a control for something that will never happen.
        if model.output == .videoWithChat, model.chatProblem == nil {
          // The one control the deleted render-options form left behind (see
          // docs/design/compositing.md §4, §8): a fixed size cannot serve
          // both a laptop window and a TV across the room. Rendered as a
          // pulldown now, matching `Download` and `Quality` above — it was a
          // segmented control until the mockup asked for `Medium ⌄` like
          // every other row in this panel, so it drops the explicit
          // `.pickerStyle` and takes the same default menu style they do.
          Picker("Chat text size", selection: $model.chatSize) {
            Text("Small").tag(ChatSize.small)
            Text("Medium").tag(ChatSize.medium)
            Text("Large").tag(ChatSize.large)
          }
        }

        destination

        // Stays inside the drawer, unlike `spaceWarning` below — §2.6 names
        // this exact user (a saved destination that has since vanished) and
        // makes the collapsed header's summary the mitigation:
        // `optionsSummary` genuinely reads "Downloads" rather than the
        // folder that fell back, so the collapsed state is not lying about
        // where the file is going. There is no equivalent for disk space —
        // the summary carries output, cap and folder, nothing about what is
        // free — so that warning cannot rely on the same cover and has to
        // stay visible outright (see the `Section`'s `footer:` below).
        if model.destinationFellBack {
          Label(
            "The folder you last chose is not available, so Oxbow will use "
              + "Downloads.",
            systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        // A clip whose parent broadcast Twitch has expired, or any video
        // whose metadata fetch failed — see `IntakeModel.chatProblem`.
        // Without this the sheet would simply grey Add out with nothing on
        // screen saying why, which is the exact failure `compositeProblem`
        // below exists to prevent, and the exact failure the whole panel is
        // forced open to prevent (§2.7).
        if let chatProblem = model.chatProblem {
          Label(chatProblem, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
        }

        // Only reachable for a clip whose selected rendition Twitch never
        // recorded pixel dimensions for — see `IntakeModel.compositeProblem`.
        if let compositeProblem = model.compositeProblem {
          Label(compositeProblem, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
        }

        // Built as its own leading-aligned `HStack` with a trailing
        // `Spacer`, rather than left as a bare labeled `Toggle` row. A `Form`
        // row normally splits a control's label into the row's leading
        // label column and puts only the control itself in the trailing
        // column — right where `Download`, `Quality` and `Chat text size`
        // put their pulldowns above. A lone checkbox glyph in that column
        // reads as centred, floating under the values above it rather than
        // under their labels. Wrapping the checkbox and its own text as one
        // unit is what actually left-aligns it with those labels, per the
        // mockup (§4).
        HStack {
          // Checkbox, not a switch. A switch communicates a persistent mode
          // that stays where you left it; this is a one-shot action applied
          // once when Add is pressed (design doc §2.2). The default switch
          // style would contradict the affordance.
          Toggle(isOn: $model.wantsToSaveDefaults) {
            Text("Make these settings my defaults")
          }
          .toggleStyle(.checkbox)
          Spacer(minLength: 0)
        }

        // Back inside the drawer, below the checkbox — see the doc comment
        // above `options` for why this reverses where an earlier version of
        // this panel put it. `.padding(.top, 4)` pulls it away from the
        // checkbox above so it reads as a footnote about the panel, not as
        // a second line of the checkbox's own label.
        if model.output == .videoWithChat, model.chatProblem == nil {
          Text("Chat is rendered in a column beside the video and encoded into "
            + "one file. This takes roughly as long as the stream itself.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }

        if model.wantsToSaveDefaults {
          Text(saveNote)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }

    // Was the options `Section`'s `footer:`. `Section(isExpanded:)` has no
    // footer variant, and these belong outside the drawer anyway — a warning
    // that scrolls away with the section it hangs off is a warning that gets
    // missed.
    //
    // Conditional on there being something to say: a `Section` with no
    // visible content still draws its box in a grouped `Form`, which read as
    // an empty panel hanging under the options for the common case where
    // nothing is wrong.
    if model.destinationCollision != nil || model.spaceWarning != nil {
      Section {
      // Outside the collapsible section on purpose — see the doc comment
      // above `options`. Visible whether the panel is open or shut: the
      // collision warning belongs here alongside `spaceWarning`, which was
      // already here. The delivered filename used to sit above them and no
      // longer does — the Save panel is where a name is chosen and shown,
      // and repeating it here restated something the user had just typed
      // while being the one row in this window whose height nobody could
      // predict, because it wraps with the stream's own title.
      VStack(alignment: .leading, spacing: 8) {
        if let collision = model.destinationCollision {
          // Orange, not red: nothing is wrong and nothing is blocked. Red is
          // reserved for `addFailure` below, where the sheet is refusing.
          Label(collisionWarning(for: collision), systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let warning = model.spaceWarning {
          VStack(alignment: .leading, spacing: 2) {
            // Orange, matching the overwrite caution above: nothing is
            // wrong and nothing is blocked. Red belongs to `addFailure`,
            // where the sheet is actually refusing.
            Label(spaceWarningText(warning), systemImage: "externaldrive.badge.exclamationmark")
              .font(.caption)
              .foregroundStyle(.orange)
            if let remedy = warning.remedy {
              // The actionable half, and the reason this is a warning worth
              // showing at all. Indented under the label's text rather than
              // its icon so the two read as one block.
              Text(remedyText(remedy))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 18)
            }
          }
        }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// Routed through the model so a pick re-derives the cap (§3.3).
  private var qualityBinding: Binding<String> {
    Binding(get: { model.quality }, set: { model.selectQuality($0) })
  }

  /// What the checkbox's footnote says once it is ticked. Always ends with
  /// the same reassurance — this is not a one-way door — and leads with
  /// whatever this particular save would do differently from a literal
  /// reading of the screen, so the two footnotes above it only appear when
  /// they have something to say.
  private var saveNote: String {
    var parts: [String] = []
    if let rung = model.savedQualityNote { parts.append("Saved as \(rung.label).") }
    if model.withholdsOutputFromSave {
      parts.append("Whether to include chat will not be saved from this video.")
    }
    if model.withholdsChatSizeFromSave {
      parts.append("Chat text size will not be saved from this video.")
    }
    parts.append("You can change these any time in Settings.")
    return parts.joined(separator: " ")
  }

  /// The timeline needs a duration to scale against, so a VOD whose metadata
  /// fetch failed falls back to the two fields alone — which is the state the
  /// `Metadata failed` preview below already reaches, since `showsTrimOptions`
  /// keys off the parsed link rather than off `info`.
  private var trim: some View {
    // Closing this undoes nothing — it hides the controls and that is all.
    // Which is why the header carries the range: a section quietly applying a
    // trim while showing nothing would be exactly the hidden state a
    // disclosure triangle is so easily mistaken for.
    Section {
      disclosureHeader(
        "Trim",
        isExpanded: model.isTrimExpanded,
        trailing: {
          if let summary = model.trimSummary {
            Text(summary)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        },
        toggle: { model.isTrimExpanded.toggle() })

      if model.isTrimExpanded {
        if let duration = model.info?.duration {
          TrimTimeline(
            duration: duration,
            startText: $model.trimStartText,
            endText: $model.trimEndText,
            isDimmed: model.trimIsInvalid)
        }

        // One row, not three. As separate `LabeledContent` rows these pushed
        // the section below the fold of the default window, and they read as
        // three unrelated settings rather than as the two ends of one range
        // with its length between them.
        HStack(spacing: 8) {
          Text("Start")
            .foregroundStyle(.secondary)
          TextField("Start", text: $model.trimStartText, prompt: Text("0:00"))
            .labelsHidden()
            .monospacedDigit()
            .frame(width: 88)

          Spacer(minLength: 8)
          if let selected = model.effectiveDuration {
            // Not a field: it is derived from the two that are, and giving it
            // a box would invite people to type into it.
            Text(Timecode.spelled(selected))
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
          Spacer(minLength: 8)

          Text("End")
            .foregroundStyle(.secondary)
          // Trailing-aligned and sized to its contents, unlike Start. This is
          // the right-hand end of the range and it sits under the right-hand
          // end of the timeline, so it stays anchored there whatever it holds
          // — in a fixed-width box the long `End of video` placeholder reached
          // the edge while a typed `07:13:00` stopped short of it, and the
          // label was left stranded across a gap that changed size with the
          // value. `minWidth` keeps a half-typed value from shrinking the
          // field to something too small to click back into, and monospaced
          // digits stop the label twitching as the digits change under a drag.
          TextField("End", text: $model.trimEndText, prompt: Text("End of video"))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .fixedSize()
            .frame(minWidth: 64, alignment: .trailing)
        }
        if model.trimIsInvalid {
          Label(
            "Use h:mm:ss, m:ss, or seconds. The end must come after the start, "
              + "and both must fall inside the video.",
            systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
  }

  /// Just the buttons, pinned below the form.
  ///
  /// **Outside the scroll view, deliberately.** As a `Section` at the bottom
  /// of the form it scrolled away the moment a thumbnail loaded, so the one
  /// thing every download commits to — where the file goes — was below the
  /// fold exactly when the window looked most finished. Transmission pins its
  /// path row above its buttons for the same reason. The destination itself
  /// has since moved up into `options`, into the order the decision is
  /// actually made in — pinning it here was a guard against it falling below
  /// the fold exactly when the form looked most finished, which the window
  /// growing to fit its own sections now covers, and which the collapsed
  /// panel's own summary (§2.6) covers a second time.
  private var footer: some View {
    buttons
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
  }

  /// Both figures on one line, and the volume named rather than called "the
  /// disk" — a Mac with an external drive attached has more than one, and
  /// which one is short is the first thing the user needs to know.
  ///
  /// "About", because it is: `docs/design/disk-preflight.md` §3.2 is explicit
  /// that the composite term is a median of four samples. Stating a soft
  /// number as though it were exact is how a warning earns distrust.
  private func spaceWarningText(_ warning: IntakeModel.SpaceWarning) -> String {
    let needed = warning.needed.formatted(.byteCount(style: .file))
    let available = warning.available.formatted(.byteCount(style: .file))
    return "Needs about \(needed) · \(available) free on \(warning.volumeName)"
  }

  private func remedyText(_ remedy: IntakeModel.SpaceWarning.Remedy) -> String {
    "\(remedy.qualityName) would need about \(remedy.needed.formatted(.byteCount(style: .file)))"
  }

  private var destination: some View {
    HStack(spacing: 8) {
      // Not `.secondary`, unlike `folder`'s own "No folder chosen" fallback
      // below. This is a row label, the same job `Download`, `Quality` and
      // `Chat text size` do with their own `Picker` labels — all rendered at
      // the default (primary) style. `destination` is a plain `HStack`, not
      // a `LabeledContent`, so nothing styles this label but this modifier;
      // it dates from when `Save to` lived in its own `Section` below the
      // pickers, where dimming it read as secondary information rather than
      // as disabled. Inside one group of option rows it reads as disabled,
      // so it goes.
      Text("Save to")

      if let folder = model.folder {
        // The real Finder icon for the real folder: a faster read than the
        // path text, and proof the path resolves to something.
        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path(percentEncoded: false)))
          .resizable()
          .frame(width: 16, height: 16)
        Text(folder.lastPathComponent)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(folder.path(percentEncoded: false))
      } else {
        Text("No folder chosen")
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 8)
      Button("Choose…") { chooseFolder() }
        .controlSize(.small)
    }
  }

  private var buttons: some View {
    HStack(spacing: 12) {
      if let addFailure = model.addFailure {
        Label(addFailure, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      if isAdding { ProgressView().controlSize(.small) }
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      // Named for what it does. No ellipsis: nothing further is asked for —
      // the warning above is the whole disclosure, and this button completes
      // the action (HIG reserves the ellipsis for actions that need more
      // input).
      Button(model.destinationCollision == nil ? "Add" : "Replace") { add() }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canAdd || isAdding)
    }
  }

  // MARK: - Sizing to fit

  /// How much room the form wants for what is currently on screen.
  ///
  /// **Estimates, not layout arithmetic** — but they are now load-bearing in
  /// both directions. They began as floors, back when the window only ever
  /// grew: an over-estimate cost a little slack under the last row and cost
  /// nothing else. Now that closing a disclosure shrinks the window again,
  /// an over-estimate is a visible gap above the buttons and an
  /// under-estimate leaves the form scrolling, so each number below is worth
  /// checking on screen rather than reasoning about.
  ///
  /// Measuring the real content height instead would mean reaching inside a
  /// `Form`'s scroll view, which SwiftUI does not offer and which would break
  /// the moment the form style changed. That is still the right answer if
  /// these numbers ever start needing per-state special cases.
  private var desiredContentHeight: CGFloat {
    // Raised from the old horizontal card's 600: the thumbnail now spans the
    // form's width at 16:9 instead of sitting fixed at 90pt tall beside the
    // title, which is the single biggest addition to what's on screen by
    // default — a floor, like the rest of this function, not a measurement.
    // Measured on screen against a two-line title, not derived: with both
    // disclosures shut, the form ends here and the buttons sit directly
    // under it. A one-line title leaves a little slack, which is the right
    // way round — slack is a small gap, a shortfall is a clipped row.
    var height: CGFloat = 640
    // **As soon as the link parses, not once metadata settles.** Everything
    // below is a floor for content that appears when the fetch answers — but
    // `resize(toFit:)` animates, so waiting for the answer meant the window
    // resized twice for one paste: once as the loading card appeared, then
    // again 120pt taller a second later as the options drawer arrived. Two
    // animated resizes for one action read as the window rendering twice.
    //
    // Everything this needs is already known at parse time: the drawer's
    // expansion comes from preferences, and `chatProblem` is nil until there
    // is an `info` or a failure to make it otherwise — so the branch below
    // evaluates the same before and after. A link that then fails, or whose
    // chat turns out to be unavailable, is 120pt taller than it strictly
    // needs until something else changes the height — the cost of sizing
    // once per paste rather than twice.
    guard model.target != nil else { return height }
    if model.output == .videoWithChat, model.chatProblem == nil,
       model.isOptionsEffectivelyExpanded
    {
      // The chat text size picker and the encode-duration note both live
      // inside the drawer (the note moved back in below the checkbox — see
      // the doc comment above `options`), so both only claim room while
      // `options` is actually expanded — the same way the trim bump below
      // is gated on `isTrimExpanded`. Growing the window for either while
      // the panel is collapsed would open a gap under a closed drawer.
      // Measured the same way, and much larger than the 120 it replaced:
      // that number dates from when the drawer held only the chat-size
      // picker and the encode note. The destination row and the defaults
      // checkbox moved inside it since, and nobody re-measured.
      height += 230
    }
    // 100, not the 165 this started at: measured on screen with both
    // disclosures open, where 165 left a visible band of empty window above
    // the buttons. The timeline and its two labels are all that opens here.
    if model.showsTrimOptions, model.isTrimExpanded { height += 100 }
    return height
  }

  /// Extends the window's **bottom** edge to make room, never its top.
  ///
  /// The title bar staying put is the point: the window appears to unfold
  /// downward from where you left it, rather than jumping under the cursor. It
  /// stops at the bottom of the screen and never shrinks — a window the user
  /// has sized up is theirs, and collapsing a section is not a request to lose
  /// that space.
  /// A section's own header row: the whole width of the box, and the chevron
  /// with it.
  ///
  /// **We draw the chevron rather than letting `Section(isExpanded:)` draw
  /// it.** Its chevron sits outside the header's content bounds and does not
  /// respond to clicks, so the one thing a person actually aims at was the
  /// one dead spot on the row — measured by clicking across it: the label
  /// toggled, a point 150pt to its right toggled, the triangle did nothing.
  /// A row inside the section is a plain `Form` row, so a `Button` filling it
  /// is clickable end to end, triangle included.
  private func disclosureHeader(
    _ title: String,
    isExpanded: Bool,
    @ViewBuilder trailing: () -> some View,
    toggle: @escaping () -> Void)
    -> some View
  {
    Button {
      toggleDisclosure(toggle)
    } label: {
      // **`.firstTextBaseline`, not the default centre.** The title is body
      // text and the summary beside it is `.caption`; centred, two different
      // point sizes sit on two different baselines and the smaller one reads
      // as floating. The chevron is a glyph rather than text, so it carries
      // its own guide below to keep it optically centred on the title rather
      // than sitting on the baseline with its tail hanging under it.
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
          // Rotated rather than swapped for `chevron.down`: a swap pops
          // between two glyphs, a rotation is the same continuous motion the
          // rest of the disclosure makes.
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .frame(width: 10)
        Text(title)
        trailing()
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// How long a disclosure takes to open or close, shared by the content
  /// animation and the window's own frame change.
  ///
  /// **They have to be one number.** Toggling a section used to animate the
  /// content immediately and then resize the window from `.onChange`, a
  /// render later, with `NSWindow`'s own duration and curve. Two animations
  /// on two clocks for one click is what read as sluggish next to an app
  /// that does it in one move.
  private static let disclosureDuration: Double = 0.22

  /// Opens or closes a section and resizes the window in the same breath.
  ///
  /// Reading `desiredContentHeight` *after* the toggle is what makes this
  /// work: it is a computed property over the model, so it already reflects
  /// the new state by the time the window is asked to move.
  private func toggleDisclosure(_ toggle: () -> Void) {
    withAnimation(.easeInOut(duration: Self.disclosureDuration)) { toggle() }
    resize(toFit: desiredContentHeight)
  }

  /// Sizes the window to what the form currently wants — in both directions.
  ///
  /// **Shrinking matters as much as growing now that both sections are
  /// disclosures.** While this only grew, opening Trim and then closing it
  /// again left the window 165pt taller than its contents forever, and a
  /// window that ratchets up every time you look inside something is worse
  /// than one that never resizes at all.
  ///
  /// The origin moves by the same delta so the **title bar stays put** and
  /// the window grows and shrinks from its bottom edge. Growing downward is
  /// what a window opening a section should do; growing upward would walk the
  /// window up the screen a section at a time.
  ///
  /// This does override a height the user dragged to themselves, which is the
  /// price of sizing to content at all — it was already true of growing, and
  /// making it symmetric does not make it more true.
  private func resize(toFit wanted: CGFloat) {
    guard let hostWindow, let screen = hostWindow.screen ?? NSScreen.main else { return }
    let chrome = hostWindow.frame.height - hostWindow.contentLayoutRect.height
    let target = min(wanted + chrome, screen.visibleFrame.height)
    let delta = target - hostWindow.frame.height
    // A point either way is not worth an animation.
    guard abs(delta) > 1 else { return }

    var frame = hostWindow.frame
    frame.size.height = target
    frame.origin.y = max(frame.origin.y - delta, screen.visibleFrame.minY)

    // `NSAnimationContext` rather than `setFrame(display:animate:)`, whose
    // duration is chosen by AppKit from the size of the change — so a big
    // section and a small one moved the window at different speeds, and
    // neither matched the content animating inside it.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.disclosureDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      hostWindow.animator().setFrame(frame, display: true)
    }
  }

  // MARK: - Actions

  /// Dismisses only once the job is in the engine. `model.add()` awaits the
  /// enqueue all the way in and reports whether it landed; a refusal leaves
  /// the sheet open with its reason on screen. The checkbox's own save is
  /// gated on that same success (§2.3), so it lands here rather than inside
  /// `model.add()` itself.
  private func add() {
    isAdding = true
    Task {
      let didAdd = await model.add()
      isAdding = false
      if didAdd {
        // After the enqueue succeeds and never before it (§2.3) —
        // `addFailure` is the path where Add refused and the window
        // deliberately stays open on a job that was never composed, and
        // saving there would persist the settings of a job that does not
        // exist.
        model.saveDefaultsIfRequested()
        dismiss()
      }
    }
  }

  /// Fills the link field from the clipboard, when it holds a Twitch address
  /// and the field is still empty.
  ///
  /// The reason the window exists is almost always a link you just copied, so
  /// having to paste it is a keystroke asking to be skipped. Guarded on
  /// `TwitchLink.parse` rather than on any string, so an unrelated clipboard
  /// never lands in the field — and on `linkText` being empty, so re-focusing
  /// the window cannot overwrite something half-typed.
  private func prefillFromClipboard() {
    guard model.linkText.isEmpty else { return }
    guard let text = NSPasteboard.general.string(forType: .string),
          TwitchLink.parse(text) != nil
    else { return }
    model.linkText = text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A Save panel, not an Open panel — this is where a Mac user expects to
  /// name a file, not just pick the folder it lands in (§2). The window
  /// still only ever shows one row for it, `Save to`, so this single dialog
  /// now does what a directory-only `NSOpenPanel` and the deleted Name field
  /// (§1) used to do between them.
  ///
  /// `nameFieldStringValue` mirrors `.OK`'s own write-back below: it is
  /// `outputBaseName + OutputSuffix.video`, the exact `.mp4` this job
  /// delivers, restricted to that one type via `allowedContentTypes` so the
  /// panel cannot offer to save a name Oxbow would never produce.
  /// `directoryURL` opens on the folder already chosen (`model.folder`),
  /// not a hard-coded `~/Downloads` — the panel should open where the job is
  /// already headed, not reset it.
  private func chooseFolder() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = model.outputBaseName + OutputSuffix.video
    panel.directoryURL = model.folder
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.mpeg4Movie]

    // A sheet on the sheet. `runModal()` here would stack an app-modal panel
    // on top of a sheet — it appears detached from the window it belongs to,
    // and it spins a nested runloop underneath SwiftUI.
    guard let hostWindow else {
      // Only if the window has not been read back yet, which cannot happen
      // once the sheet is on screen and the user has clicked a button in it.
      if panel.runModal() == .OK, let url = panel.url {
        applyChosenDestination(url)
      }
      return
    }
    panel.beginSheetModal(for: hostWindow) { response in
      guard response == .OK, let url = panel.url else { return }
      applyChosenDestination(url)
    }
  }

  /// Splits the Save panel's one URL back into the two fields it replaced:
  /// the folder `Save to` has always shown, and `model.name`, which still
  /// carries every reader it always had — `outputBaseName` re-sanitizes and
  /// re-reserves suffix bytes over whatever the user typed here exactly as
  /// it does over a name `load()` derived from metadata, so a name picked in
  /// this panel goes through the same rules rather than bypassing them.
  private func applyChosenDestination(_ url: URL) {
    model.folder = url.deletingLastPathComponent()
    model.name = url.deletingPathExtension().lastPathComponent
  }

  // MARK: - Text

  // Delegated rather than duplicated: this view used to carry
  // its own copy of this exact one-line predicate, and `optionsSummary`
  // grew a second one that disagreed with it — a clip's collapsed header
  // said "Video + chat" while its own expanded picker, reading this
  // property, said "Clip + chat". One answer now, on the model.
  private var isClip: Bool { model.isClip }

}

/// Hands back the AppKit window hosting this SwiftUI view.
///
/// `NSSavePanel.beginSheetModal(for:)` needs the sheet's own `NSWindow`, and
/// SwiftUI does not expose it. Zero-sized and in the background, so it
/// affects nothing it is placed behind; the state write is deferred a turn
/// because `makeNSView` runs during a view update, and `view.window` is nil
/// until the view is in a window anyway.
///
/// **Not `private`.** `SettingsView` needs the identical mechanism for the
/// identical reason — its own folder panel has to be a sheet, never a
/// `runModal()` — and duplicating this `NSViewRepresentable` in a second file
/// would be the second mechanism its own doc comment warns against. Internal,
/// not public: nothing outside the app target has a window to capture.
struct HostWindowReader: NSViewRepresentable {
  @Binding var window: NSWindow?

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async { window = view.window }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard window !== view.window else { return }
    DispatchQueue.main.async { window = view.window }
  }
}

// MARK: - Previews

/// A model wired to a canned fetch, so the previews below show the sheet's
/// settled states without an engine, a helper, or a network call.
///
/// The link is pre-filled and the sheet's own `.task(id:)` runs in a preview,
/// so each of these loads through the real `IntakeModel.load()` path rather
/// than having its state poked in from outside.
@MainActor
private func previewModel(
  link: String = "https://www.twitch.tv/videos/2844548319",
  info: VideoInfo? = .previewVOD,
  folder: URL? = URL(filePath: "/Users/you/Downloads"),
  fileExists: @escaping (URL) -> Bool = { _ in false },
  volumeSpace: VolumeSpace = .previewFull(free: 10_000_000_000_000),
  // Defaulted rather than left to whatever `OxbowPreviews` last held. (Fix
  // round 1.) `isOptionsExpanded`'s `didSet` writes straight through to the
  // store (§2.5), and this function backs every preview in the file with the
  // same on-disk suite — so a preview that set `model.isOptionsExpanded`
  // after construction was not just choosing its own state, it was leaving
  // that state for the *next* preview drawn from this same function to
  // inherit. `#Preview("Options panel - collapsed")` rendering once was
  // enough to collapse the drawer in `#Preview("Not enough room - with a
  // remedy")`, hiding the one thing that preview exists to show. Setting it
  // here, before the model exists, makes every preview's expansion its own
  // explicit choice again — nothing to inherit, nothing to leak.
  optionsExpanded: Bool = true)
  -> IntakeModel
{
  // A fixed store, not `.standard`: `output`, `chatSize` and `qualityCap`
  // are seeded from it too, not just `folder` (which this function does
  // overwrite below) — so `.standard` would make every preview canvas in
  // this file render differently depending on whichever developer's real
  // saved defaults happen to be, the same thing `VolumeSpace.previewFull`'s
  // own comment below rules out for disk space ("a canvas that changes
  // with the developer's disk is a canvas nobody can review"). Worse,
  // previews are interactive — once Add's save is wired up, ticking the
  // box and pressing Add in a live preview would write to the real
  // `studio.lofti.Oxbow` domain.
  //
  // A fresh `InMemoryPreferenceStore` per call, not the named
  // `UserDefaults(suiteName: "OxbowPreviews")` this used to be: that suite
  // name was fixed rather than per-call, so every preview in this file
  // shared one on-disk domain across the whole run — which is what made the
  // `optionsExpanded` parameter above necessary in the first place (see its
  // comment). A fresh in-memory store removes the sharing entirely, along
  // with the `.plist` the named suite left in `~/Library/Preferences`.
  var preferences = Preferences(
    store: InMemoryPreferenceStore(),
    homeDirectory: URL(filePath: "/Users/preview"),
    directoryExists: { _ in true })
  // Written before `IntakeModel.init` runs, which is what seeds
  // `isOptionsExpanded` from it — setting `model.isOptionsExpanded`
  // afterwards instead would work for *this* model but would also perform
  // the exact store write this parameter exists to make unnecessary.
  preferences.optionsPanelIsExpanded = optionsExpanded

  let model = IntakeModel(
    fetchInfo: { _ in
      guard let info else { throw VideoInfoFetchError.unparseableOutput(snippet: "") }
      return info
    },
    enqueue: { _, _ in },
    fileExists: fileExists,
    volumeSpace: volumeSpace,
    preferences: preferences)
  model.linkText = link
  model.folder = folder
  return model
}

extension VolumeSpace {
  /// A volume with a fixed amount of room. Every preview uses one rather than
  /// `.live`, so a preview renders the same way on a full laptop and an empty
  /// one — a canvas that changes with the developer's disk is a canvas nobody
  /// can review.
  fileprivate static func previewFull(free: Int64) -> VolumeSpace {
    VolumeSpace(
      availableBytes: { _ in free },
      volumeRoot: { _ in URL(filePath: "/") },
      volumeName: { _ in "Macintosh HD" })
  }
}

extension VideoInfo {
  fileprivate static let previewVOD = VideoInfo(
    streamer: "LeighXP",
    title: "indie horror + something else later?? ٩(◕‿◕)۶",
    createdAt: .now,
    duration: .seconds(991),
    qualities: [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_184_466),
      StreamQuality(name: "720p60", resolution: "1280x720", bitsPerSecond: 3_411_940),
      StreamQuality(name: "480p30", resolution: "852x480", bitsPerSecond: 1_427_697),
    ],
    thumbnailURLs: [URL(string: """
      https://static-cdn.jtvnw.net/cf_vods/d2nvs31859zcd8/\
      5652d9d62faa525b5c68_leighxp_317872278872_1786573193//thumb/thumb0-320x180.jpg
      """)!])
}

/// The sheet as it opens: chat included, since that is the default.
#Preview("Video + chat") {
  IntakeWindow(model: previewModel())
}

#Preview("Video") {
  let model = previewModel()
  model.output = .video
  return IntakeWindow(model: model)
}

/// Exercises the chat text size picker away from its `.medium` default, so a
/// glance at this preview catches the segmented control rendering wrong as
/// readily as the "Video + chat" one above catches everything else in the
/// section.
#Preview("Video + chat - large text") {
  let model = previewModel()
  model.chatSize = .large
  return IntakeWindow(model: model)
}

/// A clip whose parent broadcast Twitch has expired, with chat asked for.
/// Exercises `IntakeModel.chatProblem`: the chat size picker and its encoding
/// note are suppressed, the refusal is shown in their place, and Add is
/// disabled — while `.video` remains selectable, because the clip itself
/// still downloads.
#Preview("Clip + chat - broadcast gone") {
  let clipInfo = VideoInfo(
    streamer: "f00xtr0t323",
    title: "This dude jumped off the ledge.",
    createdAt: .now,
    duration: .seconds(30),
    qualities: [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_264_272),
    ],
    thumbnailURLs: [],
    hasDownloadableChat: false)
  let model = previewModel(
    link: "https://clips.twitch.tv/AdorableStylishPotatoPlanking-5UAS4GFYHTkDW4xX",
    info: clipInfo)
  model.output = .videoWithChat
  return IntakeWindow(model: model)
}

/// A clip old enough that Twitch never backfilled pixel dimensions onto its
/// only rendition, explicitly chosen for a composite. Exercises
/// `IntakeModel.compositeProblem`, the one conditional row nothing else here
/// renders.
#Preview("Video + chat - composite problem") {
  let clipInfo = VideoInfo(
    streamer: "LeighXP",
    title: "an old clip with no recorded dimensions",
    createdAt: .now,
    duration: .seconds(45),
    qualities: [
      StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0),
    ],
    thumbnailURLs: [])
  let model = previewModel(link: "https://clips.twitch.tv/TangibleGiantPancakeKappa", info: clipInfo)
  model.output = .videoWithChat
  model.quality = "720p0-1"
  return IntakeWindow(model: model)
}

#Preview("Empty") {
  IntakeWindow(model: previewModel(link: "", info: nil, folder: nil))
}

/// Also the second half of `IntakeModel.chatProblem`: without metadata the
/// default output cannot be built, so this preview shows the refusal and a
/// disabled Add alongside the id-derived fallback name.
#Preview("Metadata failed") {
  IntakeWindow(model: previewModel(info: nil))
}

/// A name whose file is already sitting in the chosen folder. Exercises the
/// caution line in the options panel's footer and the Add button's
/// relabelling — the two halves of the overwrite warning, which have to
/// appear together.
#Preview("Name already taken") {
  IntakeWindow(model: previewModel(fileExists: { _ in true }))
}

/// A destination that cannot hold the job, with a lower rendition that can.
/// Unreachable in a preview without a genuinely full disk, which is exactly
/// why it needs one — this is the layout nobody would otherwise look at until
/// a user hit it.
#Preview("Not enough room - with a remedy") {
  IntakeWindow(model: previewModel(volumeSpace: .previewFull(free: 900_000_000)))
}

/// The same warning with no way out: every rendition on offer is too big, so
/// the second line is absent and the first has to stand on its own.
#Preview("Not enough room - no remedy") {
  IntakeWindow(model: previewModel(volumeSpace: .previewFull(free: 1_000_000)))
}

/// The timeline in the window it actually lives in, at a real VOD's length,
/// with a trim set. The section is otherwise only reachable by clicking.
#Preview("Video - trimmed") {
  let model = previewModel()
  model.output = .video
  model.isTrimExpanded = true
  model.trimStartText = "00:02:00"
  return IntakeWindow(model: model)
}

// MARK: - The options panel (§2.1, §2.5-§2.7)

/// Collapsed is the steady state (§2.6), so this is the one most people see
/// most of the time. Passed as `previewModel`'s own `optionsExpanded:`
/// parameter rather than set on the model afterward — see that parameter's
/// doc comment: that used to matter because every preview in this file
/// shared one on-disk `UserDefaults` suite, so setting it post-construction
/// here would have collapsed every *other* preview too, not just this one.
/// `previewModel` now hands each call its own `InMemoryPreferenceStore`, so
/// that sharing is gone — the parameter stays because it is still the
/// correct way for a preview to choose its own expansion explicitly.
#Preview("Options panel - collapsed") {
  IntakeWindow(model: previewModel(optionsExpanded: false))
}

/// Expanded, with the checkbox ticked and the quality footnote showing.
///
/// **This preview used to call `model.selectQuality("900p30")` before
/// the window's `.task` had loaded metadata, which is a silent no-op —
/// `selectQuality` guards on `qualities`, which is empty until `load()`
/// settles it — and `load()` then overwrote `quality` from `qualityCap`
/// anyway, via `QualityLadder.resolve`. The picker never actually showed
/// `900p30`, and the footnote this preview is named for never actually
/// rendered.**
///
/// Fixed by seeding `qualityCap` directly and letting the real `load()` path
/// every other preview goes through do the resolving, the same way `folder`
/// and `output` are seeded elsewhere in this file. This is spec §3.3's own
/// worked example: a cap of `.p720` against a video offering only
/// `1080p60` (nothing at or under the ceiling) resolves `quality` to
/// `"1080p60"` — the only rendition on offer — while the seeded cap itself
/// stays `.p720`. `savedQualityNote` is exactly this disagreement:
/// `bucketed` (`.p1080`, from `1080p60`'s own dimensions) differs from
/// `qualityCap` (`.p720`), so it reads `qualityCap` back out and the
/// footnote says "Saved as Up to 720p" beside a visibly different
/// `1080p60` selection (§3.8). Also exercised directly, without a view, by
/// `IntakeModelTests.anUntouchedPickerSavesTheSeededCapNotWhatItResolvedTo`.
#Preview("Options panel - expanded, ticked, bucket footnote") {
  let info = VideoInfo(
    streamer: "LeighXP",
    title: "indie horror + something else later?? ٩(◕‿◕)۶",
    createdAt: .now,
    duration: .seconds(991),
    qualities: [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_184_466),
    ],
    thumbnailURLs: [])
  let model = previewModel(info: info, optionsExpanded: true)
  model.qualityCap = .p720
  model.wantsToSaveDefaults = true
  return IntakeWindow(model: model)
}

/// The forced-open case (§2.7). `optionsExpanded: false` — the same
/// collapsed state as the first preview above — so what actually props the
/// panel open is `chatProblem` alone, exactly the mechanism
/// `isOptionsEffectivelyExpandedBinding` exists for. A regression that made
/// the panel respect only the stored flag again would show this preview
/// collapsed, with Add greyed out and no explanation on screen — the failure
/// this whole feature exists to prevent.
#Preview("Options panel - forced open by chatProblem") {
  let clipInfo = VideoInfo(
    streamer: "f00xtr0t323",
    title: "This dude jumped off the ledge.",
    createdAt: .now,
    duration: .seconds(30),
    qualities: [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_264_272),
    ],
    thumbnailURLs: [],
    hasDownloadableChat: false)
  let model = previewModel(
    link: "https://clips.twitch.tv/AdorableStylishPotatoPlanking-5UAS4GFYHTkDW4xX",
    info: clipInfo, optionsExpanded: false)
  model.output = .videoWithChat
  return IntakeWindow(model: model)
}
