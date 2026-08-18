import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:dio/dio.dart';

import 'package:lolisnatcher/src/boorus/booru_type.dart';
import 'package:lolisnatcher/src/boorus/idol_sankaku_handler.dart';
import 'package:lolisnatcher/src/boorus/sankaku_handler.dart';
import 'package:lolisnatcher/src/data/booru.dart';
import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/handlers/booru_handler_factory.dart';
import 'package:lolisnatcher/src/handlers/database_handler.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/utils/debouncer.dart';
import 'package:lolisnatcher/src/utils/extensions.dart';
import 'package:lolisnatcher/src/utils/logger.dart';
import 'package:lolisnatcher/src/utils/request_limiter.dart';
import 'package:lolisnatcher/src/utils/tools.dart';
import 'package:lolisnatcher/src/widgets/common/thumbnail_loading.dart';
import 'package:lolisnatcher/src/widgets/image/custom_network_image.dart';
import 'package:lolisnatcher/src/widgets/preview/shimmer_builder.dart';

class Thumbnail extends StatefulWidget {
  const Thumbnail({
    required this.item,
    this.booru,
    this.isStandalone = false,
    this.useHero = true,
    super.key,
  });

  final BooruItem item;
  final Booru? booru;

  /// set to true when used in a list
  final bool isStandalone;
  final bool useHero;

  @override
  State<Thumbnail> createState() => _ThumbnailState();
}

/// Whether a thumbnail should load the small preview rather than the sample.
///
/// Extracted so the "no separate sample exists" rule can be tested directly.
/// When a post has no sample, `sampleURL` **is** the full original, so asking
/// for sample quality means downloading and decoding the entire file for a
/// ~130px grid cell. That guard used to be qualified with `!isStandalone`,
/// which applied it only in the viewer -- where the full image is being loaded
/// anyway -- and skipped it in the grid, where it matters most. Measured
/// against rule34.xxx: 25% of posts have no sample, and one page of 20 grid
/// tiles pulled 20.28 MB instead of 0.20 MB, including a 15.6 MB animated GIF.
bool shouldUseThumbnailQuality({
  required bool previewModeIsThumbnail,
  required MediaType mediaType,
  required String fileURL,
  required String sampleURL,
}) {
  if (previewModeIsThumbnail) {
    return true;
  }
  if (mediaType.isVideo || mediaType.isNeedToGuess || mediaType.isNeedToLoadItem) {
    return true;
  }
  return fileURL == sampleURL;
}

/// Placeholder for a disabled ImageFiltered, which still requires a filter.
final ImageFilter _noBlur = ImageFilter.blur();

class _ThumbnailState extends State<Thumbnail> {
  final SettingsHandler settingsHandler = SettingsHandler.instance;

  final ValueNotifier<int> total = ValueNotifier(0), received = ValueNotifier(0), startedAt = ValueNotifier(0);
  int restartedCount = 0;
  final ValueNotifier<bool?> isFromCache = ValueNotifier(null);
  final ValueNotifier<bool> isFirstBuild = ValueNotifier(true);
  final ValueNotifier<bool> isFailed = ValueNotifier(false);
  final ValueNotifier<bool> isLoaded = ValueNotifier(false);
  final ValueNotifier<bool> isLoadedExtra = ValueNotifier(false);
  final ValueNotifier<bool> useExtra = ValueNotifier(false);
  final ValueNotifier<bool> failedRendering = ValueNotifier(false);
  final ValueNotifier<String?> errorCode = ValueNotifier(null);
  CancelToken? mainCancelToken, extraCancelToken, loadItemCancelToken;

  late String currentUrl;

  Timer? debounceLoading;

  bool? isThumbQuality;
  late String thumbURL;
  late String thumbFolder;
  double? thumbWidth, thumbHeight;

  final ValueNotifier<ImageProvider?> mainProvider = ValueNotifier(null), extraProvider = ValueNotifier(null);
  ImageStreamListener? mainImageListener, extraImageListener;
  ImageStream? mainImageStream, extraImageStream;
  int _loadGeneration = 0;

  bool isBlurred = true;

  @override
  void initState() {
    super.initState();

    currentUrl = widget.item.thumbnailURL;
  }

  @override
  void didUpdateWidget(Thumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // force redraw on tab change
    if (oldWidget.item != widget.item) {
      currentUrl = widget.item.thumbnailURL;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;

        await restartLoading();
      });
    }
  }

  Future<ImageProvider> getImageProvider(
    bool isMain, {
    required int loadGeneration,
    bool withCaptchaCheck = false,
  }) async {
    if (isMain) {
      mainCancelToken ??= CancelToken();
    } else {
      extraCancelToken ??= CancelToken();
    }
    final String url = isMain ? thumbURL : widget.item.thumbnailURL;
    final bool isAvif = url.contains('.avif');
    final ImageProvider provider = isAvif
        ? CustomNetworkAvifImage(
            url,
            cancelToken: isMain ? mainCancelToken : extraCancelToken,
            headers: await Tools.getFileCustomHeaders(
              widget.booru,
              item: widget.item,
              checkForReferer: true,
            ),
            withCache: settingsHandler.thumbnailCache,
            cacheFolder: isMain ? thumbFolder : 'thumbnails',
            fileNameExtras: widget.item.fileNameExtras,
            sendTimeout: widget.isStandalone ? const Duration(seconds: 20) : null,
            receiveTimeout: widget.isStandalone ? const Duration(seconds: 20) : null,
            onError: isMain
                ? (error) {
                    if (_isCurrentLoad(loadGeneration)) {
                      onError(error);
                    }
                  }
                : null,
            onCacheDetected: (bool didDetectCache) {
              if (isMain && _isCurrentLoad(loadGeneration)) {
                isFromCache.value = didDetectCache;
              }
            },
            withCaptchaCheck: withCaptchaCheck,
          )
        : CustomNetworkImage(
            url,
            cancelToken: isMain ? mainCancelToken : extraCancelToken,
            headers: await Tools.getFileCustomHeaders(
              widget.booru,
              item: widget.item,
              checkForReferer: true,
            ),
            withCache: settingsHandler.thumbnailCache,
            cacheFolder: isMain ? thumbFolder : 'thumbnails',
            fileNameExtras: widget.item.fileNameExtras,
            sendTimeout: widget.isStandalone ? const Duration(seconds: 20) : null,
            receiveTimeout: widget.isStandalone ? const Duration(seconds: 20) : null,
            onError: isMain
                ? (error) {
                    if (_isCurrentLoad(loadGeneration)) {
                      onError(error);
                    }
                  }
                : null,
            onCacheDetected: (bool didDetectCache) {
              if (isMain && _isCurrentLoad(loadGeneration)) {
                isFromCache.value = didDetectCache;
              }
            },
            withCaptchaCheck: withCaptchaCheck,
          );

    // on desktop devicePixelRatio is not working?
    final bool shouldResize = (thumbWidth != null || thumbHeight != null) && !PlatformExt.isDesktop;
    final bool shouldPixelate = widget.item.isHidden && settingsHandler.shitDevice;

    if (shouldResize || shouldPixelate) {
      return ResizeImage(
        provider,
        // when in low performance mode - resize hidden images to 10px to simulate blur effect
        width: shouldPixelate ? 10 : thumbWidth?.round(),
        height: shouldPixelate ? 10 : thumbHeight?.round(),
        policy: ResizeImagePolicy.fit,
        allowUpscaling: false,
      );
    }

    return provider;
  }

  void calcThumbWidth(BoxConstraints constraints) {
    if (!mounted) {
      return;
    }

    final double widthLimit = constraints.maxWidth * MediaQuery.devicePixelRatioOf(context);
    double thumbRatio = 1;
    final bool hasSizeData = widget.item.fileHeight != null && widget.item.fileWidth != null;

    // Reset first: these are only ever assigned below, so a recycled tile could
    // keep a constraint computed for a previous item on the other axis.
    thumbWidth = null;
    thumbHeight = null;

    if (!widget.isStandalone) {
      thumbWidth = widthLimit;
      return;
    }

    switch (settingsHandler.previewDisplay) {
      case .rectangle:
        thumbRatio = 16 / 9;
        thumbWidth = widthLimit;
        thumbHeight = widthLimit * thumbRatio;
        break;

      case .staggered:
        if (hasSizeData) {
          thumbRatio = widget.item.fileAspectRatio!;
          if (thumbRatio < 1) {
            // vertical image - resize to width
            thumbWidth = widthLimit;
          } else {
            // horizontal image - resize to height
            // fileAspectRatio is width/height, so for a wide image this must
            // divide. Multiplying targeted a height LARGER than the width, which
            // for a 2:1 image meant decoding ~16x the pixels actually needed.
            thumbHeight = widthLimit / thumbRatio;
          }
        } else {
          thumbRatio = 16 / 9;
          thumbWidth = widthLimit;
          thumbHeight = widthLimit * thumbRatio;
        }
        break;

      case .square:
        thumbWidth = widthLimit;
        thumbHeight = widthLimit;
        break;
    }
  }

  void onBytesAdded(int receivedNew, int? totalNew) {
    received.value = receivedNew;
    total.value = totalNew ?? 0;
  }

  void onError(Object error) {
    if (error is DioException && CancelToken.isCancel(error)) {
      //
    } else {
      // A host that just rate limited us gets a break before anything retries.
      if (error is DioException && RequestLimiter.isRateLimitStatus(error.response?.statusCode)) {
        RequestLimiter.reportRateLimited(error.requestOptions.uri.host);
      }

      final int retryLimit = settingsHandler.shitDevice ? 2 : RequestLimiter.maxAttempts;

      if (restartedCount < retryLimit) {
        // Exponential backoff with jitter, replacing a flat 500ms. The old
        // policy let ~30 tiles retry in lockstep 8 times each -- up to 270
        // requests in 4.5s at a host that had just told us to slow down.
        Debounce.debounce(
          tag: 'thumbnail_reload_${widget.item.hashCode}',
          callback: () async {
            await restartLoading();
            restartedCount++;
          },
          duration: RequestLimiter.backoffFor(restartedCount),
        );
      } else {
        isFailed.value = true;
        if (error is DioException) {
          errorCode.value = error.response?.statusCode?.toString();
        } else {
          errorCode.value = null;
        }
      }
    }
  }

  void selectThumbProvider({
    bool withCaptchaCheck = false,
  }) {
    final int loadGeneration = ++_loadGeneration;
    startedAt.value = DateTime.now().millisecondsSinceEpoch;

    isThumbQuality = shouldUseThumbnailQuality(
      previewModeIsThumbnail: settingsHandler.previewMode.isThumbnail,
      mediaType: widget.item.mediaType.value,
      fileURL: widget.item.fileURL,
      sampleURL: widget.item.sampleURL,
    );
    thumbURL = isThumbQuality == true ? widget.item.thumbnailURL : widget.item.sampleURL;
    thumbFolder = (isThumbQuality == true || thumbURL == widget.item.thumbnailURL) ? 'thumbnails' : 'samples';
    useExtra.value = isThumbQuality == false && !widget.item.isHidden && !settingsHandler.shitDevice;

    // delay loading a little to improve performance when scrolling fast, ignore delay if it's a standalone widget (i.e. not in a list)
    debounceLoading = Timer(
      Duration(milliseconds: widget.isStandalone ? 200 : 0),
      () => startDownloading(
        loadGeneration: loadGeneration,
        withCaptchaCheck: withCaptchaCheck,
      ),
    );
    return;
  }

  Future<void> startDownloading({
    required int loadGeneration,
    bool withCaptchaCheck = false,
  }) async {
    final ImageProvider newMainProvider = await getImageProvider(
      true,
      loadGeneration: loadGeneration,
      withCaptchaCheck: withCaptchaCheck,
    );

    if (!_isCurrentLoad(loadGeneration)) {
      return;
    }

    mainProvider.value = newMainProvider;
    _removeMainImageStreamListener();
    mainImageStream = mainProvider.value!.resolve(ImageConfiguration.empty);
    mainImageListener = ImageStreamListener(
      (imageInfo, syncCall) {
        if (!_isCurrentLoad(loadGeneration)) return;

        isLoaded.value = true;
      },
      onChunk: (event) {
        if (!_isCurrentLoad(loadGeneration)) return;

        onBytesAdded(event.cumulativeBytesLoaded, event.expectedTotalBytes);
      },
      onError: (e, s) {
        if (!_isCurrentLoad(loadGeneration)) return;

        if (e is! DioException) {
          failedRendering.value = true;
        }
        Logger.Inst().log(
          'Error loading thumbnail: ${widget.item.sampleURL} ${widget.item.thumbnailURL}',
          'Thumbnail',
          'build',
          LogTypes.imageLoadingError,
          s: s,
        );
        onError(e);
      },
    );
    mainImageStream!.addListener(mainImageListener!);

    // The underlay exists to show *something* while the larger sample downloads.
    // If the sample was already in the image cache its stream resolves
    // synchronously, so `isLoaded` is already true by now and a second request
    // would fetch a blurry preview nobody will ever see. Skipping it halves the
    // request count on every scroll-back and re-visit.
    if (isLoaded.value) {
      useExtra.value = false;
    }

    if (useExtra.value) {
      final ImageProvider newExtraProvider = await getImageProvider(
        false,
        loadGeneration: loadGeneration,
      );

      if (!_isCurrentLoad(loadGeneration)) {
        return;
      }

      extraProvider.value = newExtraProvider;
      _removeExtraImageStreamListener();
      extraImageStream = extraProvider.value!.resolve(ImageConfiguration.empty);
      extraImageListener = ImageStreamListener(
        (imageInfo, syncCall) {
          if (!_isCurrentLoad(loadGeneration)) return;

          isLoadedExtra.value = true;
        },
        onError: (e, s) {
          if (!_isCurrentLoad(loadGeneration)) return;

          if (e is! DioException) {
            failedRendering.value = true;
          }
          Logger.Inst().log(
            'Error loading extra thumbnail: ${widget.item.thumbnailURL}',
            'Thumbnail',
            'build',
            LogTypes.imageLoadingError,
            s: s,
          );
        },
      );
      extraImageStream!.addListener(extraImageListener!);
    }
  }

  Future<void> restartLoading({bool withItemLoad = false}) async {
    if (failedRendering.value) {
      failedRendering.value = false;
      unawaited(cleanProviderCache());
    }

    disposables(evictProviders: true);

    total.value = 0;
    received.value = 0;
    startedAt.value = 0;

    isLoaded.value = false;
    isLoadedExtra.value = false;
    isFromCache.value = null;
    isFailed.value = false;
    errorCode.value = null;

    bool? updateRes;
    if (withItemLoad) {
      loadItemCancelToken = CancelToken();
      final CancelToken itemLoadCancelToken = loadItemCancelToken!;
      updateRes = await tryToLoadAndUpdateItem(
        widget.item,
        itemLoadCancelToken,
      );

      if (!mounted || itemLoadCancelToken.isCancelled || !identical(loadItemCancelToken, itemLoadCancelToken)) {
        return;
      }
    }

    selectThumbProvider(
      withCaptchaCheck: withItemLoad && updateRes != true,
    );
  }

  Future<void> cleanProviderCache() async {
    for (final provider in [
      if (mainProvider.value != null && mainProvider.value is ResizeImage)
        (mainProvider.value! as ResizeImage).imageProvider
      else
        mainProvider.value,
      //
      if (extraProvider.value != null && extraProvider.value is ResizeImage)
        (extraProvider.value! as ResizeImage).imageProvider
      else
        extraProvider.value,
    ]) {
      if (provider == null) {
        continue;
      }

      switch (provider) {
        case CustomNetworkImage _:
          await provider.deleteCacheFile();
          break;
        case CustomNetworkAvifImage _:
          await provider.deleteCacheFile();
          break;
      }
    }
  }

  @override
  void dispose() {
    disposables();
    disposeNotifiers();
    super.dispose();
  }

  /// [evictProviders] purges the decoded bitmaps from Flutter's image cache.
  ///
  /// Correct when *this* provider is being abandoned (a failed load being
  /// retried), wrong when the widget is merely being torn down for structural
  /// reasons -- a trim, an orientation change, a tab rebuild. Evicting there
  /// throws away work that is about to be needed again, which is what made the
  /// grid visibly blank out and reload. Flutter's own LRU already bounds the
  /// cache (see the explicit limits set in main.dart), and an image with no
  /// live listeners is a normal LRU candidate the moment this widget goes away.
  void disposables({bool evictProviders = false}) {
    _loadGeneration++;
    _removeMainImageStreamListener();
    _removeExtraImageStreamListener();

    if (!(mainCancelToken?.isCancelled ?? true)) {
      mainCancelToken?.cancel();
    }
    mainCancelToken = null;

    if (!(extraCancelToken?.isCancelled ?? true)) {
      extraCancelToken?.cancel();
    }
    extraCancelToken = null;

    if (!(loadItemCancelToken?.isCancelled ?? true)) {
      loadItemCancelToken?.cancel();
    }
    loadItemCancelToken = null;

    if (widget.isStandalone) {
      if (evictProviders) {
        mainProvider.value?.evict();
        extraProvider.value?.evict();
      }
      mainProvider.value = null;
      extraProvider.value = null;
    }

    debounceLoading?.cancel();
    debounceLoading = null;
    Debounce.cancel('thumbnail_reload_${widget.item.hashCode}');
  }

  bool _isCurrentLoad(int loadGeneration) {
    return mounted && loadGeneration == _loadGeneration;
  }

  void _removeMainImageStreamListener() {
    final ImageStreamListener? listener = mainImageListener;
    if (listener != null) {
      mainImageStream?.removeListener(listener);
    }
    mainImageListener = null;
    mainImageStream = null;
  }

  void _removeExtraImageStreamListener() {
    final ImageStreamListener? listener = extraImageListener;
    if (listener != null) {
      extraImageStream?.removeListener(listener);
    }
    extraImageListener = null;
    extraImageStream = null;
  }

  void disposeNotifiers() {
    total.dispose();
    received.dispose();
    startedAt.dispose();
    isFromCache.dispose();
    isFirstBuild.dispose();
    isFailed.dispose();
    isLoaded.dispose();
    isLoadedExtra.dispose();
    useExtra.dispose();
    failedRendering.dispose();
    errorCode.dispose();
    mainProvider.dispose();
    extraProvider.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget imageStack = LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;

          calcThumbWidth(constraints);
          if (isFirstBuild.value) {
            isFirstBuild.value = false;
            selectThumbProvider();
          }

          if (currentUrl != widget.item.thumbnailURL) {
            currentUrl = widget.item.thumbnailURL;
            restartLoading();
          }
        });

        // take smallest dimension for hidden icon container
        final double iconSize =
            (constraints.maxHeight < constraints.maxWidth ? constraints.maxHeight : constraints.maxWidth) * 0.75;

        final double blurAmount = (settingsHandler.blurImages && !widget.isStandalone)
            ? 40
            : max(constraints.maxWidth * (widget.isStandalone ? 0.1 : 0.06), 10);

        // Built once per layout instead of twice per build. blurImages defaults
        // to false, so in the common case both ImageFiltered widgets below were
        // allocating a native Skia filter that was never used.
        final bool blurEnabledForExtra = settingsHandler.blurImages || widget.item.isHidden;
        final bool blurEnabledForMain =
            isBlurred && (settingsHandler.blurImages || (widget.item.isHidden && !settingsHandler.shitDevice));
        final ImageFilter? sharedBlur = (blurEnabledForExtra || blurEnabledForMain)
            ? ImageFilter.blur(sigmaX: blurAmount, sigmaY: blurAmount, tileMode: TileMode.decal)
            : null;

        return Stack(
          alignment: Alignment.center,
          children: [
            if (widget.isStandalone)
              ValueListenableBuilder(
                valueListenable: isFailed,
                builder: (context, isFailed, _) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    color: isFailed ? Colors.red.withValues(alpha: 0.1) : Colors.transparent,
                  );
                },
              ),
            //
            ValueListenableBuilder(
              valueListenable: useExtra,
              builder: (context, useExtra, child) {
                // fetch small low quality thumbnail while loading a sample
                return useExtra ? child! : const SizedBox.shrink();
              },
              child: ValueListenableBuilder(
                valueListenable: isLoadedExtra,
                builder: (context, isLoadedExtra, child) {
                  return AnimatedOpacity(
                    // fade in image
                    opacity: (!widget.isStandalone || isLoadedExtra) ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: child,
                  );
                },
                child: ImageFiltered(
                  enabled: blurEnabledForExtra,
                  imageFilter: sharedBlur ?? _noBlur,
                  child: ValueListenableBuilder(
                    valueListenable: extraProvider,
                    builder: (context, extraProvider, _) {
                      Widget child = const SizedBox.shrink();

                      if (extraProvider != null) {
                        child = Image(
                          image: extraProvider,
                          fit: widget.isStandalone ? BoxFit.cover : BoxFit.contain,
                          isAntiAlias: true,
                          filterQuality: FilterQuality.medium,
                          width: double.infinity,
                          height: double.infinity,
                          errorBuilder: (BuildContext context, Object exception, StackTrace? stackTrace) {
                            if (widget.isStandalone) {
                              return Icon(
                                Icons.broken_image,
                                size: 30,
                                color: Colors.yellow.withValues(alpha: 0.5),
                              );
                            } else {
                              return const SizedBox.shrink();
                            }
                          },
                        );
                      }

                      return AnimatedSwitcher(
                        duration: Duration(milliseconds: widget.isStandalone ? 100 : 0),
                        child: child,
                      );
                    },
                  ),
                ),
              ),
            ),
            //
            ValueListenableBuilder(
              valueListenable: isLoaded,
              builder: (context, isLoaded, child) {
                return AnimatedOpacity(
                  // fade in image
                  opacity: (settingsHandler.shitDevice || !widget.isStandalone || isLoaded) ? 1 : 0,
                  duration: const Duration(milliseconds: 300),
                  child: child,
                );
              },
              child: GestureDetector(
                // TODO reenable after filters rework (when blur/hide will be separate for each filter)
                // ignore: dead_code
                onTap: false && (widget.item.isHidden && !settingsHandler.shitDevice && widget.isStandalone)
                    // ignore: dead_code
                    ? () => setState(() => isBlurred = !isBlurred)
                    : null,
                child: ImageFiltered(
                  enabled: blurEnabledForMain,
                  imageFilter: sharedBlur ?? _noBlur,
                  child: ValueListenableBuilder(
                    valueListenable: mainProvider,
                    builder: (context, mainProvider, _) {
                      Widget child = const SizedBox.shrink();

                      if (mainProvider != null) {
                        child = TickerMode(
                          enabled: settingsHandler.gifsAsThumbnails,
                          child: Image(
                            image: mainProvider,
                            fit: widget.isStandalone ? BoxFit.cover : BoxFit.contain,
                            isAntiAlias: true,
                            filterQuality: FilterQuality.medium,
                            width: double.infinity,
                            height: double.infinity,
                            errorBuilder: (BuildContext context, Object exception, StackTrace? stackTrace) {
                              if (widget.isStandalone) {
                                return Icon(
                                  Icons.broken_image,
                                  size: 30,
                                  color: Colors.white.withValues(alpha: 0.5),
                                );
                              } else {
                                return const SizedBox.shrink();
                              }
                            },
                          ),
                        );
                      }

                      return AnimatedSwitcher(
                        duration: Duration(milliseconds: widget.isStandalone ? 200 : 0),
                        child: child,
                      );
                    },
                  ),
                ),
              ),
            ),
            //
            if (widget.isStandalone && !settingsHandler.shitDevice)
              ListenableBuilder(
                listenable: Listenable.merge([isLoaded, isLoadedExtra, isFailed]),
                builder: (context, _) {
                  final bool isAnyLoaded = isLoaded.value || isLoadedExtra.value;
                  final bool showShimmer = !isAnyLoaded && !isFailed.value;

                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: showShimmer ? const ShimmerCard() : const SizedBox.shrink(),
                  );
                },
              ),
            //
            if (widget.isStandalone && widget.item.isHidden)
              Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(iconSize * 0.1),
                ),
                width: iconSize,
                height: iconSize,
                child: const Icon(
                  CupertinoIcons.eye_slash,
                  color: Colors.white,
                ),
              ),
            if (widget.isStandalone)
              ValueListenableBuilder(
                valueListenable: isLoaded,
                builder: (context, isLoadedVal, child) {
                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: isLoadedVal ? const SizedBox.shrink() : child,
                  );
                },
                child: ListenableBuilder(
                  listenable: Listenable.merge([isLoaded, isFromCache, isFailed, errorCode]),
                  builder: (context, child) {
                    if (widget.booru == null) return const SizedBox.shrink();

                    final bool isFavOrDlsOrHasLoad =
                        widget.booru?.type?.isFavouritesOrDownloads == true ||
                        BooruHandlerFactory().getBooruHandler([widget.booru!], null).booruHandler.hasLoadItemSupport;

                    return ThumbnailLoading(
                      item: widget.item,
                      hasProgress: true,
                      isFromCache: isFromCache.value,
                      // if any of the thumbnails loaded - dont consider a failure
                      isDone: isLoaded.value || (isFailed.value && isLoadedExtra.value),
                      isFailed: isFailed.value && !isLoaded.value && !isLoadedExtra.value,
                      total: total,
                      received: received,
                      startedAt: startedAt,
                      retryText: isFavOrDlsOrHasLoad ? 'Tap to update or retry' : null,
                      retryIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        spacing: 4,
                        children: isFavOrDlsOrHasLoad
                            ? const [
                                Icon(Icons.download),
                                Text('/', style: TextStyle(fontSize: 20)),
                                Icon(Icons.refresh),
                              ]
                            : const [
                                Icon(Icons.refresh),
                              ],
                      ),
                      restartAction: () async {
                        restartedCount = 0;

                        await restartLoading(withItemLoad: isFavOrDlsOrHasLoad);
                      },
                      errorCode: errorCode.value,
                    );
                  },
                ),
              ),
          ],
        );
      },
    );

    imageStack = Material(
      color: Colors.transparent,
      child: imageStack,
    );

    if (widget.isStandalone && widget.useHero) {
      return HeroMode(
        enabled: settingsHandler.enableHeroTransitions && !settingsHandler.shitDevice,
        child: Hero(
          tag: 'imageHero${widget.item.hashCode}',
          placeholderBuilder: (BuildContext context, Size heroSize, Widget child) {
            // keep building the image since the images can be visible in the
            // background of the image gallery
            return child;
          },
          child: imageStack,
        ),
      );
    } else {
      return imageStack;
    }
  }
}

/// Returns true if successful, false on error and null on skip
Future<bool?> tryToLoadAndUpdateItem(
  BooruItem item,
  CancelToken cancelToken,
) async {
  try {
    final itemFileHost = Uri.tryParse(item.fileURL)?.host;
    final itemPostHost = Uri.tryParse(item.postURL)?.host;
    final Booru? possibleBooru = SettingsHandler.instance.booruList.firstWhereOrNull((e) {
      final booruHost = Uri.tryParse(e.baseURL ?? '')?.host;

      return (itemPostHost?.isNotEmpty == true &&
              booruHost?.isNotEmpty == true &&
              (itemPostHost! == booruHost! ||
                  switch (e.type) {
                    BooruType.IdolSankaku => IdolSankakuHandler.knownUrls.contains(itemPostHost),
                    BooruType.Sankaku => SankakuHandler.knownPostUrls.contains(itemPostHost),
                    _ => false,
                  })) ||
          (itemFileHost?.isNotEmpty == true && booruHost?.isNotEmpty == true && itemFileHost! == booruHost!);
    });

    if (possibleBooru != null) {
      final handler = BooruHandlerFactory().getBooruHandler([possibleBooru], null).booruHandler;
      if (handler.hasLoadItemSupport) {
        final result = await handler.loadItem(
          item: item,
          cancelToken: cancelToken,
          withCapcthaCheck: true,
        );

        if (!result.failed &&
            result.item != null &&
            (result.item?.isSnatched.value == true || result.item?.isFavourite.value == true)) {
          unawaited(
            SettingsHandler.instance.dbHandler.updateBooruItem(
              result.item!,
              BooruUpdateMode.urlUpdate,
            ),
          );
          return true;
        } else {
          return false;
        }
      }
    }
    return null;
  } catch (_) {}
  return null;
}
