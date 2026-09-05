import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Watching model")
struct WatchingModelTests {

  private func temporaryStore() -> WatchStore {
    WatchStore(fileURL: URL.temporaryDirectory
      .appending(path: "watching-\(UUID().uuidString)")
      .appending(path: "watches.json"))
  }

  private func watch(_ login: String, seen: Set<String> = []) -> Watch {
    Watch(login: login, displayName: login.capitalized,
          settings: .init(destinationPath: "/Users/x/Downloads", qualityCap: .best,
                          output: .videoWithChat, chatSize: .medium),
          downloadsAutomatically: false, seen: seen)
  }

  private func archive(_ id: String) -> ChannelArchive {
    ChannelArchive(id: id, title: "Stream \(id)", duration: .seconds(3600),
                   publishedAt: Date(timeIntervalSince1970: 0), status: .recorded,
                   thumbnailURL: nil)
  }

  private func model(store: WatchStore) -> WatchingModel {
    WatchingModel(store: store, openIntake: { _, _ in })
  }

  // MARK: - Derivation

  @Test func sectionsMirrorTheSweep() {
    let model = model(store: temporaryStore())
    model.apply([
      .init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1"), archive("2")])),
      .init(login: "day9tv", displayName: "Day9tv", outcome: .found([archive("3")]))])

    #expect(model.sections.map(\.login) == ["ninja", "day9tv"])
    #expect(model.sections[0].archives.map(\.id) == ["1", "2"])
    #expect(model.unreadCount == 3)
  }

  @Test func aFailedChannelKeepsItsReasonAndIsNotCountedAsUnread() {
    // Section 7: a failure must read as a failure, never as an empty list.
    let model = model(store: temporaryStore())
    model.apply([.init(login: "gone", displayName: "Gone", outcome: .failed(.noSuchChannel))])

    #expect(model.sections[0].failure != nil)
    #expect(model.sections[0].archives.isEmpty)
    #expect(model.unreadCount == 0)
  }

  @Test func aChannelWithNothingNewIsNotShownAsAFailure() {
    let model = model(store: temporaryStore())
    model.apply([.init(login: "quiet", displayName: "Quiet", outcome: .found([]))])

    #expect(model.sections[0].failure == nil)
    #expect(model.sections[0].archives.isEmpty)
  }

  // MARK: - The dismissal overlay

  @Test func ignoringRemovesTheRowImmediately() throws {
    // `WatchPoller.results` is a snapshot taken against the seen-set as it
    // stood at sweep time, so persisting alone would leave the row on screen
    // until the next sweep — up to an hour of a button appearing to do
    // nothing. The overlay is what makes Ignore feel like it worked.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja",
                       outcome: .found([archive("1"), archive("2")]))])

    model.ignore(archive("1"), from: "ninja")

    #expect(model.sections[0].archives.map(\.id) == ["2"])
    #expect(model.unreadCount == 1)
  }

  @Test func ignoringPersistsToTheSeenSet() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.ignore(archive("1"), from: "ninja")

    #expect(try store.load()[0].seen == ["1"])
  }

  @Test func addingPersistsAndOpensIntake() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let opened = OpenedBox()
    let model = WatchingModel(store: store, openIntake: { archive, _ in opened.id = archive.id })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.add(archive("1"), from: "ninja")

    #expect(opened.id == "1")
    // Marked seen on Add, not on the eventual download: the watch's job is to
    // stop offering it, and a person who adds it and then cancels at intake
    // has still answered the question the row was asking.
    #expect(try store.load()[0].seen == ["1"])
    #expect(model.sections[0].archives.isEmpty)
  }

  /// The exact shape `OxbowApp` wires in production — its `openIntake`
  /// closure only ever builds a `PendingIntake` from the watch `add` hands it,
  /// never from `Preferences`. `addingPersistsAndOpensIntake` above only pins
  /// the archive id; this pins the other half of the hand-off, that a channel
  /// someone capped at 720p, video-only actually carries those settings to
  /// intake rather than whatever the global defaults happen to be.
  @Test func addHandsIntakeTheWatchsFrozenSettingsNotGlobalPreferences() throws {
    let store = temporaryStore()
    let capped = Watch(
      login: "ninja", displayName: "Ninja",
      settings: .init(
        destinationPath: "/Users/x/Archive", qualityCap: .p720,
        output: .video, chatSize: .large),
      downloadsAutomatically: false, seen: [])
    try store.save([capped])

    var pending: PendingIntake?
    let model = WatchingModel(store: store, openIntake: { archive, watch in
      pending = PendingIntake(archiveID: archive.id, settings: watch.settings)
    })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.add(archive("1"), from: "ninja")

    let handedOff = try #require(pending)
    #expect(handedOff.archiveID == "1")
    #expect(handedOff.settings == capped.settings)
  }

  @Test func anActionOnAnUnknownChannelIsIgnoredRatherThanCrashing() throws {
    // The watch file can change under us — a later stage will let someone
    // remove a channel while findings from it are still on screen.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "removed", displayName: "Removed",
                       outcome: .found([archive("1")]))])

    model.ignore(archive("1"), from: "removed")

    #expect(try store.load().map(\.login) == ["ninja"])
  }

  @Test func aSweepThatStraddlesADismissalDoesNotBringTheRowBack() throws {
    // `sweep` reads the seen-set once up front, then makes slow sequential
    // per-channel calls. A sweep that was already in flight when the ignore
    // landed finishes with results computed before that write — still
    // containing the just-dismissed archive. An identical payload reapplied
    // is exactly that case, and the row must stay gone rather than reappear.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.ignore(archive("1"), from: "ninja")

    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    #expect(model.sections[0].archives.isEmpty)
  }

  @Test func aDismissalDropsOutOfTheOverlayOnceTheArchiveStopsAppearing() throws {
    // A sweep computed after the write no longer carries the dismissed id at
    // all, so it can drop out of the overlay safely — the set stays bounded
    // instead of growing forever, and a genuinely new archive that reuses the
    // id later is not hidden permanently by a stale dismissal.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.ignore(archive("1"), from: "ninja")

    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([]))])
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    #expect(model.sections[0].archives.map(\.id) == ["1"])
  }
}

/// A reference box so an escaping closure's effect is observable from a test.
@MainActor private final class OpenedBox {
  var id: String?
}
