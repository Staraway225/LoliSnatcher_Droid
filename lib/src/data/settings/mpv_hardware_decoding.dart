import 'dart:io';

import 'package:lolisnatcher/src/data/settings/settings_enum.dart';
import 'package:lolisnatcher/src/utils/extensions.dart';

enum MpvHardwareDecoding with SettingsEnum<MpvHardwareDecoding> {
  auto,
  autoSafe,
  autoCopy,
  mediacodec,
  mediacodecCopy,
  vulkan,
  vulkanCopy,
  videotoolbox,
  videotoolboxCopy,
  ;

  // For JSON serialization - returns ORIGINAL string values for backwards compatibility
  // New format (uncomment after grace period): auto => 'auto', autoSafe => 'autoSafe', etc.
  @override
  String toJson() {
    switch (this) {
      case MpvHardwareDecoding.auto:
        return 'auto';
      case MpvHardwareDecoding.autoSafe:
        return 'auto-safe';
      case MpvHardwareDecoding.autoCopy:
        return 'auto-copy';
      case MpvHardwareDecoding.mediacodec:
        return 'mediacodec';
      case MpvHardwareDecoding.mediacodecCopy:
        return 'mediacodec-copy';
      case MpvHardwareDecoding.vulkan:
        return 'vulkan';
      case MpvHardwareDecoding.vulkanCopy:
        return 'vulkan-copy';
      case MpvHardwareDecoding.videotoolbox:
        return 'videotoolbox';
      case MpvHardwareDecoding.videotoolboxCopy:
        return 'videotoolbox-copy';
    }
  }

  static MpvHardwareDecoding fromString(String name) {
    switch (name) {
      case 'auto':
        return MpvHardwareDecoding.auto;
      case 'auto-safe':
      case 'autoSafe':
        return MpvHardwareDecoding.autoSafe;
      case 'auto-copy':
      case 'autoCopy':
        return MpvHardwareDecoding.autoCopy;
      case 'mediacodec':
        return MpvHardwareDecoding.mediacodec;
      case 'mediacodec-copy':
      case 'mediacodecCopy':
        return MpvHardwareDecoding.mediacodecCopy;
      case 'vulkan':
        return MpvHardwareDecoding.vulkan;
      case 'vulkan-copy':
      case 'vulkanCopy':
        return MpvHardwareDecoding.vulkanCopy;
      case 'videotoolbox':
        return MpvHardwareDecoding.videotoolbox;
      case 'videotoolbox-copy':
      case 'videotoolboxCopy':
        return MpvHardwareDecoding.videotoolboxCopy;
    }
    return defaultValue;
  }

  static MpvHardwareDecoding get defaultValue {
    return PlatformExt.isDesktop ? MpvHardwareDecoding.auto : MpvHardwareDecoding.autoSafe;
  }

  /// Values that can actually work on the current platform.
  ///
  /// `auto*` are generic and resolve per platform; the rest name a specific API
  /// that only exists on one of them. Unlike a bad video output, mpv falls back
  /// silently on an unsupported hwdec, so these mostly cost performance rather
  /// than breaking playback - but offering them is still misleading.
  static List<MpvHardwareDecoding> get allowedValues {
    const generic = [
      MpvHardwareDecoding.auto,
      MpvHardwareDecoding.autoSafe,
      MpvHardwareDecoding.autoCopy,
    ];
    if (Platform.isAndroid) {
      return [...generic, MpvHardwareDecoding.mediacodec, MpvHardwareDecoding.mediacodecCopy];
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return [...generic, MpvHardwareDecoding.videotoolbox, MpvHardwareDecoding.videotoolboxCopy];
    }
    return [...generic, MpvHardwareDecoding.vulkan, MpvHardwareDecoding.vulkanCopy];
  }

  /// Falls back to [defaultValue] when this value cannot work here - see the
  /// note on `MpvVideoOutput.orPlatformDefault` for why persisted values need
  /// coercing.
  MpvHardwareDecoding get orPlatformDefault => allowedValues.contains(this) ? this : defaultValue;

  bool get isAuto => this == MpvHardwareDecoding.auto;
  bool get isAutoSafe => this == MpvHardwareDecoding.autoSafe;
  bool get isAutoCopy => this == MpvHardwareDecoding.autoCopy;
  bool get isMediacodec => this == MpvHardwareDecoding.mediacodec;
  bool get isMediacodecCopy => this == MpvHardwareDecoding.mediacodecCopy;
  bool get isVulkan => this == MpvHardwareDecoding.vulkan;
  bool get isVulkanCopy => this == MpvHardwareDecoding.vulkanCopy;
  bool get isVideotoolbox => this == MpvHardwareDecoding.videotoolbox;
  bool get isVideotoolboxCopy => this == MpvHardwareDecoding.videotoolboxCopy;

  @override
  String get locName {
    return toJson();
  }
}
