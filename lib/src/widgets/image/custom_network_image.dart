// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';

import 'package:lolisnatcher/src/services/image_writer.dart';
import 'package:lolisnatcher/src/utils/dio_network.dart';
import 'package:lolisnatcher/src/utils/perf_tracer.dart';
import 'package:lolisnatcher/src/utils/request_limiter.dart';
import 'package:lolisnatcher/src/utils/tools.dart';
import 'package:lolisnatcher/src/widgets/image/abstract_custom_network_image.dart' as custom_network_image;

/// Shared logic for downloading, caching, and atomic writing of images.
class NetworkImageLoader {
  static const Duration _defaultReceiveTimeout = Duration(seconds: 30);

  static Future<void> _commitCacheFile(File tempFile, String destPath) async {
    final dest = File(destPath);
    try {
      await tempFile.rename(destPath);
      return;
    } catch (_) {}

    if (await dest.exists()) {
      try {
        final len = await dest.length();
        if (len > 0) {
          try {
            await tempFile.delete();
          } catch (_) {}
          return;
        }
        await dest.delete();
      } catch (e) {
        try {
          await tempFile.delete();
        } catch (_) {}
        return;
      }
    }
    for (int i = 0; i < 3; i++) {
      try {
        await tempFile.rename(destPath);
        return;
      } catch (_) {
        await Future.delayed(Duration(milliseconds: 50 * (i + 1)));
      }
    }

    if (await dest.exists()) {
      try {
        await tempFile.delete();
      } catch (_) {}
      return;
    }

    throw FileSystemException('Failed to commit cache file after retries', destPath);
  }

  static Future<Uint8List> downloadAndCache({
    required String url,
    required String? cacheFolder,
    required String fileNameExtras,
    required bool withCache,
    required Map<String, String>? headers,
    required Duration? sendTimeout,
    required Duration? receiveTimeout,
    required CancelToken? cancelToken,
    required bool withCaptchaCheck,
    required StreamController<ImageChunkEvent>? chunkEvents,
    required void Function(bool)? onCacheDetected,
    void Function(int, int?)? onReceiveProgress,
  }) async {
    final Stopwatch perfWatch = Stopwatch()..start();
    final Uri resolved = Uri.base.resolve(url);
    final String cacheFilePath = await ImageWriter().getCachePathString(
      resolved.toString(),
      cacheFolder ?? 'media',
      clearName: cacheFolder != 'favicons',
      fileNameExtras: fileNameExtras,
    );

    final String tempFilePath = '$cacheFilePath.temp_${DateTime.now().microsecondsSinceEpoch}';

    File? cacheFile;

    // Check existing cache
    if (withCache) {
      cacheFile = File(cacheFilePath);
      if (await cacheFile.exists()) {
        final int fileSize = await cacheFile.length();
        if (fileSize < 10) {
          try {
            await cacheFile.delete();
          } catch (_) {}
          cacheFile = null;
        } else {
          chunkEvents?.add(
            ImageChunkEvent(
              cumulativeBytesLoaded: fileSize,
              expectedTotalBytes: fileSize,
            ),
          );
          onReceiveProgress?.call(fileSize, fileSize);
        }
      } else {
        cacheFile = null;
      }
    }

    if (onCacheDetected != null) {
      onCacheDetected(cacheFile != null);
    }

    if (cacheFile != null) {
      try {
        final Uint8List cached = await cacheFile.readAsBytes();
        PerfTracer.recordDownload(
          bytes: cached.length,
          millis: perfWatch.elapsedMilliseconds,
          fromCache: true,
        );
        return cached;
      } catch (e) {
        cacheFile = null;
      }
    }

    // --- Download Logic ---
    // Everything above this point is a cache lookup and must NOT hold a permit;
    // only the actual network fetch is rate limited.
    final Duration? hostPause = RequestLimiter.pauseRemaining(resolved.host);
    if (hostPause != null) {
      // This host just rate limited us. Backing off here stops ~30 tiles from
      // hammering it in lockstep.
      await Future<void>.delayed(hostPause);
    }

    // The captcha interceptor mutates the client, so that path keeps a private
    // instance. Everything else shares a pooled client, which is what lets
    // consecutive thumbnails reuse a connection instead of paying a fresh
    // TCP + TLS handshake each.
    final bool skipLogging = !SettingsHandler.instance.useImageLogging.value;
    final Dio client = withCaptchaCheck
        ? DioNetwork.getClient(skipLogging: skipLogging)
        : DioNetwork.getSharedClient(skipLogging: skipLogging);
    if (withCaptchaCheck) {
      DioNetwork.captchaInterceptor(
        client,
        customUserAgent: Tools.appUserAgent,
      );
    }

    Response? response;
    // Dio applies receiveTimeout between response chunks. Without a default,
    // a server that sends an initial buffer and then stalls stays pending forever
    final effectiveReceiveTimeout = receiveTimeout ?? _defaultReceiveTimeout;
    try {
      response = await RequestLimiter.withPermit<Response<dynamic>>(
        () async => withCache
            ? await client.downloadUri(
                resolved,
                tempFilePath,
                options: Options(
                  headers: headers,
                  sendTimeout: sendTimeout,
                  receiveTimeout: effectiveReceiveTimeout,
                  followRedirects: headers?.containsKey('LS-IGNORE-REDIRECT') == true ? false : true,
                ),
                onReceiveProgress: (int count, int total) {
                  chunkEvents?.add(
                    ImageChunkEvent(
                      cumulativeBytesLoaded: count,
                      expectedTotalBytes: total <= 0 ? null : total,
                    ),
                  );
                  onReceiveProgress?.call(count, total <= 0 ? null : total);
                },
                cancelToken: cancelToken,
              )
            : await client.getUri(
                resolved,
                options: Options(
                  headers: headers,
                  responseType: ResponseType.bytes,
                  sendTimeout: sendTimeout,
                  receiveTimeout: effectiveReceiveTimeout,
                  followRedirects: headers?.containsKey('LS-IGNORE-REDIRECT') == true ? false : true,
                ),
                onReceiveProgress: (int count, int total) {
                  chunkEvents?.add(
                    ImageChunkEvent(
                      cumulativeBytesLoaded: count,
                      expectedTotalBytes: total <= 0 ? null : total,
                    ),
                  );
                  onReceiveProgress?.call(count, total <= 0 ? null : total);
                },
                cancelToken: cancelToken,
              ),
      );
    } on DioException catch (e) {
      try {
        await File(tempFilePath).delete();
      } catch (_) {}
      if (RequestLimiter.isRateLimitStatus(e.response?.statusCode)) {
        RequestLimiter.reportRateLimited(resolved.host);
      }
      rethrow;
    } catch (e) {
      try {
        await File(tempFilePath).delete();
      } catch (_) {}
      rethrow;
    } finally {
      // Never close the pooled client -- other thumbnails are using it.
      if (withCaptchaCheck) {
        client.close();
      }
    }

    if (!Tools.isGoodResponse(response)) {
      try {
        await File(tempFilePath).delete();
      } catch (_) {}

      throw NetworkImageLoadException(
        statusCode: response.statusCode ?? 0,
        uri: resolved,
      );
    }

    if (withCache) {
      final tempFile = File(tempFilePath);
      if (await tempFile.exists()) {
        final actualLen = await tempFile.length();

        // Validate Content-Length
        final headerLen = int.tryParse(response.headers.value(HttpHeaders.contentLengthHeader) ?? '');
        if (headerLen != null && headerLen > 0 && actualLen != headerLen) {
          try {
            await tempFile.delete();
          } catch (_) {}
          throw Exception('Download incomplete: Expected $headerLen bytes, got $actualLen');
        }

        try {
          await _commitCacheFile(tempFile, cacheFilePath);
          final Uint8List committed = await File(cacheFilePath).readAsBytes();
          PerfTracer.recordDownload(
            bytes: committed.length,
            millis: perfWatch.elapsedMilliseconds,
            fromCache: false,
          );
          return committed;
        } catch (_) {
          try {
            await tempFile.delete();
          } catch (_) {}
          rethrow;
        }
      }
    }

    return response.data as Uint8List;
  }

  static Future<Uint8List> tryFixGifSpeed(
    String url,
    Uint8List image,
  ) async {
    // Sniff the GIF signature rather than the URL. The old check was
    // `!endsWith('.gif') && !contains('.gif')`, where the `contains` made the
    // `endsWith` dead and matched any URL merely mentioning .gif -- so this
    // whole-buffer scan ran on the UI isolate for non-GIFs too.
    if (image.length < 6 ||
        image[0] != 0x47 || // G
        image[1] != 0x49 || // I
        image[2] != 0x46 || // F
        image[3] != 0x38) {
      // 8
      return image;
    }

    try {
      // Graphic Control Extension blocks that matter live near the start; a
      // multi-MB GIF does not need a full byte-by-byte walk on the UI thread.
      const int scanLimit = 64 * 1024;
      final int len = min(image.length, scanLimit) - 6;
      for (int i = 0; i < len; i++) {
        if (image[i] == 0x21 && image[i + 1] == 0xF9 && image[i + 2] == 0x04) {
          final int delay = image[i + 4] | (image[i + 5] << 8);
          if (delay < 10) {
            image[i + 4] = 0x0A;
          }
          i += 5;
        }
      }
    } catch (_) {}
    return image;
  }

  static Future<void> deleteCache(
    String url,
    String? cacheFolder,
    String fileNameExtras,
  ) async {
    final Uri resolved = Uri.base.resolve(url);
    final String cacheFilePath = await ImageWriter().getCachePathString(
      resolved.toString(),
      cacheFolder ?? 'media',
      clearName: cacheFolder != 'favicons',
      fileNameExtras: fileNameExtras,
    );
    final File cacheFile = File(cacheFilePath);
    try {
      if (await cacheFile.exists()) {
        await cacheFile.delete();
      }
      // Note: We can't easily delete unique temp files here as their names are random.
      // But they are cleaned up in the try/catch blocks of downloadAndCache.
      // We can try deleting the legacy fixed temp file just in case.
      final legacyTemp = File('$cacheFilePath.temp');
      if (await legacyTemp.exists()) {
        await legacyTemp.delete();
      }
    } catch (e) {
      print('NetworkImage Exception :: delete cache file :: $e');
    }
  }
}

/// Value equality for the request headers.
///
/// [CustomNetworkImage.obtainKey] returns `this`, so the provider *is* the key
/// Flutter's `imageCache` hashes and compares. `headers` is a `Map`, which in
/// Dart compares by identity, and `Tools.getFileCustomHeaders` allocates a fresh
/// map on every call -- so two providers for the same URL were never equal and
/// the memory cache could never produce a hit. Every rebuilt tile paid a full
/// disk read plus a re-decode, and two tiles showing the same URL each ran their
/// own download because `_pendingImages` could not dedupe them either.
const MapEquality<String, String> _headersEquality = MapEquality<String, String>();

bool _headersEqual(Map<String, String>? a, Map<String, String>? b) {
  if (identical(a, b)) {
    return true;
  }
  if (a == null || b == null) {
    return false;
  }
  return _headersEquality.equals(a, b);
}

/// Order-independent hash of the header map, so equal maps hash equal.
int _headersHash(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) {
    return 0;
  }
  return _headersEquality.hash(headers);
}

@immutable
class CustomNetworkImage extends ImageProvider<custom_network_image.CustomNetworkImage>
    implements custom_network_image.CustomNetworkImage {
  const CustomNetworkImage(
    this.url, {
    this.scale = 1.0,
    this.headers,
    this.cancelToken,
    this.withCache = false,
    this.cacheFolder,
    this.fileNameExtras = '',
    this.onCacheDetected,
    this.onError,
    this.sendTimeout,
    this.receiveTimeout,
    this.withCaptchaCheck = false,
  }) : assert(!withCache || cacheFolder != null, 'cacheFolder must be set when withCache is true');

  @override
  final String url;
  @override
  final double scale;
  @override
  final Map<String, String>? headers;
  final CancelToken? cancelToken;
  final bool withCache;
  final String? cacheFolder;
  final String fileNameExtras;
  final void Function(bool)? onCacheDetected;
  final void Function(Object)? onError;
  final Duration? sendTimeout;
  final Duration? receiveTimeout;
  final bool withCaptchaCheck;

  @override
  Future<CustomNetworkImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<CustomNetworkImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    custom_network_image.CustomNetworkImage key,
    ImageDecoderCallback decode,
  ) {
    final StreamController<ImageChunkEvent> chunkEvents = StreamController<ImageChunkEvent>();

    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key as CustomNetworkImage, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<custom_network_image.CustomNetworkImage>('Image key', key),
      ],
    );
  }

  Future<bool> deleteCacheFile() async {
    await NetworkImageLoader.deleteCache(url, cacheFolder, fileNameExtras);
    return true;
  }

  Future<ui.Codec> _loadAsync(
    CustomNetworkImage key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      assert(key == this, 'The $runtimeType cannot be reused after disposing.');

      final Uint8List bytes = await NetworkImageLoader.downloadAndCache(
        url: key.url,
        cacheFolder: cacheFolder,
        fileNameExtras: fileNameExtras,
        withCache: withCache,
        headers: headers,
        sendTimeout: sendTimeout,
        receiveTimeout: receiveTimeout,
        cancelToken: cancelToken,
        withCaptchaCheck: withCaptchaCheck,
        chunkEvents: chunkEvents,
        onCacheDetected: onCacheDetected,
      );

      if (bytes.isEmpty) {
        await deleteCacheFile();
        throw Exception('CustomNetworkImage is an empty file: ${key.url}');
      }

      final fixedBytes = await NetworkImageLoader.tryFixGifSpeed(key.url, bytes);

      final Stopwatch decodeWatch = Stopwatch()..start();
      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(fixedBytes);
      final ui.Codec codec = await decode(buffer);
      PerfTracer.recordDecode(decodeWatch.elapsedMilliseconds);
      return codec;
    } catch (e) {
      if (onError != null) {
        onError?.call(e);
      }
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      await chunkEvents.close();
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is CustomNetworkImage &&
        other.url == url &&
        other.scale == scale &&
        _headersEqual(other.headers, headers) &&
        other.withCache == withCache &&
        other.cacheFolder == cacheFolder &&
        other.fileNameExtras == fileNameExtras &&
        other.sendTimeout == sendTimeout &&
        other.receiveTimeout == receiveTimeout &&
        other.withCaptchaCheck == withCaptchaCheck;
  }

  @override
  int get hashCode => Object.hash(
    url,
    scale,
    _headersHash(headers),
    withCache,
    cacheFolder,
    fileNameExtras,
    sendTimeout,
    receiveTimeout,
    withCaptchaCheck,
  );

  @override
  String toString() => '${objectRuntimeType(this, 'CustomNetworkImage')}("$url", scale: $scale)';
}

@immutable
class CustomNetworkAvifImage extends ImageProvider<custom_network_image.CustomNetworkImage>
    implements custom_network_image.CustomNetworkImage {
  const CustomNetworkAvifImage(
    this.url, {
    this.scale = 1.0,
    this.headers,
    this.cancelToken,
    this.withCache = false,
    this.cacheFolder,
    this.fileNameExtras = '',
    this.onCacheDetected,
    this.onError,
    this.sendTimeout,
    this.receiveTimeout,
    this.withCaptchaCheck = false,
  }) : assert(!withCache || cacheFolder != null, 'cacheFolder must be set when withCache is true');

  @override
  final String url;
  @override
  final double scale;
  @override
  final Map<String, String>? headers;
  final CancelToken? cancelToken;
  final bool withCache;
  final String? cacheFolder;
  final String fileNameExtras;
  final void Function(bool)? onCacheDetected;
  final void Function(Object)? onError;
  final Duration? sendTimeout;
  final Duration? receiveTimeout;
  final bool withCaptchaCheck;

  @override
  Future<CustomNetworkAvifImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<CustomNetworkAvifImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    custom_network_image.CustomNetworkImage key,
    ImageDecoderCallback decode,
  ) {
    final StreamController<ImageChunkEvent> chunkEvents = StreamController<ImageChunkEvent>();

    return AvifImageStreamCompleter(
      key: key,
      codec: _loadAsync(key as CustomNetworkAvifImage, chunkEvents, decode),
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        ErrorDescription('Url: $url'),
      ],
      chunkEvents: chunkEvents.stream,
    );
  }

  Future<bool> deleteCacheFile() async {
    await NetworkImageLoader.deleteCache(url, cacheFolder, fileNameExtras);
    return true;
  }

  Future<AvifCodec> _loadAsync(
    CustomNetworkAvifImage key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      assert(key == this, 'The $runtimeType cannot be reused after disposing.');

      final Uint8List bytes = await NetworkImageLoader.downloadAndCache(
        url: key.url,
        cacheFolder: cacheFolder,
        fileNameExtras: fileNameExtras,
        withCache: withCache,
        headers: headers,
        sendTimeout: sendTimeout,
        receiveTimeout: receiveTimeout,
        cancelToken: cancelToken,
        withCaptchaCheck: withCaptchaCheck,
        chunkEvents: chunkEvents,
        onCacheDetected: onCacheDetected,
      );

      if (bytes.isEmpty) {
        await deleteCacheFile();
        throw Exception('CustomNetworkAvifImage is an empty file: ${key.url}');
      }

      final fType = isAvifFile(bytes.sublist(0, 16));
      if (fType == AvifFileType.unknown) {
        throw Exception('CustomNetworkAvifImage is not an avif file: ${key.url}');
      }

      final codec = fType == AvifFileType.avif
          ? SingleFrameAvifCodec(bytes: bytes)
          : MultiFrameAvifCodec(
              key: hashCode,
              avifBytes: bytes,
              overrideDurationMs: -1,
            );
      await codec.ready();
      return codec;
    } catch (e) {
      if (onError != null) {
        onError?.call(e);
      }
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      await chunkEvents.close();
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is CustomNetworkAvifImage &&
        other.url == url &&
        other.scale == scale &&
        _headersEqual(other.headers, headers) &&
        other.withCache == withCache &&
        other.cacheFolder == cacheFolder &&
        other.fileNameExtras == fileNameExtras &&
        other.sendTimeout == sendTimeout &&
        other.receiveTimeout == receiveTimeout &&
        other.withCaptchaCheck == withCaptchaCheck;
  }

  @override
  int get hashCode => Object.hash(
    url,
    scale,
    _headersHash(headers),
    withCache,
    cacheFolder,
    fileNameExtras,
    sendTimeout,
    receiveTimeout,
    withCaptchaCheck,
  );

  @override
  String toString() => '${objectRuntimeType(this, 'CustomNetworkAvifImage')}("$url", scale: $scale)';
}
