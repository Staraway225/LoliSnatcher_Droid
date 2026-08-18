import 'dart:math';

import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/data/tag.dart';

/// Deterministic generator of realistic [BooruItem]s for tests and benchmarks.
///
/// Realism matters here for reasons that are easy to get wrong:
///
/// - `fileURL`s are 60-70 chars with long shared prefixes. Short `'url$i'`
///   strings understate the cost of the dedupe stage's string hashing and
///   comparison by roughly an order of magnitude.
/// - Tag lists are **shuffled**, never pre-sorted. `SettingsHandler.cleanTagsList`
///   sorts, and pre-sorted input makes Dart's sort artificially fast.
/// - [Tag.updatedAt] is pinned, because `Tag`'s constructor falls back to
///   `DateTime.now()` when it is 0, which would destroy determinism.
class BooruItemFactory {
  BooruItemFactory({
    int seed = 0x105,
    this.minTags = 50,
    this.maxTags = 200,
    this.vocabularySize = 4000,
    this.duplicateFileUrlRate = 0,
    this.duplicateServerIdRate = 0,
    this.favouriteRate = 0,
    this.snatchedRate = 0,
    this.trackedNullRate = 1,
    this.missingSizeRate = 0.05,
    this.hiddenTagRate = 0,
    this.markedTagRate = 0,
    this.hiddenTagPool = const <String>[],
    this.markedTagPool = const <String>[],
  }) : _random = Random(seed);

  /// Pinned so [Tag] never calls `DateTime.now()`.
  static const int fixedTagTimestamp = 1700000000000;

  static const List<String> _extensions = [
    'jpg',
    'jpg',
    'jpg',
    'png',
    'png',
    'jpeg',
    'webp',
    'gif',
    'mp4',
    'webm',
  ];

  /// Includes the extremes that exercise both clamps in the staggered height
  /// formula: 0.25 hits the upper bound, 4.0 hits the 100px floor.
  static const List<double> _aspectRatios = [
    1,
    0.75,
    1.33,
    0.5625,
    1.78,
    0.25,
    4,
  ];

  final int minTags;
  final int maxTags;
  final int vocabularySize;
  final double duplicateFileUrlRate;
  final double duplicateServerIdRate;
  final double favouriteRate;
  final double snatchedRate;
  final double trackedNullRate;
  final double missingSizeRate;
  final double hiddenTagRate;
  final double markedTagRate;
  final List<String> hiddenTagPool;
  final List<String> markedTagPool;

  final Random _random;
  int _counter = 0;

  final List<String> _recentFileUrls = [];
  final List<String> _recentServerIds = [];

  late final List<String> _vocabulary = List<String>.generate(
    vocabularySize,
    (i) => 'tag_${i.toRadixString(36)}_${(i * 2654435761 % 99991).toRadixString(36)}',
  );

  String _hex32(int n) {
    final StringBuffer buffer = StringBuffer();
    int state = n * 2654435761 + 0x9E3779B9;
    for (int i = 0; i < 8; i++) {
      state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
      buffer.write((state & 0xFFFF).toRadixString(16).padLeft(4, '0'));
    }
    return buffer.toString().substring(0, 32);
  }

  bool _chance(double rate) => rate > 0 && _random.nextDouble() < rate;

  List<Tag> _buildTags() {
    final int count = minTags + _random.nextInt(max(1, maxTags - minTags + 1));
    final List<Tag> tags = <Tag>[];
    final Set<String> used = <String>{};

    while (tags.length < count) {
      final String word = _vocabulary[_random.nextInt(_vocabulary.length)];
      if (used.add(word)) {
        tags.add(Tag(word, updatedAt: fixedTagTimestamp));
      }
    }

    if (hiddenTagPool.isNotEmpty && _chance(hiddenTagRate)) {
      tags.add(
        Tag(hiddenTagPool[_random.nextInt(hiddenTagPool.length)], updatedAt: fixedTagTimestamp),
      );
    }
    if (markedTagPool.isNotEmpty && _chance(markedTagRate)) {
      tags.add(
        Tag(markedTagPool[_random.nextInt(markedTagPool.length)], updatedAt: fixedTagTimestamp),
      );
    }

    tags.shuffle(_random);
    return tags;
  }

  bool? _trackedValue(double trueRate) {
    if (_chance(trackedNullRate)) {
      return null;
    }
    return _chance(trueRate);
  }

  /// Produces one item. Successive calls never repeat unless a duplicate rate
  /// is configured, in which case duplicates are drawn from the recent window
  /// so they land *across* pages, which is what unstable booru paging produces.
  BooruItem next() {
    final int n = _counter++;
    final String ext = _extensions[_random.nextInt(_extensions.length)];
    final String md5 = _hex32(n);

    String fileURL;
    if (_recentFileUrls.isNotEmpty && _chance(duplicateFileUrlRate)) {
      fileURL = _recentFileUrls[_random.nextInt(_recentFileUrls.length)];
    } else {
      fileURL =
          'https://cdn.example-booru.test/images/${md5.substring(0, 2)}/${md5.substring(2, 4)}/$md5.$ext';
    }

    String serverId;
    if (_recentServerIds.isNotEmpty && _chance(duplicateServerIdRate)) {
      serverId = _recentServerIds[_random.nextInt(_recentServerIds.length)];
    } else {
      serverId = '$n';
    }

    _recentFileUrls.add(fileURL);
    _recentServerIds.add(serverId);
    if (_recentFileUrls.length > 200) {
      _recentFileUrls.removeAt(0);
    }
    if (_recentServerIds.length > 200) {
      _recentServerIds.removeAt(0);
    }

    double? width;
    double? height;
    if (!_chance(missingSizeRate)) {
      final double aspect = _aspectRatios[_random.nextInt(_aspectRatios.length)];
      height = (600 + _random.nextInt(3400)).toDouble();
      width = (height * aspect).roundToDouble();
    }

    final BooruItem item = BooruItem(
      fileURL: fileURL,
      sampleURL: 'https://cdn.example-booru.test/samples/${md5.substring(0, 2)}/sample_$md5.jpg',
      thumbnailURL:
          'https://cdn.example-booru.test/thumbnails/${md5.substring(0, 2)}/thumbnail_$md5.jpg',
      tagsList: _buildTags(),
      postURL: 'https://example-booru.test/index.php?page=post&s=view&id=$n',
      fileExt: ext,
      fileWidth: width,
      fileHeight: height,
      serverId: serverId,
      md5String: md5,
      rating: 'general',
    );

    item.isFavourite.value = _trackedValue(favouriteRate);
    item.isSnatched.value = _trackedValue(snatchedRate);
    return item;
  }

  List<BooruItem> page(int size) => List<BooruItem>.generate(size, (_) => next());

  ({List<BooruItem> all, List<List<BooruItem>> pages}) corpus({
    required int pageCount,
    required int pageSize,
  }) {
    final List<List<BooruItem>> pages = <List<BooruItem>>[];
    final List<BooruItem> all = <BooruItem>[];
    for (int i = 0; i < pageCount; i++) {
      final List<BooruItem> p = page(pageSize);
      pages.add(p);
      all.addAll(p);
    }
    return (all: all, pages: pages);
  }
}
