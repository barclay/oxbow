import OxbowKit

/// A Watching finding's identity and its channel's frozen settings, carried
/// from the Add button on a `FindingRow` to the intake window it opens.
///
/// **`settings` is a `Watch.Settings`, never a live read of `Preferences`.**
/// `Watch`'s own settings are frozen at the moment a channel is added
/// (see that type's doc comment) precisely so a channel someone capped at
/// 720p, video-only keeps downloading that way indefinitely — clicking Add
/// on one of its findings has to honour that freeze, not whatever the
/// standing global defaults happen to be by the time the click lands.
struct PendingIntake: Equatable {
  /// The archive's own id. `TwitchLink.parse` accepts a bare numeric video
  /// id, so this is usable as `IntakeModel.linkText` directly — there is no
  /// URL to reconstruct.
  var archiveID: String
  var settings: Watch.Settings
}
