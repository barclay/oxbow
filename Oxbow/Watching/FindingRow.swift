import SwiftUI
import OxbowKit

/// One archive a watch found: what it is, where it came from, how long ago it
/// was published, and the two things a person can do about it.
///
/// **The age comes from `RelativeDay`, never a countdown.** There is no
/// `expiresAt` on a Twitch video and retention runs anywhere from six weeks to
/// nine months with nothing predicting which (`docs/design/channel-watching.md`
/// §7) — a countdown here would be a number this row invented. "Published 12
/// days ago" is the only honest answer, so the row asks `RelativeDay` for it
/// rather than touching `publishedAt` itself.
///
/// **Title and metadata are two lines on purpose, and only one of them may
/// give ground.** A title is free text and can run to a full sentence; the
/// line beneath it — channel, duration, age — is short and is the thing a
/// person is actually triaging by. Giving the metadata line the higher layout
/// priority means the title is what SwiftUI shrinks first: a long title
/// truncates, and the channel name it sits above never does.
struct FindingRow: View {
  let archive: ChannelArchive
  let channelName: String
  /// Add's Finder-reveal precedent has no equivalent here — this is a value,
  /// not a filesystem lookup — but the same reasoning that made
  /// `RelativeDay.phrase` take `now` applies: a preview should be able to fix
  /// the clock instead of depending on the moment it happens to render.
  let now: Date
  let onAdd: () -> Void
  let onIgnore: () -> Void

  init(
    archive: ChannelArchive,
    channelName: String,
    now: Date = .now,
    onAdd: @escaping () -> Void,
    onIgnore: @escaping () -> Void)
  {
    self.archive = archive
    self.channelName = channelName
    self.now = now
    self.onAdd = onAdd
    self.onIgnore = onIgnore
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(archive.title)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(archive.title)

        HStack(spacing: 6) {
          Text(channelName)
          Text("·")
          Text(archive.duration.formatted(.time(pattern: .hourMinute)))
          Text("·")
          Text(RelativeDay.phrase(for: archive.publishedAt, now: now))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        // Higher than the title's default 0: when the row is squeezed, this
        // is the line that must come through whole. See the type doc above.
        .layoutPriority(1)
      }

      Spacer(minLength: 8)

      HStack(spacing: 8) {
        // Not destructive in the alert-worthy sense — it only stops this row
        // being offered again, not anything already downloaded — so unlike
        // `QueueView`'s removal it takes no confirmation.
        Button("Ignore", action: onIgnore)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Stop offering this video. It will not appear again.")

        // The prominent one: this is the row's whole reason to exist, and
        // Ignore is the exception a person reaches for less often.
        Button("Add", action: onAdd)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .help("Open Add Download with this video filled in.")
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

#Preview("Finding") {
  List {
    FindingRow(
      archive: FindingRowPreviewData.normal,
      channelName: "LeighXP",
      now: FindingRowPreviewData.now,
      onAdd: {}, onIgnore: {})
  }
  .frame(width: 480, height: 100)
}

#Preview("Long title") {
  List {
    FindingRow(
      archive: FindingRowPreviewData.longTitle,
      channelName: "A Channel With A Genuinely Long Display Name",
      now: FindingRowPreviewData.now,
      onAdd: {}, onIgnore: {})
  }
  .frame(width: 480, height: 100)
}

/// Fixtures for the previews above.
///
/// Not `WatchingView`'s: that view defines its own `WatchingViewPreviewData`
/// and explains at length why it must — see the comment there.
private enum FindingRowPreviewData {
  static let now = Date(timeIntervalSince1970: 1_754_000_000)

  static let normal = ChannelArchive(
    id: "1", title: "Indie horror night",
    duration: .seconds(3 * 3600 + 24 * 60),
    publishedAt: now.addingTimeInterval(-12 * 86400),
    status: .recorded, thumbnailURL: nil)

  static let longTitle = ChannelArchive(
    id: "2",
    title: "LeighXP - 2026-08-12 - indie horror + something else later?? "
      + "also chatting about the new patch notes and taking questions",
    duration: .seconds(5 * 3600),
    publishedAt: now,
    status: .recorded, thumbnailURL: nil)
}
