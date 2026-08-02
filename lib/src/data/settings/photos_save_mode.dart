import 'package:lolisnatcher/gen/strings.g.dart';
import 'package:lolisnatcher/src/data/settings/settings_enum.dart';

/// Controls whether snatched media is added to the iOS Photos library.
///
/// iOS keeps the Photos library in a separate store from the app sandbox, so
/// adding an asset copies the file rather than referencing it. This setting
/// decides whether to pay for that copy, skip Photos entirely, or hand the file
/// over and keep only the Photos copy.
///
/// Android has no use for this - the media scanner indexes saved files where
/// they already sit, so they appear in the gallery without duplication.
enum PhotosSaveMode with SettingsEnum<PhotosSaveMode> {
  /// Leave the Photos library alone. Saved files are reachable through the
  /// Files app only.
  disabled,

  /// Add to Photos and keep the file in the app folder. Uses roughly twice the
  /// storage, but the app can still see its own files.
  copy,

  /// Add to Photos and let it consume the original, so only one copy exists.
  /// The file then disappears from the app folder, which means duplicate
  /// detection has to fall back on the database.
  move,
  ;

  @override
  String toJson() {
    switch (this) {
      case PhotosSaveMode.disabled:
        return 'disabled';
      case PhotosSaveMode.copy:
        return 'copy';
      case PhotosSaveMode.move:
        return 'move';
    }
  }

  static PhotosSaveMode fromString(String name) {
    switch (name) {
      case 'disabled':
        return PhotosSaveMode.disabled;
      case 'copy':
        return PhotosSaveMode.copy;
      case 'move':
        return PhotosSaveMode.move;
    }
    return defaultValue;
  }

  static PhotosSaveMode get defaultValue => PhotosSaveMode.copy;

  bool get isDisabled => this == PhotosSaveMode.disabled;
  bool get isCopy => this == PhotosSaveMode.copy;
  bool get isMove => this == PhotosSaveMode.move;

  /// True when the file should be added to Photos at all.
  bool get isEnabled => !isDisabled;

  @override
  String get locName {
    switch (this) {
      case PhotosSaveMode.disabled:
        return loc.settings.cache.photosSaveModeValues.disabled;
      case PhotosSaveMode.copy:
        return loc.settings.cache.photosSaveModeValues.copy;
      case PhotosSaveMode.move:
        return loc.settings.cache.photosSaveModeValues.move;
    }
  }
}
