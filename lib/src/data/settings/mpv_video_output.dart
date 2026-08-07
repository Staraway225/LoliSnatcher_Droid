import 'dart:io';

import 'package:lolisnatcher/src/data/settings/settings_enum.dart';
import 'package:lolisnatcher/src/utils/extensions.dart';

enum MpvVideoOutput with SettingsEnum<MpvVideoOutput> {
  gpu,
  gpuNext,
  libmpv,
  mediacodecEmbed,
  sdl,
  ;

  // For JSON serialization - returns ORIGINAL string values for backwards compatibility
  // New format (uncomment after grace period): gpu => 'gpu', gpuNext => 'gpuNext', etc.
  @override
  String toJson() {
    switch (this) {
      case MpvVideoOutput.gpu:
        return 'gpu';
      case MpvVideoOutput.gpuNext:
        return 'gpu-next';
      case MpvVideoOutput.libmpv:
        return 'libmpv';
      case MpvVideoOutput.mediacodecEmbed:
        return 'mediacodec_embed';
      case MpvVideoOutput.sdl:
        return 'sdl';
    }
  }

  static MpvVideoOutput fromString(String name) {
    switch (name) {
      case 'gpu':
        return MpvVideoOutput.gpu;
      case 'gpu-next':
      case 'gpuNext':
        return MpvVideoOutput.gpuNext;
      case 'libmpv':
        return MpvVideoOutput.libmpv;
      case 'mediacodec_embed':
      case 'mediacodecEmbed':
        return MpvVideoOutput.mediacodecEmbed;
      case 'sdl':
        return MpvVideoOutput.sdl;
    }
    return defaultValue;
  }

  /// Android is the exception here, not desktop: it renders through a
  /// SurfaceTexture and wants `gpu`. Every other platform goes through
  /// media_kit's `NativeVideoController`, which renders via `mpv_render_context`
  /// into a Flutter texture and only works with the render-API output. Handing
  /// it `gpu` makes mpv drive its own GPU output instead, so no texture is ever
  /// produced - the video buffers but never appears.
  static MpvVideoOutput get defaultValue {
    return Platform.isAndroid ? MpvVideoOutput.gpu : MpvVideoOutput.libmpv;
  }

  /// Values that can actually work on the current platform.
  ///
  /// Mirrors `VideoBackendMode.allowedValues`. Without this the dropdown offers
  /// `mediacodec_embed` on iOS and `sdl` on Android, neither of which exists in
  /// those libmpv builds.
  static List<MpvVideoOutput> get allowedValues {
    if (Platform.isAndroid) {
      return [
        MpvVideoOutput.gpu,
        MpvVideoOutput.gpuNext,
        MpvVideoOutput.mediacodecEmbed,
        MpvVideoOutput.libmpv,
      ];
    }
    if (PlatformExt.isDesktop) {
      return [
        MpvVideoOutput.gpu,
        MpvVideoOutput.gpuNext,
        MpvVideoOutput.libmpv,
        MpvVideoOutput.sdl,
      ];
    }
    // iOS: the texture path is the only one that renders.
    return [MpvVideoOutput.libmpv];
  }

  /// Falls back to [defaultValue] when this value cannot work here.
  ///
  /// Persisted settings bypass the `options` list entirely - see
  /// `SettingsEnumRegistry.validate` in settings_enum.dart, which only calls
  /// [fromString] - so a value stored before this fix, or synced from another
  /// platform, would otherwise reach mpv verbatim.
  MpvVideoOutput get orPlatformDefault => allowedValues.contains(this) ? this : defaultValue;

  bool get isGpu => this == MpvVideoOutput.gpu;
  bool get isGpuNext => this == MpvVideoOutput.gpuNext;
  bool get isLibmpv => this == MpvVideoOutput.libmpv;
  bool get isMediacodecEmbed => this == MpvVideoOutput.mediacodecEmbed;
  bool get isSdl => this == MpvVideoOutput.sdl;

  @override
  String get locName {
    return toJson();
  }
}
