import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Intake model")
struct IntakeModelTests {

  // MARK: - Seeding

  /// The rule survives the arrival of a preference store: a model whose
  /// folder has been cleared still refuses to compose a job. Only the way a
  /// model *gets* a folder changed.
  @Test func composingRefusesOnceTheFolderIsCleared() async {
    let model = await loadedModel()
    model.folder = nil
    #expect(model.composedTemplate() == nil)
  }

  @Test func seedsEveryFieldFromTheStore() {
    let model = makeModel(preferences: Self.store {
      $0.destination = URL(filePath: "/Volumes/Archive")
      $0.qualityCap = .p720
      $0.output = .video
      $0.chatSize = .large
      $0.optionsPanelIsExpanded = false
    })

    #expect(model.folder == URL(filePath: "/Volumes/Archive"))
    #expect(model.qualityCap == .p720)
    #expect(model.output == .video)
    #expect(model.chatSize == .large)
    #expect(model.isOptionsExpanded == false)
  }

  /// Spec §2.2. Including the first run — an unticked box makes the same
  /// promise every time, so nobody has to remember what state it was left in.
  @Test func theCheckboxIsUntickedOnAFreshStoreAndOnAConfiguredOne() {
    #expect(makeModel(preferences: Self.store()).wantsToSaveDefaults == false)
    #expect(makeModel(preferences: Self.store { $0.qualityCap = .p480 })
      .wantsToSaveDefaults == false)
  }

  /// Every stored value here differs from both its factory default and the
  /// value the model is mutated to below, so a `reset()` that hardcoded
  /// factory constants — or one that simply left the mutations in place and
  /// touched nothing — could not pass this by accident.
  ///
  /// **The destination is deliberately one that exists and is not the
  /// factory `~/Downloads`.** An earlier version of this test used a missing
  /// destination, which resolves to `~/Downloads` — indistinguishable from
  /// what a `reset()` that hardcoded the factory constant, rather than
  /// reading `preferences.destination`, would also produce. `/Volumes/Archive`
  /// here is a value only a real read of the store can produce.
  /// `destinationFellBack` and its own store-derived recomputation on
  /// `reset()` are covered separately below, by
  /// `resetRereadsDestinationFellBackFromTheStoreRatherThanKeepingInitsAnswer`
  /// — a destination that is present throughout, as this one is, cannot
  /// distinguish "recomputed on reset" from "never touched since init".
  @Test func resetReseedsFromTheStoreAndUnticksTheBox() {
    var store = Preferences(
      store: InMemoryPreferenceStore(), homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { _ in true })
    store.destination = URL(filePath: "/Volumes/Archive")
    store.qualityCap = .p480
    store.output = .video
    store.chatSize = .large
    store.optionsPanelIsExpanded = false

    let model = makeModel(preferences: store)
    model.output = .videoWithChat
    model.chatSize = .small
    model.qualityCap = .p1080
    model.folder = URL(filePath: "/Users/someone/Movies")
    model.wantsToSaveDefaults = true
    // Not mutated here the way the fields above are: `isOptionsExpanded`
    // writes straight through to `store` on every assignment (§2.5), so
    // setting it here would overwrite the very value this test wants
    // `reset()` to reseed from, rather than leaving something for `reset()`
    // to overwrite. See `resetRereadsIsOptionsExpandedFromTheStore` below for
    // the version of this that mutates the store instead of the model.

    model.reset()

    #expect(model.output == .video)
    #expect(model.chatSize == .large)
    #expect(model.qualityCap == .p480)
    #expect(
      model.folder == URL(filePath: "/Volumes/Archive"),
      "a reset() that hardcoded ~/Downloads would also pass a missing-destination test")
    #expect(model.destinationFellBack == false)
    #expect(model.isOptionsExpanded == false)
    #expect(model.wantsToSaveDefaults == false)
  }

  /// Pins the one line in `reset()` nothing else in this file exercises
  /// meaningfully: `destinationFellBack = preferences.storedDestinationIsMissing`.
  /// Every other test either never reaches `reset()` with a destination that
  /// changes, or (like the test above, before this one existed) uses a store
  /// whose missing-ness never changes between construction and `reset()` — so
  /// `destinationFellBack` starts and ends at the same value regardless of
  /// whether `reset()` actually reads the store fresh or just leaves init's
  /// answer sitting there. Deleting the line changes nothing observable
  /// without this test.
  ///
  /// Here the store's destination is switched from present to missing
  /// *between* construction and `reset()`, through a second `Preferences`
  /// value over the same backing store — standing in for whatever else in the
  /// app (Settings, a later task) might change the destination mid-session. A
  /// stale, uncomputed `destinationFellBack` and a freshly recomputed one
  /// give different answers here; only the real line makes this pass.
  @Test func resetRereadsDestinationFellBackFromTheStoreRatherThanKeepingInitsAnswer() {
    var store = Preferences(
      store: InMemoryPreferenceStore(), homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { $0.path != "/Volumes/NowGone" })
    store.destination = URL(filePath: "/Volumes/StillHere")

    let model = makeModel(preferences: store)
    #expect(model.destinationFellBack == false, "precondition: the destination resolves at construction")

    var mutator = store
    mutator.destination = URL(filePath: "/Volumes/NowGone")

    model.reset()

    #expect(model.destinationFellBack, "reset() must re-read the store, not keep init's answer")
  }

  @Test func aMissingStoredDestinationSeedsTheFallbackAndFlagsIt() {
    var store = Preferences(
      store: InMemoryPreferenceStore(), homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { $0.path != "/Volumes/Unplugged" })
    store.destination = URL(filePath: "/Volumes/Unplugged")

    let model = makeModel(preferences: store)

    #expect(model.folder == URL(filePath: "/Users/t/Downloads"))
    #expect(model.destinationFellBack)
  }

  // MARK: - Reseeding on open

  /// The bug: Add Download is one `Window` for the app's whole run, seeded
  /// once at construction and re-seeded only by `reset()`, which fires once
  /// per *close*. A Settings change made between a close and the next open —
  /// the ordinary sequence, not an edge case — never reaches the model until
  /// `reseedFromPreferences()` reads the store again on open.
  @Test func reseedFromPreferencesPicksUpAStoreChangedSinceConstruction() {
    var store = Preferences(
      store: InMemoryPreferenceStore(), homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { _ in true })
    store.qualityCap = .best
    store.output = .videoWithChat
    store.chatSize = .medium
    store.destination = URL(filePath: "/Users/someone/Movies")
    store.optionsPanelIsExpanded = true

    let model = makeModel(preferences: store)
    #expect(model.qualityCap == .best, "precondition: seeded at construction")

    // Stands in for Settings writing to the same store while this window is
    // closed — a second `Preferences` value over the same backing store, the
    // same technique
    // `resetRereadsDestinationFellBackFromTheStoreRatherThanKeeping-
    // InitsAnswer` above uses for the identical reason.
    var mutator = store
    mutator.qualityCap = .p480
    mutator.output = .video
    mutator.chatSize = .small
    mutator.destination = URL(filePath: "/Users/someone/Archive")
    mutator.optionsPanelIsExpanded = false

    model.reseedFromPreferences()

    #expect(model.qualityCap == .p480)
    #expect(model.output == .video)
    #expect(model.chatSize == .small)
    #expect(model.folder == URL(filePath: "/Users/someone/Archive"))
    #expect(model.isOptionsExpanded == false)
  }

  /// `reseedFromPreferences()` is deliberately narrower than `reset()`: it
  /// runs on *open*, where a link may already be typed or a fetch already
  /// settled, and clobbering that would trade one bug for another. Every
  /// field `reset()` clears is asserted here to survive untouched instead.
  @Test func reseedFromPreferencesLeavesTheInProgressVideoAlone() async {
    let model = await loadedModel()
    model.trimStartText = "00:01:00"
    model.trimEndText = "00:02:00"
    model.wantsToSaveDefaults = true
    let linkBefore = model.linkText
    let nameBefore = model.name
    let qualityBefore = model.quality
    #expect(!linkBefore.isEmpty, "precondition")
    #expect(model.hasSettledMetadata, "precondition")

    model.reseedFromPreferences()

    #expect(model.linkText == linkBefore)
    #expect(model.name == nameBefore)
    #expect(model.quality == qualityBefore)
    #expect(model.trimStartText == "00:01:00")
    #expect(model.trimEndText == "00:02:00")
    #expect(model.wantsToSaveDefaults)
    #expect(model.hasSettledMetadata, "metadata is untouched, not idled the way reset() idles it")
  }

  // MARK: - Pending intake

  /// `apply(_:)` is how a Watching finding reaches this form: `WatchingModel`
  /// hands `IntakeWindow` the archive id and its channel's frozen settings,
  /// and this is what turns those into the fields the rest of the model
  /// reads. The seeded values below all differ from the pending ones, so a
  /// version that silently kept whatever `Preferences` had seeded could not
  /// pass this by accident.
  @Test func applySetsTheLinkAndAllFourSettings() {
    let model = makeModel(preferences: Self.store {
      $0.qualityCap = .best
      $0.output = .videoWithChat
      $0.chatSize = .medium
      $0.destination = URL(filePath: "/Users/someone/Downloads")
    })

    let pending = PendingIntake(
      archiveID: "2844548319",
      settings: Watch.Settings(
        destinationPath: "/Users/someone/Archive",
        qualityCap: .p720,
        output: .video,
        chatSize: .large))

    model.apply(pending)

    #expect(model.linkText == "2844548319")
    #expect(model.target != nil, "a bare numeric id parses as a video")
    #expect(model.qualityCap == .p720)
    #expect(model.output == .video)
    #expect(model.chatSize == .large)
    #expect(model.folder == URL(filePath: "/Users/someone/Archive"))
  }

  /// The ordering `IntentSubmission.submit` already depends on, for the same
  /// reason (see that type's own comment): `load()` reads `qualityCap` to
  /// pick a rendition, so whatever `apply(_:)` sets has to be in place
  /// *before* `load()` runs — never after.
  ///
  /// Proven rather than merely asserted-on-paper: the model starts on a
  /// `.best` cap, which `load()` alone resolves to "best available" (an empty
  /// `quality`). Applying a `.p720` cap and *then* loading instead resolves
  /// `quality` to the rendition that cap actually selects. A version of
  /// `apply(_:)` that ran too late — or an `IntakeWindow` that called
  /// `load()` before `apply(_:)` — would leave `quality` empty here instead.
  @Test func appliedSettingsAreInPlaceBeforeLoadResolvesQuality() async {
    let model = makeModel(
      preferences: Self.store {
        $0.qualityCap = .best
        $0.output = .videoWithChat
      },
      info: Self.info(qualities: [
        StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 8_000_000),
        StreamQuality(name: "720p60", resolution: "1280x720", bitsPerSecond: 3_000_000),
      ]))

    let pending = PendingIntake(
      archiveID: "2844548319",
      settings: Watch.Settings(
        destinationPath: "/Users/someone/Archive",
        qualityCap: .p720,
        output: .video,
        chatSize: .medium))

    model.apply(pending)
    await model.load()

    #expect(
      model.quality == "720p60",
      "load() must resolve against the applied .p720 cap, not the seeded .best one")
    #expect(model.output == .video, "apply()'s output survives a load() that never touches it")
  }

  // MARK: - Quality, both directions

  @Test func metadataResolvesTheCapIntoARendition() async {
    let model = makeModel(preferences: Self.store { $0.qualityCap = .p720 })
    model.linkText = Self.videoLink
    await model.load()

    #expect(model.quality == "720p60")
  }

  /// Spec §3.3. The cap is first-class state, so a video that only offers
  /// more than the cap cannot quietly raise the user's standing preference.
  @Test func anUntouchedPickerLeavesTheCapExactlyAsSeeded() async {
    let model = makeModel(
      preferences: Self.store { $0.qualityCap = .p720 },
      info: Self.info(qualities: [
        StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 8_000_000),
      ]))
    model.linkText = Self.videoLink
    await model.load()

    #expect(model.quality == "1080p60")
    #expect(model.qualityCap == .p720)
  }

  @Test func pickingARenditionRederivesTheCap() async {
    let model = await loadedModel()
    model.selectQuality("720p60")

    #expect(model.quality == "720p60")
    #expect(model.qualityCap == .p720)
  }

  /// Spec §3.8. The bucket is shown at the moment it is chosen, and only when
  /// the pick is not already a rung.
  @Test func theFootnoteAppearsOnlyForAnInexactPick() async {
    let model = await loadedModel(info: Self.info(qualities: [
      StreamQuality(name: "900p30", resolution: "1600x900", bitsPerSecond: 5_000_000),
      StreamQuality(name: "720p60", resolution: "1280x720", bitsPerSecond: 3_000_000),
    ]))

    model.selectQuality("900p30")
    #expect(model.savedQualityNote == .p720)

    model.selectQuality("720p60")
    #expect(model.savedQualityNote == nil)
  }

  /// The footnote's other source of disagreement: an *untouched* picker
  /// whose seeded cap resolved upward because nothing on this video sits at
  /// or under its ceiling. `qualityCap` stays `.p720` — `load()` never
  /// touches it — while `quality` reads `"1080p60"`. The note has to say
  /// what a save would actually write (`.p720`), not `1080p60`'s own bucket
  /// (`.p1080`), or it would describe a save that never happens.
  @Test func theFootnoteNamesTheCapAnUntouchedPickerWouldActuallySave() async {
    let model = makeModel(
      preferences: Self.store { $0.qualityCap = .p720 },
      info: Self.info(qualities: [
        StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 8_000_000),
      ]))
    model.linkText = Self.videoLink
    await model.load()

    #expect(model.quality == "1080p60", "precondition: nothing here sits at or under 720p")
    #expect(model.savedQualityNote == .p720, "what a save would write, not 1080p60's own bucket")
  }

  // MARK: - Saving

  @Test func aTickedBoxWritesEveryFieldOnSave() async {
    let store = Self.store()
    let model = await loadedModel(preferences: store)
    // `.videoWithChat`, not `loadedModel`'s own `.video` — the chat text
    // size picker this test wants to save from only exists on screen while
    // chat is selected (§3.7's `withholdsChatSizeFromSave`).
    model.output = .videoWithChat
    model.selectQuality("720p60")
    model.chatSize = .large
    model.folder = URL(filePath: "/Volumes/Archive")
    model.wantsToSaveDefaults = true

    model.saveDefaultsIfRequested()

    #expect(store.qualityCap == .p720)
    #expect(store.chatSize == .large)
    #expect(store.destination == URL(filePath: "/Volumes/Archive"))
    #expect(store.hasSavedDefaults)
  }

  @Test func anUntickedBoxWritesNothing() async {
    let store = Self.store()
    let model = await loadedModel(preferences: store)
    model.chatSize = .large

    model.saveDefaultsIfRequested()

    #expect(store.hasSavedDefaults == false)
  }

  /// Spec §3.3's own worked example: cap `.p720` against a video offering
  /// only `1080p60` resolves `quality` to `"1080p60"` (nothing at or under
  /// the ceiling). Untouched, that must save the seeded `.p720`, not
  /// `1080p60`'s own bucket — `anUntouchedPickerLeavesTheCapExactlyAsSeeded`
  /// proves this of the model field; this proves it of what actually reaches
  /// the store, which is the thing the checkbox promises.
  @Test func anUntouchedPickerSavesTheSeededCapNotWhatItResolvedTo() async {
    let store = Self.store { $0.qualityCap = .p720 }
    let model = await loadedModel(
      preferences: store,
      info: Self.info(qualities: [
        StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 8_000_000),
      ]))
    #expect(model.quality == "1080p60", "precondition: nothing here sits at or under 720p")
    model.wantsToSaveDefaults = true

    model.saveDefaultsIfRequested()

    #expect(store.qualityCap == .p720)
  }

  /// §3.7's counterpart for an untouched picker: a video whose only
  /// rendition carries no dimensions resolves `quality` to `""` (best
  /// available). Saving that must not stomp a real seeded cap with `.best`
  /// — there was never a pick to derive `.best` from, only an absent one.
  @Test func anUntouchedPickerWithNoDimensionsLeavesTheSeededCapAlone() async {
    let store = Self.store { $0.qualityCap = .p720 }
    let model = await loadedModel(
      preferences: store,
      info: Self.info(qualities: [
        StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0),
      ]))
    #expect(model.quality == "", "precondition: nothing here has dimensions to resolve against")
    model.wantsToSaveDefaults = true

    model.saveDefaultsIfRequested()

    #expect(store.qualityCap == .p720)
  }

  /// Spec §2.7's other branch: a metadata fetch that failed outright, not
  /// just a clip whose broadcast expired. `.video` with a failed fetch is
  /// legal (the id-derived fallback name), so switching to it is a
  /// workaround for this video's missing details, not a preference — saving
  /// it must not overwrite a stored `.videoWithChat` default.
  ///
  /// `chatSize` is withheld here too, but for the unrelated reason §3.7
  /// documents for `withholdsChatSizeFromSave`: its own picker is hidden
  /// once `output == .video`, workaround or not. `destination` is the field
  /// that actually isolates "does withholding `output` touch anything else",
  /// since nothing hides its control.
  @Test func outputIsWithheldWhileMetadataFailed() async {
    let store = Self.store { $0.output = .videoWithChat }
    let model = makeModel(
      preferences: store,
      failure: VideoInfoFetchError.helperFailed(status: .exited(1), standardError: "nope"))
    model.linkText = Self.videoLink
    await model.load()
    model.folder = URL(filePath: "/Volumes/Archive")

    #expect(model.chatProblem != nil, "precondition: the fetch failed")
    model.output = .video
    #expect(model.withholdsOutputFromSave)

    model.chatSize = .large
    model.wantsToSaveDefaults = true
    model.saveDefaultsIfRequested()

    #expect(store.output == .videoWithChat, "not overwritten by the workaround")
    #expect(store.chatSize == .medium, "withheld too — its picker is hidden while output is .video")
    #expect(store.destination == URL(filePath: "/Volumes/Archive"), "unrelated field still saves")
  }

  /// Spec §3.7. Nothing to bucket, so the other three still save.
  @Test func aRenditionWithNoDimensionsWithholdsOnlyQuality() async {
    let store = Self.store { $0.qualityCap = .p1080 }
    let model = await loadedModel(
      preferences: store,
      info: Self.info(qualities: [
        StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0),
      ]))
    // `.videoWithChat` so the chat text size picker this test also wants to
    // save from is actually on screen (`withholdsChatSizeFromSave`) —
    // otherwise this would conflate two different withholding rules.
    model.output = .videoWithChat
    model.selectQuality("720p0-1")
    model.chatSize = .small
    model.wantsToSaveDefaults = true

    model.saveDefaultsIfRequested()

    #expect(store.qualityCap == .p1080)
    #expect(store.chatSize == .small)
  }

  /// Spec §2.7. The trap this rule exists to disarm: one expired clip would
  /// otherwise turn chat off for every future download, from a single tick.
  /// Asserts the two fields that isolate "does withholding `output` touch
  /// anything else" — `destination` and `qualityCap`, neither of which has a
  /// control that output hides. `chatSize` is asserted separately below: it
  /// is withheld here too, but for §3.7's unrelated reason (its own picker
  /// disappears once `output == .video`), not because of this rule.
  @Test func outputIsWithheldWhileChatIsUnavailable() async {
    let store = Self.store { $0.output = .videoWithChat }
    let model = await loadedModel(
      preferences: store, info: Self.info(hasDownloadableChat: false))
    model.output = .videoWithChat

    #expect(model.chatProblem != nil)
    model.output = .video
    #expect(model.withholdsOutputFromSave)

    model.selectQuality("720p60")
    model.chatSize = .large
    model.wantsToSaveDefaults = true
    model.saveDefaultsIfRequested()

    #expect(store.output == .videoWithChat, "withheld: not overwritten by the workaround")
    #expect(store.chatSize == .medium, "withheld too — its picker is hidden while output is .video")
    #expect(store.destination == Self.folder)
    #expect(store.qualityCap == .p720)
  }

  /// §3.7's shape, applied to `chatSize`: its picker only renders while
  /// `output == .videoWithChat`, so once `.video` is selected the value on
  /// screen is stale by construction and must not be written.
  @Test func chatSizeIsWithheldWhileVideoOnlyIsSelected() async {
    let store = Self.store { $0.chatSize = .small }
    let model = await loadedModel(preferences: store)
    model.output = .video
    #expect(model.withholdsChatSizeFromSave)

    model.chatSize = .large
    model.wantsToSaveDefaults = true
    model.saveDefaultsIfRequested()

    #expect(store.chatSize == .small, "untouched — the picker that would have set this is hidden")
  }

  /// The positive control: with `.videoWithChat` selected, the picker is on
  /// screen and a save must write what it shows.
  @Test func chatSizeSavesNormallyWithVideoAndChatSelected() async {
    let store = Self.store()
    let model = await loadedModel(preferences: store)
    model.output = .videoWithChat
    #expect(!model.withholdsChatSizeFromSave)

    model.chatSize = .large
    model.wantsToSaveDefaults = true
    model.saveDefaultsIfRequested()

    #expect(store.chatSize == .large)
  }

  // MARK: - Options panel

  @Test func isOptionsExpandedWritesThroughToTheStore() async {
    let store = Self.store { $0.optionsPanelIsExpanded = true }
    let model = await loadedModel(preferences: store)

    model.isOptionsExpanded = false

    #expect(store.optionsPanelIsExpanded == false)
  }

  /// The `reset()` counterpart to `resetRereadsDestinationFellBackFrom-
  /// TheStoreRatherThanKeepingInitsAnswer` above, for the same reason: the
  /// obvious way to test "reset() reseeds `isOptionsExpanded`" is to mutate
  /// the model and then reset it, but `isOptionsExpanded` writes straight
  /// through on every assignment (§2.5) — mutating the model *is* mutating
  /// the store, so there is nothing left for `reset()` to overwrite. The
  /// store has to change out from under the model instead, through a second
  /// `Preferences` value over the same backing store, the way the destination
  /// does in the test above.
  @Test func resetRereadsIsOptionsExpandedFromTheStore() async {
    let store = Self.store { $0.optionsPanelIsExpanded = true }
    let model = await loadedModel(preferences: store)
    #expect(model.isOptionsExpanded, "precondition: seeded expanded")

    var mutator = store
    mutator.optionsPanelIsExpanded = false

    model.reset()

    #expect(model.isOptionsExpanded == false, "reset() must re-read the store, not keep init's answer")
  }

  /// §2.5. Collapsing the panel is not a statement about downloads, so it
  /// must not set the same flag a real save sets — otherwise the Settings
  /// window would start claiming defaults nobody chose from one triangle
  /// click.
  @Test func collapsingThePanelDoesNotSetHasSavedDefaults() async {
    let store = Self.store()
    let model = await loadedModel(preferences: store)

    model.isOptionsExpanded = false

    #expect(store.hasSavedDefaults == false)
  }

  /// §2.5's "collapses it once" — the visible payoff for opting in, tied to
  /// the explicit act of adding.
  @Test func savingCollapsesThePanel() async {
    let model = await loadedModel()
    model.isOptionsExpanded = true
    model.wantsToSaveDefaults = true

    model.saveDefaultsIfRequested()

    #expect(model.isOptionsExpanded == false)
  }

  @Test func notSavingLeavesThePanelAlone() async {
    let model = await loadedModel()
    model.isOptionsExpanded = true

    model.saveDefaultsIfRequested()

    #expect(model.isOptionsExpanded)
  }

  /// §2.5's "once", the other half: collapsing the panel is the payoff for
  /// the *first* save, not a side effect the app repeats on every Add
  /// afterward. A user who reopens the panel after configuring their
  /// defaults, then adds another job with the box still ticked, must not
  /// find it collapsed again out from under them.
  @Test func aLaterSaveLeavesThePanelAlone() async {
    let store = Self.store()
    let model = await loadedModel(preferences: store)
    model.wantsToSaveDefaults = true
    model.saveDefaultsIfRequested()
    #expect(model.isOptionsExpanded == false, "precondition: the first save collapsed it")
    #expect(store.hasSavedDefaults, "precondition: defaults are now configured")

    model.isOptionsExpanded = true
    model.wantsToSaveDefaults = true
    model.saveDefaultsIfRequested()

    #expect(model.isOptionsExpanded, "a later save must not re-collapse a reopened panel")
  }

  /// §2.7: both refusals force the panel open, whatever `isOptionsExpanded`
  /// itself says — a closed panel would grey Add out with the explanation
  /// sealed inside it.
  @Test func chatProblemForcesThePanelOpen() async {
    let model = await loadedModel(info: Self.info(hasDownloadableChat: false))
    model.output = .videoWithChat
    model.isOptionsExpanded = false

    #expect(model.chatProblem != nil, "precondition")
    #expect(model.isOptionsEffectivelyExpanded)
  }

  @Test func compositeProblemForcesThePanelOpen() async {
    let model = await loadedModel(
      info: Self.info(qualities: [
        StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0),
      ]))
    model.output = .videoWithChat
    model.selectQuality("720p0-1")
    model.isOptionsExpanded = false

    #expect(model.compositeProblem != nil, "precondition")
    #expect(model.isOptionsEffectivelyExpanded)
  }

  /// The transient half of §2.7: the forced expansion must never reach the
  /// stored preference, or a clip whose broadcast Twitch has expired would
  /// permanently reopen the drawer on every future launch — the store is read
  /// through a fresh instance here for exactly the reason
  /// `resetRereadsDestinationFellBackFromTheStoreRatherThanKeepingInitsAnswer`
  /// does: `model.isOptionsExpanded` alone cannot prove the store was never
  /// written to, only that the model's own copy of it looks right.
  @Test func theForcedExpansionNeverReachesTheStore() async {
    let store = Self.store { $0.optionsPanelIsExpanded = false }
    let model = await loadedModel(
      preferences: store, info: Self.info(hasDownloadableChat: false))
    model.output = .videoWithChat
    #expect(model.isOptionsExpanded == false, "precondition: never touched, still collapsed")

    #expect(model.isOptionsEffectivelyExpanded, "forced open by chatProblem")
    #expect(store.optionsPanelIsExpanded == false, "but the store never heard about it")
  }

  /// The binding a `DisclosureGroup` actually reads and writes: its getter is
  /// `isOptionsEffectivelyExpanded`.
  @Test func theEffectiveBindingReadsTheForcedOpenValue() async {
    let model = await loadedModel(info: Self.info(hasDownloadableChat: false))
    model.output = .videoWithChat
    model.isOptionsExpanded = false

    #expect(model.isOptionsEffectivelyExpandedBinding, "reads the forced-open value")
  }

  /// Before this guard existed, the binding's setter wrote through to
  /// `isOptionsExpanded` — and so to the store — unconditionally, even while
  /// a refusal was forcing the panel open. That made a triangle tap while
  /// `chatProblem` was showing a dead control with a permanent side effect:
  /// the drawer visibly stays open either way (the getter above still
  /// returns `true`), but the *stored* preference silently flipped underneath
  /// it, for every future intake. `isOptionsExpanded` is seeded `true` here
  /// specifically so an unguarded setter writing `false` would be a change
  /// this test can catch — starting from `false` could not distinguish
  /// "ignored" from "already false".
  @Test func theEffectiveBindingIgnoresWritesWhileForcedOpen() async {
    let model = await loadedModel(info: Self.info(hasDownloadableChat: false))
    model.output = .videoWithChat
    model.isOptionsExpanded = true
    #expect(model.chatProblem != nil, "precondition: the panel is forced open")

    model.isOptionsEffectivelyExpandedBinding = false

    #expect(model.isOptionsExpanded, "the write was ignored, not merely a no-op value")
  }

  /// The counterpart to the test above: once nothing is forcing the panel
  /// open, the same setter writes through exactly as it did before that
  /// guard existed — it only ever suppresses writes made *while* a refusal
  /// is showing, never writes in general.
  @Test func theEffectiveBindingWritesThroughOnceNothingForcesExpansion() async {
    let model = await loadedModel()
    #expect(model.chatProblem == nil, "precondition")
    #expect(model.compositeProblem == nil, "precondition")
    model.isOptionsExpanded = true

    model.isOptionsEffectivelyExpandedBinding = false

    #expect(model.isOptionsExpanded == false)
  }

  /// §2.6. The collapsed header's whole reason to exist: a summary the user
  /// can trust without opening the drawer.
  @Test func optionsSummaryDescribesOutputQualityAndFolder() async {
    let model = await loadedModel()
    model.output = .video
    model.qualityCap = .p720
    model.folder = URL(filePath: "/Users/t/Movies")

    #expect(model.optionsSummary == "Video · Up to 720p · Movies")
  }

  @Test func optionsSummaryNamesTheChatOutputAndAMissingFolder() async {
    let model = await loadedModel()
    model.output = .videoWithChat
    model.qualityCap = .best
    model.folder = nil

    #expect(model.optionsSummary == "Video + chat · Best available · No folder")
  }

  /// `optionsSummary` used to always say "Video + chat" /
  /// "Video" — a clip's collapsed header disagreed with its own expanded
  /// picker, which already said "Clip + chat" / "Clip" via `isClip`. Both
  /// call sites now read the same `IntakeModel.isClip`.
  @Test func optionsSummaryNamesAClipRatherThanAVideo() async {
    let model = await loadedModel(link: Self.clipLink)
    model.output = .videoWithChat
    model.qualityCap = .best
    model.folder = URL(filePath: "/Users/t/Movies")

    #expect(model.optionsSummary == "Clip + chat · Best available · Movies")

    model.output = .video
    #expect(model.optionsSummary == "Clip · Best available · Movies")
  }

  @Test func isClipReflectsTheParsedTarget() async {
    let vod = await loadedModel()
    #expect(vod.isClip == false)

    let clip = await loadedModel(link: Self.clipLink)
    #expect(clip.isClip)
  }

  // MARK: - An occupied destination

  /// The whole point: the warning is what turns a silent overwrite into a
  /// choice. Nothing is blocked — re-downloading over a bad copy stays one
  /// click — but the click is named for what it does.
  @Test func reportsTheFileAlreadySittingAtTheDestination() async {
    let model = await loadedModel(fileExists: { _ in true })
    let expected = Self.folder.appending(path: model.outputBaseName + OutputSuffix.video)

    #expect(model.destinationCollision == expected)
  }

  /// Only the name this job would actually write counts. A folder holding
  /// other files must not read as a collision.
  @Test func reportsNoCollisionWhenTheDestinationItselfIsFree() async {
    let model = await loadedModel(
      fileExists: { $0 == Self.folder.appending(path: "something else.mp4") })

    #expect(model.destinationCollision == nil)
  }

  /// A form with no destination chosen has nothing to collide with, and must
  /// not probe a path it has not got.
  @Test func reportsNoCollisionWithoutAFolder() async {
    let model = await loadedModel(fileExists: { _ in true })
    model.folder = nil

    #expect(model.destinationCollision == nil)
  }

  /// Before the video is known the name is a placeholder, so a warning about
  /// it would be about a file this job is never going to write.
  @Test func reportsNoCollisionBeforeTheVideoIsKnown() {
    let model = makeModel(fileExists: { _ in true })
    model.folder = Self.folder

    #expect(model.destinationCollision == nil)
  }

  /// The engine may only destroy a file the user was warned about. This is
  /// the one place that authorization is granted, and it is granted from the
  /// same condition the sheet drew its warning from — so a job can never
  /// carry permission for a warning nobody saw.
  @Test func authorizesReplacementOnlyWhenTheWarningWasShown() async throws {
    let warned = await loadedModel(fileExists: { _ in true })
    #expect(try #require(warned.composedTemplate()).replacesExistingFile)

    let unwarned = await loadedModel(fileExists: { _ in false })
    #expect(try !#require(unwarned.composedTemplate()).replacesExistingFile)
  }

  // MARK: - Starting over

  /// The bug this exists for: Add Download is one `Window` for the app's whole
  /// run, so the model survives a close and the second open showed the first
  /// link again.
  @Test func resetClearsEverythingAboutTheVideoJustAdded() async {
    let model = await loadedModel()
    model.trimStartText = "00:01:00"
    model.trimEndText = "00:02:00"
    #expect(!model.linkText.isEmpty)
    #expect(!model.name.isEmpty)

    model.reset()

    #expect(model.linkText.isEmpty)
    #expect(model.name.isEmpty)
    #expect(model.quality.isEmpty)
    #expect(model.trimStartText.isEmpty)
    #expect(model.trimEndText.isEmpty)
    #expect(model.info == nil)
    #expect(!model.hasSettledMetadata)
  }

  /// Chat is on by default: it is the output that distinguishes Oxbow, and a
  /// user who wants only the video is one click from it. Pinned because every
  /// other test in this file sets `output` explicitly, so nothing else here
  /// would notice the default flipping back.
  @Test func chatIsIncludedByDefault() {
    #expect(DownloadOutput.allCases.first == .videoWithChat, "and listed first")
    #expect(makeModel().output == .videoWithChat)
  }

  /// A reset while a fetch is in flight must invalidate it, or the reply lands
  /// in the emptied form and names the next download after the last one.
  ///
  /// The waiting matters: `reset()` empties `linkText`, so a `load()` that has
  /// not yet reached its fetch returns at the `guard let target` instead and
  /// the race never happens. Written without `waitForArrival` this test passes
  /// with the `generation` bump deleted, which is to say it tests nothing.
  /// `name` is the assertion that bites — `info` is nil either way once the
  /// link is gone, because nothing describes a link that is not there.
  @Test func aFetchStillInFlightCannotSettleIntoAResetForm() async {
    let gate = AsyncGate()
    let model = IntakeModel(
      fetchInfo: { _ in
        await gate.arriveAndWait()
        return IntakeModelTests.info()
      },
      enqueue: { _, _ in },
      calendar: Self.pacific,
      preferences: Self.store())
    model.linkText = Self.videoLink

    async let loading: Void = model.load()
    await gate.waitForArrival()
    model.reset()
    await gate.open()
    await loading

    #expect(model.name.isEmpty)
    #expect(model.linkText.isEmpty)
    #expect(!model.hasSettledMetadata)
  }

  /// Lets a fetch be held open across a `reset()`, and lets the test wait
  /// until that fetch has genuinely started, without sleeping for either.
  private actor AsyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var hasArrived = false
    private var isOpen = false

    /// Called from inside the fake fetch: announces that it is running, then
    /// blocks until `open()`.
    func arriveAndWait() async {
      hasArrived = true
      for arrival in arrivals { arrival.resume() }
      arrivals.removeAll()
      guard !isOpen else { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func waitForArrival() async {
      guard !hasArrived else { return }
      await withCheckedContinuation { arrivals.append($0) }
    }

    func open() {
      isOpen = true
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
    }
  }

  // MARK: - Fixtures

  private static let videoLink = "https://www.twitch.tv/videos/2844548319"
  private static let videoID = "2844548319"
  private static let clipLink = "https://clips.twitch.tv/TangibleGiantPancakeKappa"
  private static let clipSlug = "TangibleGiantPancakeKappa"


  // MARK: - Not enough room

  /// The figures every test below is calibrated against, for the default
  /// fixture's one-hour VOD. Recomputing them by hand in each test would make
  /// a constant change look like six unrelated failures.
  ///
  /// | job | source | intermediate | composite | total |
  /// |---|---|---|---|---|
  /// | 1080p60 + chat | 3.6 | 1.7 | 2.5 | **7.9 GB** |
  /// | 720p60 + chat | 1.4 | 1.7 | 1.1 | **4.2 GB** |
  /// | 1080p60 alone | 3.6 | — | — | **3.6 GB** |
  private static let gigabyte: Int64 = 1_000_000_000

  /// The whole contract, and the same one the collision warning carries:
  /// advisory, never a gate. Two warnings in one panel where one blocks and
  /// one does not would teach the user that neither can be trusted.
  @Test func aSpaceWarningNeverBlocksAdd() async {
    let model = await loadedModel(volumeSpace: Self.volume(free: Self.gigabyte))
    model.output = .videoWithChat

    #expect(model.spaceWarning != nil, "precondition: a gigabyte cannot hold this job")
    #expect(model.canAdd, "the warning must not gate Add")
  }

  /// A machine with room says nothing at all. Stated because a warning that
  /// fires when it need not is the failure mode that makes people stop
  /// reading warnings.
  @Test func noSpaceWarningWhenThereIsRoom() async {
    let model = await loadedModel(volumeSpace: Self.volume(free: 100 * Self.gigabyte))
    model.output = .videoWithChat

    #expect(model.spaceWarning == nil)
  }

  /// Before the video is known the duration is a placeholder, so any number
  /// computed from it is fiction. Mirrors the same gate on
  /// `destinationCollision`.
  @Test func noSpaceWarningBeforeMetadataSettles() {
    let model = makeModel(volumeSpace: Self.volume(free: 1))
    model.folder = Self.folder

    #expect(model.spaceWarning == nil)
  }

  /// No destination, nothing to check, and in particular no volume to probe.
  @Test func noSpaceWarningWithoutAFolder() async {
    let model = await loadedModel(volumeSpace: Self.volume(free: 1))
    model.output = .videoWithChat
    model.folder = nil

    #expect(model.spaceWarning == nil)
  }

  /// The remedy is the point of the warning. "Insufficient disk space" tells
  /// the user something they would discover anyway; naming a rendition that
  /// fits turns it into one click of work.
  ///
  /// Six gigabytes sits between the 720p job (4.2) and the 1080p one (7.9),
  /// so exactly one rendition is a real remedy.
  @Test func theRemedyNamesALowerRenditionThatActuallyFits() async throws {
    let model = await loadedModel(volumeSpace: Self.volume(free: 6 * Self.gigabyte))
    model.output = .videoWithChat

    let remedy = try #require(model.spaceWarning?.remedy)
    #expect(remedy.qualityName == "720p60")
    #expect(remedy.needed < 6 * Self.gigabyte, "a remedy that also does not fit is not a remedy")
  }

  /// Offering a remedy that also does not fit is worse than offering none: it
  /// costs the user a click to learn nothing.
  @Test func noRemedyWhenEvenTheSmallestRenditionWouldNotFit() async {
    let model = await loadedModel(volumeSpace: Self.volume(free: Self.gigabyte))
    model.output = .videoWithChat

    #expect(model.spaceWarning != nil, "precondition")
    #expect(model.spaceWarning?.remedy == nil)
  }

  /// A plain download estimates only its source, so a volume too small for the
  /// composite can be fine without one. Asserts the warning tracks the output
  /// toggle rather than the video — five gigabytes holds the 3.6 GB download
  /// but not the 7.9 GB composite.
  @Test func switchingToVideoOnlyRecomputesTheWarning() async {
    let model = await loadedModel(volumeSpace: Self.volume(free: 5 * Self.gigabyte))

    model.output = .videoWithChat
    #expect(model.spaceWarning != nil)

    model.output = .video
    #expect(model.spaceWarning == nil)
  }

  /// Trimming is the other half of the same remedy. A user who only wants
  /// twenty minutes of a six-hour VOD should not be warned about six hours.
  @Test func trimmingTheRangeShrinksTheEstimate() async {
    let model = await loadedModel(volumeSpace: Self.volume(free: 5 * Self.gigabyte))
    model.output = .videoWithChat
    #expect(model.spaceWarning != nil, "precondition: the whole hour does not fit")

    model.trimStartText = "0:00"
    model.trimEndText = "10:00"

    #expect(model.spaceWarning == nil, "ten minutes of it does")
  }

  /// An unreadable volume produces no warning rather than a false one. The
  /// rule lives in `VolumeSpace`; this asserts the intake honours it instead
  /// of treating "unknown" as "no room".
  @Test func noSpaceWarningWhenTheVolumeCannotBeRead() async {
    let model = await loadedModel(volumeSpace: VolumeSpace(
      availableBytes: { _ in nil },
      volumeRoot: { _ in nil },
      volumeName: { _ in nil }))
    model.output = .videoWithChat

    #expect(model.spaceWarning == nil)
  }


  private static let folder = URL(filePath: "/Users/someone/Movies")

  /// Deliberately just after midnight UTC: read in Pacific it is the evening
  /// of the *previous* day, which is the day the name has to use (§4).
  private static let createdAt = ISO8601DateFormatter().date(from: "2026-08-24T04:30:00Z")!

  /// Every test passes this calendar, so the expected dates below hold
  /// wherever the suite runs.
  private static var pacific: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }

  private static func info(
    streamer: String = "leighxp",
    title: String = "A Stream",
    duration: Duration = .seconds(3600),
    qualities: [StreamQuality] = [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 8_000_000),
      StreamQuality(name: "720p60", resolution: "1280x720", bitsPerSecond: 3_000_000),
    ],
    hasDownloadableChat: Bool = true)
    -> VideoInfo
  {
    VideoInfo(
      streamer: streamer,
      title: title,
      createdAt: createdAt,
      duration: duration,
      qualities: qualities,
      hasDownloadableChat: hasDownloadableChat)
  }

  /// Captures what `add()` hands to the queue.
  private final class Recorder {
    var templates: [(template: JobTemplate, title: String)] = []
  }

  /// A store over its own `InMemoryPreferenceStore`, so a test never sees
  /// another test's values and never touches disk or the real preferences
  /// domain.
  ///
  /// **`static`, not an instance method.** It used to have to be an instance
  /// method, to register each scratch `UserDefaults` suite it created with a
  /// `deinit`-based janitor for cleanup — see the removed `SuiteJanitor` in
  /// git history. `InMemoryPreferenceStore` has nothing to clean up, so
  /// nothing here needs `self`, which is what lets `makeModel`/`loadedModel`
  /// below call it directly from a default-parameter expression again.
  private static func store(
    _ configure: (inout Preferences) -> Void = { _ in }) -> Preferences
  {
    // `directoryExists` is stubbed true because these destinations are
    // fictional. With the real FileManager predicate, `Preferences.destination`
    // correctly decides /Volumes/Archive is missing and hands back
    // ~/Downloads — and every seeding assertion below fails for a reason that
    // has nothing to do with what it is testing.
    var store = Preferences(
      store: InMemoryPreferenceStore(),
      homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { _ in true })
    configure(&store)
    return store
  }

  private func makeModel(
    preferences: Preferences = store(),
    info: VideoInfo? = IntakeModelTests.info(),
    failure: Error? = nil,
    recorder: Recorder = Recorder(),
    fileExists: @escaping (URL) -> Bool = { _ in false },
    volumeSpace: VolumeSpace = IntakeModelTests.volume(free: 1_000_000_000_000))
    -> IntakeModel
  {
    IntakeModel(
      fetchInfo: { _ in
        if let failure { throw failure }
        guard let info else { throw VideoInfoFetchError.unparseableOutput(snippet: "") }
        return info
      },
      enqueue: { recorder.templates.append((template: $0, title: $1)) },
      calendar: Self.pacific,
      fileExists: fileExists,
      volumeSpace: volumeSpace,
      preferences: preferences)
  }

  /// One volume with a fixed amount of room. Defaulted to a terabyte
  /// everywhere so no pre-existing test starts seeing a space warning it was
  /// never written to expect.
  private static func volume(free: Int64) -> VolumeSpace {
    VolumeSpace(
      availableBytes: { _ in free },
      volumeRoot: { _ in URL(filePath: "/") },
      volumeName: { _ in "Macintosh HD" })
  }

  /// A model with metadata settled, a folder chosen, and `.video` as its
  /// output — the minimum state in which Add is legal. Video-only is set
  /// explicitly rather than relied on: the sheet's default is
  /// `.videoWithChat`, and a helper that silently followed it would turn
  /// every test below into a composite test.
  private func loadedModel(
    link: String = IntakeModelTests.videoLink,
    preferences: Preferences = store(),
    info: VideoInfo = IntakeModelTests.info(),
    recorder: Recorder = Recorder(),
    fileExists: @escaping (URL) -> Bool = { _ in false },
    volumeSpace: VolumeSpace = IntakeModelTests.volume(free: 1_000_000_000_000))
    async -> IntakeModel
  {
    let model = makeModel(
      preferences: preferences, info: info, recorder: recorder, fileExists: fileExists,
      volumeSpace: volumeSpace)
    model.linkText = link
    await model.load()
    model.folder = Self.folder
    model.output = .video
    return model
  }

  /// A VOD with settled metadata offering exactly one quality, so a
  /// composite's geometry is easy to predict. `quality` also becomes the
  /// model's own selection when it is non-empty; left empty, the model keeps
  /// its default of "best available" and the fixture still needs a rendition
  /// on offer for `compositeQuality`'s fallback to resolve.
  ///
  /// Reuses `loadedModel` rather than inventing a second way to settle
  /// metadata — the only difference is the single, resolution-bearing quality
  /// a composite needs.
  private func loaded(
    quality: String,
    resolution: String,
    bitsPerSecond: Int = 6_000_000)
    async
    -> IntakeModel
  {
    let name = quality.isEmpty ? "source" : quality
    let model = await loadedModel(
      info: Self.info(qualities: [
        StreamQuality(name: name, resolution: resolution, bitsPerSecond: bitsPerSecond),
      ]))
    model.quality = quality
    return model
  }

  /// The clip equivalent of `loaded(quality:resolution:)` — same fixture
  /// mechanism, a clip link instead of a VOD one.
  private func loadedClip(
    quality: String,
    resolution: String,
    bitsPerSecond: Int = 6_000_000)
    async
    -> IntakeModel
  {
    let name = quality.isEmpty ? "source" : quality
    let model = await loadedModel(
      link: Self.clipLink,
      info: Self.info(qualities: [
        StreamQuality(name: name, resolution: resolution, bitsPerSecond: bitsPerSecond),
      ]))
    model.quality = quality
    return model
  }

  private func videoRequest(of template: JobTemplate) -> VideoRequest? {
    guard case .video(let request) = template.media else { return nil }
    return request
  }

  private func clipRequest(of template: JobTemplate) -> ClipRequest? {
    guard case .clip(let request) = template.media else { return nil }
    return request
  }

  // MARK: - Add's preconditions

  /// The positive control for every "Add is disabled" test below. Without it
  /// they would all pass just as well against a `canAdd` that is simply
  /// always false.
  @Test func addIsEnabledWithMetadataAFolderAndOneOutput() async {
    let model = await loadedModel()
    #expect(model.canAdd)
  }

  @Test func addIsDisabledUntilMetadataHasSettled() async {
    let model = makeModel()
    model.linkText = Self.videoLink
    model.folder = Self.folder

    #expect(!model.canAdd, "no metadata has been asked for yet")

    await model.load()
    #expect(model.canAdd)
  }

  @Test func addIsDisabledWithNoFolderChosen() async {
    let model = await loadedModel()
    model.folder = nil

    #expect(!model.canAdd)
  }

  @Test func addIsDisabledWhenTheLinkIsNotATwitchAddress() async {
    let model = await loadedModel()
    model.linkText = "https://example.com/videos/123"

    #expect(model.isLinkUnrecognized)
    #expect(!model.canAdd)
  }

  /// Metadata belongs to the link it was fetched for. Pasting another one
  /// must disable Add until that link's own fetch settles, or a job gets
  /// composed for one video out of another's details.
  @Test func addIsDisabledAgainOnceTheLinkChanges() async {
    let model = await loadedModel()
    #expect(model.canAdd)

    model.linkText = "https://www.twitch.tv/videos/999999"

    #expect(!model.canAdd)
    #expect(model.info == nil, "the previous video's details are not this link's")
  }

  // MARK: - Naming

  @Test func theNameIsPrefilledFromTheVideosOwnMetadata() async {
    let model = await loadedModel()
    #expect(model.name == "leighxp - 2026-08-23 - A Stream")
  }

  /// `createdAt` is 04:30 UTC on the 24th; in Pacific that is the evening of
  /// the 23rd, and the 23rd is the day both the streamer and the viewer think
  /// it happened (design doc §4).
  @Test func theNameUsesTheLocalDateRatherThanTheUTCOne() async {
    let model = await loadedModel()
    #expect(model.name.contains("2026-08-23"))
    #expect(!model.name.contains("2026-08-24"))
  }

  /// The base name reserves room for the only suffix an output can take —
  /// `".mp4"`, 4 bytes — whether the job produces a plain video or a
  /// composite, since both share that same suffix (a composite replaces the
  /// video it stacks rather than accompanying it).
  @Test func aLongTitleLeavesRoomForTheOnlySuffix() async throws {
    let model = await loadedModel(info: Self.info(title: String(repeating: "a", count: 400)))
    #expect(model.name.utf8.count == 255 - 4, "reserved for \".mp4\"")

    let template = try #require(model.composedTemplate())
    let name = try #require(videoRequest(of: template)?.destination?.lastPathComponent)
    #expect(name.utf8.count <= 255, "\(name) is \(name.utf8.count) bytes")
  }

  /// The name field is the user's, and it is the seam the prefilled-name test
  /// above cannot reach: that name arrives from `load()` already reserved, so
  /// re-sanitizing it with any budget at all leaves it unchanged. A name the
  /// user edited or pasted has had no reservation applied, and `outputBaseName`
  /// is the only thing standing between it and a path over the filesystem's
  /// 255-byte limit.
  @Test func aLongEditedNameStillFitsInAFilename() async throws {
    let model = await loadedModel()
    model.name = String(repeating: "b", count: 250)

    let template = try #require(model.composedTemplate())
    let name = try #require(videoRequest(of: template)?.destination?.lastPathComponent)
    #expect(name.utf8.count <= 255, "\(name.utf8.count) bytes: \(name)")
  }

  /// The name field is the user's, and a user can type a `/`. Left alone it
  /// would turn `appending(path:)` into a directory traversal rather than a
  /// filename.
  @Test func anEditedNameIsSanitisedBeforeItBecomesAPath() async throws {
    let model = await loadedModel()
    model.name = "why/not: both"

    let template = try #require(model.composedTemplate())
    let destination = try #require(videoRequest(of: template)?.destination)

    #expect(destination.lastPathComponent == "why-not- both.mp4")
    #expect(destination.deletingLastPathComponent().path == Self.folder.path)
  }

  @Test func anEmptiedNameFallsBackRatherThanDisablingAdd() async throws {
    let model = await loadedModel()
    model.name = "   "

    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.destination?.lastPathComponent == "untitled.mp4")
  }

  // MARK: - Output (design doc §3)

  @Test func videoOnlyProducesNoChatAndNoComposite() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .video
    let template = try #require(model.composedTemplate())
    #expect(template.chat == nil)
    #expect(template.render == nil)
    #expect(template.composite == nil)
    #expect(template.media != nil)
  }

  @Test func videoWithChatKeepsOnlyTheCompositeDestination() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    let template = try #require(model.composedTemplate())

    let composite = try #require(template.composite)
    #expect(composite.destination.lastPathComponent.hasSuffix(".mp4"))
    #expect(composite.framerate == 60)

    // The inputs are intermediates: one file lands in the user's folder.
    guard case .video(let video)? = template.media else {
      Issue.record("expected video media"); return
    }
    #expect(video.destination == nil)
    #expect(template.render?.destination == nil)
    #expect(template.chat?.destination == nil)
    // Built here rather than left to `JobTemplate`'s implied chat request —
    // seeding it from an empty id would produce a job that runs and
    // downloads nothing.
    #expect(template.chat?.videoID == Self.videoID)
  }

  /// The composite's `duration` is its own field, not `framerate`'s neighbour
  /// by coincidence — it has to be seeded from the video's own duration, not
  /// left at some default that happens to compile.
  ///
  /// There is no bitrate to seed any more. `.composite` asks the encoder for a
  /// quality and lets it choose the cost, so `CompositeRequest` carries no
  /// rate at all — see `docs/design/composite-rate-control.md`.
  @Test func theCompositeSeedsItsDurationFromTheChosenQuality() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080", bitsPerSecond: 10_000_000)
    model.output = .videoWithChat
    let composite = try #require(model.composedTemplate()?.composite)
    #expect(composite.framerate == 60)
    #expect(composite.duration == .seconds(3600), "the hour-long duration `Self.info()` fixes")
  }

  @Test func aClipGetsTheSameTwoChoicesAsAVOD() async throws {
    let model = await loadedClip(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    let template = try #require(model.composedTemplate())

    guard case .clip(let clip)? = template.media else {
      Issue.record("expected clip media"); return
    }
    #expect(clip.destination == nil)
    #expect(template.composite?.destination != nil)
    // chatdownload --id takes a slug as readily as a VOD id.
    #expect(template.chat?.videoID == clip.clipSlug)
  }

  /// "Best available" leaves the resolution unknown, which is fatal when the
  /// chat's height must equal the video's.
  @Test func compositingResolvesAnEmptyQualityToAConcreteOne() async throws {
    let model = await loaded(quality: "", resolution: "1920x1080")
    model.output = .videoWithChat
    let template = try #require(model.composedTemplate())
    guard case .video(let video)? = template.media else {
      Issue.record("expected video media"); return
    }
    #expect(!video.quality.isEmpty)
  }

  /// Video-only must not have its default changed as a side effect.
  @Test func videoOnlyLeavesAnEmptyQualityAlone() async throws {
    let model = await loaded(quality: "", resolution: "1920x1080")
    model.output = .video
    let template = try #require(model.composedTemplate())
    guard case .video(let video)? = template.media else {
      Issue.record("expected video media"); return
    }
    #expect(video.quality.isEmpty)
  }

  /// The bug this pins: a name upstream disambiguated with a trailing
  /// `-<digits>` (`480p30-1`, `480p30-2`, …) does not resolve as `-q` at all —
  /// verified against the real bundled helper, it silently falls back to the
  /// highest rendition, exit code 0, no warning. `model.quality` keeps the
  /// picker's exact name (it is matched against `qualities` by name, and the
  /// picker's own tag), but the request that reaches the CLI must carry
  /// `StreamQuality.commandLineValue` instead.
  @Test func theVideoRequestPassesTheStrippedQualityNotThePickerName() async throws {
    let model = await loaded(quality: "480p30-1", resolution: "852x480")
    model.output = .video
    let template = try #require(model.composedTemplate())
    let video = try #require(videoRequest(of: template))
    #expect(video.quality == "480p30")
  }

  @Test func theClipRequestPassesTheStrippedQualityNotThePickerName() async throws {
    let model = await loadedClip(quality: "480p30-2", resolution: "852x480")
    model.output = .video
    let template = try #require(model.composedTemplate())
    let clip = try #require(clipRequest(of: template))
    #expect(clip.quality == "480p30")
  }

  /// The composite path resolves through `compositeQuality` rather than
  /// `commandLineQuality`, but the same stripping has to happen before the
  /// name reaches the media request.
  @Test func theCompositesMediaRequestPassesTheStrippedQualityNotThePickerName() async throws {
    let model = await loaded(quality: "1080p60-1", resolution: "1920x1080")
    model.output = .videoWithChat
    let template = try #require(model.composedTemplate())
    let video = try #require(videoRequest(of: template))
    #expect(video.quality == "1080p60")
  }

  /// `-Portrait` is not affected — measured separately — so a portrait pick
  /// must reach the CLI unchanged rather than stripped.
  @Test func aPortraitQualityReachesTheRequestUnchanged() async throws {
    let model = await loaded(quality: "480p30-Portrait", resolution: "480x853")
    model.output = .video
    let template = try #require(model.composedTemplate())
    let video = try #require(videoRequest(of: template))
    #expect(video.quality == "480p30-Portrait")
  }

  @Test func theRenderMatchesTheVideosGeometry() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    let render = try #require(model.composedTemplate()?.render)
    #expect(render.height == 1080)
    #expect(render.width == 360)
    #expect(render.framerate == 30)
    // A transient input that is immediately re-encoded: 3 Mbps would put two
    // generations of lossy H.264 over text on flat backgrounds.
    #expect(render.bitrateMbps >= 12)
  }

  @Test func chatSizeDefaultsToMedium() {
    let model = makeModel()
    #expect(model.chatSize == .medium)
  }

  /// One row per `ChatSize` case, matching the table in
  /// `docs/design/compositing.md` §4 for a 1080p (360-wide) chat column.
  @Test(arguments: [
    (ChatSize.small, 13.0),
    (ChatSize.medium, 16.0),
    (ChatSize.large, 20.0),
  ])
  func chatSizeSetsTheRendersFontSize(size: ChatSize, expectedFontSize: Double) async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    model.chatSize = size
    let render = try #require(model.composedTemplate()?.render)
    #expect(render.fontSize == expectedFontSize)
  }

  /// `.video` has no render at all, so a chosen chat size — meaningless
  /// without one — must not change what gets composed. `JobTemplate` is not
  /// itself `Equatable` (its `Media` enum carries no such conformance), so
  /// this compares the one part that could plausibly have drifted.
  @Test func chatSizeIsIgnoredWhenNoChatIsRequested() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .video

    model.chatSize = .large
    let large = try #require(model.composedTemplate())
    model.chatSize = .small
    let small = try #require(model.composedTemplate())

    #expect(videoRequest(of: large) == videoRequest(of: small))
    #expect(large.render == nil)
    #expect(large.chat == nil)
    #expect(large.composite == nil)
  }

  /// A clip's rendition list can carry a quality with no pixel dimensions —
  /// `VideoInfo.clipResolution` has no filter for it, unlike a VOD's
  /// `parseQualities`, which skips a variant with no `RESOLUTION` attribute
  /// outright. When *none* of the clip's renditions parse, "best available"
  /// has nothing to fall back to.
  @Test func compositingRefusesWhenNoRenditionCanBeComposited() async throws {
    let qualities = [StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0)]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))
    model.output = .videoWithChat

    #expect(model.composedTemplate() == nil)
    #expect(!model.canAdd)
  }

  /// A failed fetch still settles (`hasSettledMetadata` counts `.failed`),
  /// but `info` — and so `qualities` and the composite's duration — stays
  /// nil. A composite needs both, so it refuses rather than crash on a force
  /// unwrap or compose a job with a guessed duration.
  @Test func compositingRefusesWithoutMetadata() async throws {
    let model = makeModel(failure: VideoInfoFetchError.unparseableOutput(snippet: "x"))
    model.linkText = Self.videoLink
    await model.load()
    model.folder = Self.folder
    model.output = .videoWithChat

    #expect(model.info == nil)
    #expect(model.composedTemplate() == nil)
    #expect(!model.canAdd)
  }

  // MARK: - Composite problem

  /// The positive control: a chosen quality that parses fine has nothing to
  /// explain.
  @Test func compositeProblemIsNilWhenTheChosenQualityCanBeComposited() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    #expect(model.compositeProblem == nil)
  }

  /// `.video` never makes a quality decision for compositing, so it can never
  /// have a composite problem — even sitting on a quality that could not be
  /// composited.
  @Test func compositeProblemIsNilForVideoOnly() async throws {
    let qualities = [StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0)]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))
    model.quality = "720p0-1"

    #expect(model.compositeProblem == nil)
  }

  /// The bug the review caught: `compositeQuality` honours an explicit pick
  /// even when it cannot be composited (see its doc comment — silently
  /// substituting a different rendition is worse), which used to mean Add
  /// simply greyed out with nothing on screen explaining why.
  @Test func choosingAnExplicitQualityWithNoDimensionsExplainsWhyAddIsDisabled() async throws {
    let qualities = [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_000_000),
      StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0),
    ]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))
    model.output = .videoWithChat
    model.quality = "720p0-1"

    // Not silently substituted for the 1080p60 that *would* work.
    #expect(model.composedTemplate() == nil)
    #expect(!model.canAdd)

    let problem = try #require(model.compositeProblem)
    #expect(problem.contains("720p0-1"), "names the rendition, not a generic failure")
    #expect(problem.contains("Pick another quality"), "says what to do, not just what's wrong")
  }

  /// `480p30-Portrait` is a real rendition whose clip-API metadata claims
  /// `480x853`, an odd height. The real decoded stream is `480x852` — h264
  /// 4:2:0 cannot carry an odd coded dimension, so 853 is a rounding
  /// artifact in Twitch's metadata, not a real frame.
  /// `CompositeGeometry.init?` rounds it down to the true 852 rather than
  /// refusing, so this composes rather than disabling Add.
  @Test func anOddHeightInMetadataComposesAtItsRoundedDownValue() async throws {
    let qualities = [
      StreamQuality(name: "480p30-Portrait", resolution: "480x853", bitsPerSecond: 1_000_000),
    ]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))
    model.output = .videoWithChat
    model.quality = "480p30-Portrait"

    #expect(model.compositeProblem == nil)
    let render = try #require(model.composedTemplate()?.render)
    #expect(render.height == 852, "rounded down from the metadata's odd 853")
  }

  // MARK: - Chat problem

  /// A clip whose parent broadcast is gone. The chat step would abort the
  /// helper on SIGABRT the moment it ran, and — because `JobTemplate.makeJob`
  /// appends the chat step *first*, so the short download claims the network
  /// slot — it would do so before the video download it was racing. The video
  /// step has no `dependsOn`, so it would then download in full into a
  /// workspace intermediate with no destination, and the composite, assemble
  /// and render steps would all be blocked behind the failed chat. The user
  /// would wait out an entire video download to receive no file at all.
  ///
  /// So this refuses up front rather than explaining afterwards.
  @Test func aClipWhoseBroadcastIsGoneCannotBeAddedWithChat() async throws {
    let model = await loadedModel(
      link: Self.clipLink,
      info: Self.info(
        qualities: [StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_000_000)],
        hasDownloadableChat: false))
    model.output = .videoWithChat

    #expect(model.composedTemplate() == nil)
    #expect(!model.canAdd)

    let problem = try #require(model.chatProblem)
    #expect(problem.contains("no longer on Twitch"))
    #expect(!problem.contains("Invalid VOD"), "upstream's diagnostic must not reach the sheet")
  }

  /// The whole point of refusing only the chat: the clip's *video* downloads
  /// fine, so video-only must stay available and stay addable. A user who
  /// picks it gets their clip.
  @Test func aClipWhoseBroadcastIsGoneCanStillBeAddedAsVideoOnly() async throws {
    let model = await loadedModel(
      link: Self.clipLink,
      info: Self.info(hasDownloadableChat: false))

    #expect(model.chatProblem == nil, "video-only has no chat to explain away")
    #expect(model.canAdd)
  }

  /// The positive control: a clip whose broadcast is still up has nothing to
  /// explain.
  @Test func chatProblemIsNilForAClipThatStillHasItsBroadcast() async throws {
    let model = await loadedClip(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    #expect(model.chatProblem == nil)
  }

  /// A VOD is the broadcast, so this can never fire for one. Guards against a
  /// clip-only rule that quietly disables chat for every VOD in the app.
  @Test func chatProblemIsNilForAVod() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    #expect(model.chatProblem == nil)
  }

  // MARK: - Quality

  @Test func theQualityPickerOffersWhatTheMetadataListed() async {
    let model = await loadedModel()
    #expect(model.qualities.map(\.name) == ["1080p60", "720p60"])
  }

  @Test func theDefaultQualityIsEmptyMeaningBestAvailable() async throws {
    let model = await loadedModel()
    #expect(model.quality == "")
    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.quality == "")
  }

  @Test func theChosenQualityReachesTheRequest() async throws {
    let model = await loadedModel()
    model.quality = "720p60"
    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.quality == "720p60")
  }

  /// 8 Mbps over an hour: 8_000_000 x 3600 / 8 bytes.
  @Test func theSizeEstimateIsBitrateTimesDuration() async throws {
    let model = await loadedModel()
    let quality = try #require(model.qualities.first)
    #expect(model.estimatedBytes(for: quality) == 3_600_000_000)
  }

  /// A trim narrows the estimate the same way it narrows the actual
  /// download — the size shown must describe what will land on disk, not
  /// the untrimmed VOD. `Self.info()` fixes the VOD at an hour with a
  /// bitrate that makes the full estimate 3_600_000_000 bytes (above); a
  /// 10-minute trim is a sixth of that.
  @Test func theSizeEstimateAccountsForATrimmedWindow() async throws {
    let model = await loadedModel()
    model.trimStartText = "0:00"
    model.trimEndText = "10:00"
    let quality = try #require(model.qualities.first)
    #expect(model.estimatedBytes(for: quality) == 600_000_000)
  }

  @Test func thereIsNoSizeEstimateWithoutMetadata() {
    let model = makeModel()
    let quality = StreamQuality(name: "x", resolution: "y", bitsPerSecond: 1)
    #expect(model.estimatedBytes(for: quality) == nil)
  }

  /// The pixel size is on the row because the name does not always imply it:
  /// `480p30` is 852x480, not 854 or 640, and a clip's upstream-derived name
  /// degenerates to things like `720p0`.
  @Test func aQualityRowNamesItsResolutionAndItsEstimate() async throws {
    let model = await loadedModel()
    let quality = try #require(model.qualities.first)

    let label = model.label(for: quality)
    #expect(label.hasPrefix("1080p60"))
    #expect(label.contains("1920x1080"))
    #expect(label.contains("about"), "the estimate is labelled as one (§6)")
    #expect(label.contains("GB"), "3.6 GB, formatted for the reader")
  }

  /// Older clips carry `bitrate: 0` for every rendition, so there is no
  /// estimate to show — and then the resolution is the only thing telling one
  /// row from the next. A zero is the absence of an estimate, not an estimate
  /// of nothing, so it is left off rather than printed as "about Zero KB".
  @Test func aQualityRowWithNoBitrateNamesItsResolutionAndNoEstimate() async throws {
    let qualities = [StreamQuality(name: "720p0-1", resolution: "1280x720", bitsPerSecond: 0)]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))
    let quality = try #require(model.qualities.first)

    #expect(model.label(for: quality) == "720p0-1 · 1280x720")
  }

  /// A rendition Twitch described with neither pixel dimensions nor a usable
  /// `quality` string: the row is the bare name rather than a dangling
  /// separator.
  @Test func aQualityRowWithNoResolutionIsJustTheName() {
    let model = makeModel()
    let quality = StreamQuality(name: "audio_only", resolution: "", bitsPerSecond: 0)
    #expect(model.label(for: quality) == "audio_only")
  }

  // MARK: - Clips (design doc §8)

  @Test func aClipTargetHidesTrimOptions() async {
    let clip = await loadedModel(link: Self.clipLink)
    #expect(!clip.showsTrimOptions)

    let video = await loadedModel()
    #expect(video.showsTrimOptions, "a VOD still offers them")
  }

  @Test func aClipTargetOffersTheClipsOwnQualities() async throws {
    let qualities = [StreamQuality(name: "1080", resolution: "1920x1080", bitsPerSecond: 6_000_000)]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))

    #expect(model.qualities == qualities)
    model.quality = "1080"
    let template = try #require(model.composedTemplate())
    #expect(clipRequest(of: template)?.quality == "1080")
  }

  @Test func aClipComposesAClipDownloadNotAVideoOne() async throws {
    let model = await loadedModel(link: Self.clipLink)
    let template = try #require(model.composedTemplate())

    #expect(clipRequest(of: template)?.clipSlug == Self.clipSlug)
    #expect(videoRequest(of: template) == nil)
  }

  /// Trim text typed while a VOD was in the field must not leak into a clip's
  /// job: clips have no trim, and its chat request would otherwise be
  /// silently narrowed to a window the clip does not have.
  @Test func trimTextIsIgnoredEntirelyForAClip() async throws {
    let model = await loadedModel(link: Self.clipLink)
    model.output = .videoWithChat
    model.trimStartText = "1:00"
    model.trimEndText = "2:00"

    let template = try #require(model.composedTemplate())
    #expect(template.chat?.trimStart == nil)
    #expect(template.chat?.trimEnd == nil)
    #expect(model.canAdd, "a hidden field cannot make Add refuse")
  }

  // MARK: - Trim

  /// A trimmed video rendered against the whole VOD's chat is wrong output
  /// that looks like a success, so both requests get the same window.
  @Test func trimTimesReachBothTheVideoAndItsChat() async throws {
    let model = await loadedModel(info: Self.info(duration: .seconds(7200)))
    model.output = .videoWithChat
    model.trimStartText = "1:00"
    model.trimEndText = "1:02:03"

    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.trimStart == .seconds(60))
    #expect(videoRequest(of: template)?.trimEnd == .seconds(3723))
    #expect(template.chat?.trimStart == .seconds(60))
    #expect(template.chat?.trimEnd == .seconds(3723))
  }

  /// The composite's own `duration` is what `FFmpegProgressParser` divides
  /// by for every fraction and ETA it reports while the step runs. Left at
  /// the full VOD's length on a trimmed job, a composite that only ever
  /// encodes the trimmed window can never report more than a sliver of
  /// progress, and its ETA counts down against footage it will never touch.
  @Test func aTrimmedCompositesDurationIsTheTrimmedWindowNotTheWholeVOD() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080", bitsPerSecond: 10_000_000)
    model.output = .videoWithChat
    model.trimStartText = "10:00"
    model.trimEndText = "40:00"

    let composite = try #require(model.composedTemplate()?.composite)
    #expect(composite.duration == .seconds(1800))
  }

  @Test func aTrimmedCompositesDurationWithOnlyAStartUsesTheVODsEnd() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080", bitsPerSecond: 10_000_000)
    model.output = .videoWithChat
    model.trimStartText = "10:00"

    let composite = try #require(model.composedTemplate()?.composite)
    // `Self.info()` fixes the VOD at an hour long (see the untrimmed test
    // above), so a 10-minute start with no end runs to 3600s - 600s = 3000s.
    #expect(composite.duration == .seconds(3000))
  }

  @Test func noTrimTextMeansNoTrim() async throws {
    let model = await loadedModel()
    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.trimStart == nil)
    #expect(videoRequest(of: template)?.trimEnd == nil)
  }

  @Test func anUnreadableTrimTimeRefusesRatherThanReadingAsNoTrim() async {
    let model = await loadedModel()
    model.trimStartText = "half an hour"

    #expect(model.trimIsInvalid)
    #expect(!model.canAdd)
  }

  @Test func anEndAtOrBeforeTheStartRefuses() async {
    let model = await loadedModel()
    model.trimStartText = "2:00"
    model.trimEndText = "1:00"
    #expect(!model.canAdd)

    model.trimEndText = "2:00"
    #expect(!model.canAdd, "a zero-length trim is not a trim")

    model.trimEndText = "2:01"
    #expect(model.canAdd)
  }

  /// A start past the end of the video reaches the CLI as an argument that
  /// fails minutes into a download, which is the exact failure `trimIsInvalid`
  /// exists to get ahead of.
  @Test func refusesATrimPastTheEndOfTheVideo() async {
    let model = await loadedModel(info: Self.info(duration: .seconds(2400)))

    model.trimStartText = "01:00:00"
    #expect(model.trimIsInvalid)

    model.trimStartText = ""
    model.trimEndText = "01:00:00"
    #expect(model.trimIsInvalid)
  }

  /// An end at exactly the last frame is the whole video, which is fine. A
  /// start there selects nothing, which is not.
  @Test func acceptsAnEndAtTheVideosLengthButNotAStartThere() async {
    let model = await loadedModel(info: Self.info(duration: .seconds(2400)))

    model.trimEndText = "00:40:00"
    #expect(!model.trimIsInvalid)

    model.trimEndText = ""
    model.trimStartText = "00:40:00"
    #expect(model.trimIsInvalid)
  }

  @Test func timecodesAreReadAsSecondsMinutesAndHours() {
    #expect(Timecode.parse("90") == .seconds(90))
    #expect(Timecode.parse("1:30") == .seconds(90))
    #expect(Timecode.parse("1:02:03") == .seconds(3723))
    #expect(Timecode.parse(" 1:30 ") == .seconds(90))
  }

  /// Swift traps on integer overflow, so an over-long number in the trim
  /// field used to take the whole app down — from a text field, with no
  /// privileged input. Too big to be a time is invalid input like any other.
  @Test func anOverflowingTimecodeIsRejectedRatherThanTrapping() async {
    #expect(Timecode.parse("999999999999999999:0") == nil, "overflows the x60")
    #expect(Timecode.parse("99999999999999999999999999") == nil, "too long for Int at all")
    #expect(Timecode.parse("999999999999999999:59:59") == nil)
    // The largest value that does NOT overflow still has to convert to a
    // `Duration` rather than trapping on the way out.
    #expect(Timecode.parse("9223372036854775807") != nil)

    // And it reaches the sheet as a refusal, not a crash.
    let model = await loadedModel()
    model.trimStartText = "999999999999999999:0"
    #expect(model.trimIsInvalid)
    #expect(!model.canAdd)
  }

  @Test func malformedTimecodesAreRejectedRatherThanCoerced() {
    #expect(Timecode.parse("") == nil)
    #expect(Timecode.parse("abc") == nil)
    #expect(Timecode.parse("1:2:3:4") == nil)
    #expect(Timecode.parse("1:90") == nil, "90 is not a seconds field")
    #expect(Timecode.parse("1:") == nil)
    #expect(Timecode.parse("+5") == nil)
    #expect(Timecode.parse("１:３０") == nil, "full-width digits are not a timecode")
  }

  /// Collapsing the section hides the controls and does nothing else. It used
  /// to clear both fields, which was right for a checkbox and wrong for a
  /// disclosure triangle — that reads as "hide the details", so reclaiming a
  /// little window space silently destroyed the trim.
  @Test func collapsingTheTrimSectionKeepsTheTimes() {
    let model = IntakeModel(
      fetchInfo: { _ in throw CancellationError() }, enqueue: { _, _ in },
      preferences: Self.store())
    model.linkText = Self.videoLink
    model.isTrimExpanded = true
    model.trimStartText = "00:10:00"
    model.trimEndText = "00:20:00"

    model.isTrimExpanded = false

    #expect(model.trimStartText == "00:10:00")
    #expect(model.trimEndText == "00:20:00")
  }

  /// And it keeps applying it. A set trim that quietly stops counting because
  /// a triangle is closed is hidden state; the collapsed row carries
  /// `trimSummary` precisely so there is none.
  @Test func aCollapsedTrimSectionStillTrims() {
    let model = IntakeModel(
      fetchInfo: { _ in throw CancellationError() }, enqueue: { _, _ in },
      preferences: Self.store())
    model.linkText = Self.videoLink
    model.trimStartText = "00:10:00"
    model.isTrimExpanded = false

    #expect(model.trimStart == .seconds(600))
    #expect(model.trimSummary == "from 00:10:00")
  }

  @Test func summarisesWhicheverEndsAreSet() {
    let model = IntakeModel(
      fetchInfo: { _ in throw CancellationError() }, enqueue: { _, _ in },
      preferences: Self.store())
    model.linkText = Self.videoLink
    #expect(model.trimSummary == nil)

    model.trimStartText = "00:10:00"
    model.trimEndText = "00:20:00"
    #expect(model.trimSummary == "00:10:00 – 00:20:00")

    model.trimStartText = ""
    #expect(model.trimSummary == "up to 00:20:00")

    // Nothing to summarise while the value cannot be read.
    model.trimEndText = "half an hour"
    #expect(model.trimSummary == nil)
  }

  /// A clip has no trim at all, so it has nothing to say about one either.
  @Test func aClipNeverSummarisesATrim() {
    let model = IntakeModel(
      fetchInfo: { _ in throw CancellationError() }, enqueue: { _, _ in },
      preferences: Self.store())
    model.linkText = Self.clipLink
    model.trimStartText = "00:10:00"
    #expect(model.trimSummary == nil)
  }

  /// `reset()` empties the window when it closes (#39), and that includes
  /// folding the section back up — a reopened window should look like a new
  /// one, not like the last job half-configured.
  @Test func resettingTheWindowFoldsTheTrimSectionAway() {
    let model = IntakeModel(
      fetchInfo: { _ in throw CancellationError() }, enqueue: { _, _ in },
      preferences: Self.store())
    model.linkText = Self.videoLink
    model.isTrimExpanded = true
    model.trimStartText = "00:10:00"

    model.reset()

    #expect(!model.isTrimExpanded)
    #expect(model.trimStartText.isEmpty)
  }

  /// A trim is scoped to the video it was drawn against more tightly than a
  /// quality is: `trimIsInvalid` checks the window against `info.duration`, so
  /// a trim carried over from a longer video does not get quietly ignored the
  /// way a stale quality selection would — it gets rejected, leaving the
  /// timeline dimmed and Add disabled over a video the trim was never drawn
  /// against. Pasting a new link has to clear it, not just the quality.
  @Test func loadingADifferentVideoClearsAnyTrimFromTheLastOne() async {
    let long = Self.info(duration: .seconds(2400))
    let short = Self.info(duration: .seconds(300))
    let model = IntakeModel(
      fetchInfo: { id in id == "1111" ? long : short },
      enqueue: { _, _ in },
      calendar: Self.pacific,
      preferences: Self.store())

    model.linkText = "https://www.twitch.tv/videos/1111"
    await model.load()
    model.trimStartText = "10:00"
    model.trimEndText = "20:00"

    model.linkText = "https://www.twitch.tv/videos/2222"
    await model.load()

    #expect(!model.isTrimExpanded)
    #expect(model.trimStartText.isEmpty)
    #expect(model.trimEndText.isEmpty)
  }

  /// A superseded fetch is not a failure. `.task(id:)` cancels the previous
  /// fetch on every edit to the link, and `generation` cannot hide it — the
  /// replacement has not necessarily incremented the counter by the time the
  /// cancelled one unwinds. Reporting it would flash "Oxbow could not read
  /// that video's details" at someone who is simply still typing.
  @Test func aCancelledFetchIsNotReportedAsAFailure() async {
    let model = makeModel(failure: CancellationError())
    model.linkText = Self.videoLink

    await model.load()

    #expect(model.metadataFailure == nil)
    #expect(!model.hasSettledMetadata, "a cancelled fetch settles nothing")
    #expect(model.isLoadingMetadata, "the replacement fetch is what settles this")
  }

  /// The positive control for the test above: a real failure still shows.
  @Test func aRealFetchFailureIsStillReported() async {
    let model = makeModel(failure: VideoInfoFetchError.unparseableOutput(snippet: "x"))
    model.linkText = Self.videoLink

    await model.load()

    #expect(model.metadataFailure != nil)
    #expect(model.hasSettledMetadata)
  }

  // MARK: - Metadata failure

  @Test func aMetadataFailureIsSurfacedAndTheSheetStaysUsable() async throws {
    let model = makeModel(
      failure: VideoInfoFetchError.helperFailed(
        status: .exited(1),
        standardError: "Unable to get information about VOD\n   at Foo.Bar()"))
    model.linkText = Self.videoLink
    await model.load()
    model.folder = Self.folder

    let failure = try #require(model.metadataFailure)
    #expect(failure.contains("Unable to get information about VOD"), "the helper's own sentence")
    #expect(!failure.contains("at Foo.Bar()"), "but not its stack trace")

    // The fallback: named from the id, and still addable as video-only.
    #expect(model.name == Self.videoID)
    model.output = .video
    #expect(model.canAdd)
    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.destination?.lastPathComponent == "2844548319.mp4")
    #expect(model.qualities.isEmpty)
    #expect(model.quality == "", "with no quality list, best available is the only honest choice")
  }

  /// The default output is the one metadata failure takes away: a composite
  /// has no rendition to size its chat column against and no duration to
  /// time its encode. Refusing it silently would grey Add out on a freshly
  /// opened sheet with nothing on screen saying why, so the refusal comes
  /// with the sentence and with the output that still works.
  @Test func aMetadataFailureExplainsWhyChatIsUnavailable() async throws {
    let model = makeModel(
      failure: VideoInfoFetchError.helperFailed(status: .exited(1), standardError: "nope"))
    model.linkText = Self.videoLink
    await model.load()
    model.folder = Self.folder

    #expect(model.output == .videoWithChat, "the default, and the one that cannot be built")
    #expect(!model.canAdd)
    let problem = try #require(model.chatProblem)
    #expect(problem.contains("\"Video\""), "names the output that still works")

    model.output = .video
    #expect(model.chatProblem == nil)
    #expect(model.canAdd)
  }

  @Test func aClipsMetadataFailureNamesFromTheSlug() async {
    let model = makeModel(failure: VideoInfoFetchError.unparseableOutput(snippet: "???"))
    model.linkText = Self.clipLink
    await model.load()

    #expect(model.metadataFailure != nil)
    #expect(model.name == Self.clipSlug)
  }

  @Test func aFailureWithNoStandardErrorStillExplainsItself() async throws {
    let model = makeModel(
      failure: VideoInfoFetchError.helperFailed(status: .exited(1), standardError: ""))
    model.linkText = Self.videoLink
    await model.load()

    let failure = try #require(model.metadataFailure)
    #expect(!failure.isEmpty)
  }

  /// A slow fetch for the link the user has already replaced must not land
  /// last and name the job after the wrong video.
  @Test func aSupersededFetchNeverOverwritesTheNewerOne() async {
    let gate = Gate()
    let stale = Self.info(streamer: "stale", title: "Old")
    let fresh = Self.info(streamer: "fresh", title: "New")
    let model = IntakeModel(
      fetchInfo: { id in
        if id == "1111" {
          await gate.wait()
          return stale
        }
        return fresh
      },
      enqueue: { _, _ in },
      calendar: Self.pacific,
      preferences: Self.store())

    model.linkText = "https://www.twitch.tv/videos/1111"
    let first = Task { await model.load() }
    await waitUntil("the first fetch is in flight") { model.isLoadingMetadata }

    model.linkText = "https://www.twitch.tv/videos/2222"
    await model.load()
    #expect(model.name == "fresh - 2026-08-23 - New")

    await gate.open()
    await first.value

    #expect(model.name == "fresh - 2026-08-23 - New", "the superseded fetch must not write back")
    #expect(model.info?.streamer == "fresh")
  }

  // MARK: - Add

  @Test func addEnqueuesExactlyOneJobTitledAfterItsOutputs() async {
    let recorder = Recorder()
    let model = await loadedModel(recorder: recorder)

    #expect(await model.add())

    #expect(recorder.templates.count == 1)
    #expect(recorder.templates.first?.title == "leighxp - 2026-08-23 - A Stream")
  }

  /// The hazard this path is shaped around: Add must never report success —
  /// which is what dismisses the sheet — without a job to show for it. A
  /// refusal enqueues nothing and says why.
  @Test func addRefusesAndExplainsRatherThanClosingOnNothing() async {
    let recorder = Recorder()
    let model = await loadedModel(recorder: recorder)
    model.folder = nil

    #expect(await model.add() == false)
    #expect(recorder.templates.isEmpty)
    #expect(model.addFailure != nil)
  }

  @Test func aSucceedingAddClearsAnEarlierRefusal() async {
    let recorder = Recorder()
    let model = await loadedModel(recorder: recorder)
    model.folder = nil
    _ = await model.add()
    #expect(model.addFailure != nil)

    model.folder = Self.folder
    #expect(await model.add())
    #expect(model.addFailure == nil)
  }

  // MARK: - Suffixes

  @Test func theReservedSuffixIsTheOnlyOneAnyOutputCanTake() {
    #expect(OutputSuffix.longestBytes == OutputSuffix.video.utf8.count)
    #expect(OutputSuffix.longestBytes == 4)
  }

  // MARK: - Helpers

  /// Lets a test hold a fetch open while it drives the model past it.
  private actor Gate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
      guard !isOpen else { return }
      await withCheckedContinuation { continuation = $0 }
    }

    func open() {
      isOpen = true
      continuation?.resume()
      continuation = nil
    }
  }

  /// Yields until `condition` holds, bounded so a broken implementation fails
  /// the test rather than hanging it.
  private func waitUntil(
    _ description: String,
    yields: Int = 10_000,
    _ condition: () -> Bool)
    async
  {
    for _ in 0..<yields {
      if condition() { return }
      await Task.yield()
    }
    Issue.record("timed out waiting until \(description)")
  }
}
