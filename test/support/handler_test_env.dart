import 'package:get_it/get_it.dart';

import 'package:lolisnatcher/src/data/booru.dart';
import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/data/constants.dart';
import 'package:lolisnatcher/src/handlers/booru_handler.dart';
import 'package:lolisnatcher/src/handlers/booru_handler_factory.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';

/// Offline scaffolding for handler-level tests and benchmarks.
///
/// Deliberate constraints, each of which will bite if ignored:
///
/// - Only `SettingsHandler.register()` is called, never `initialize()`. The
///   constructor is inert (`DBHandler.db` stays null, no platform channels, no
///   SharedPreferences), but `initialize()` reads and writes
///   `~/.loliSnatcher/config/` on the developer's real machine.
/// - Tag filter lists are mutated directly. `SettingsHandler.addTagToList`
///   calls `saveSettings()`, which writes to disk.
/// - The handler resolves to `EmptyHandler`, which overrides nothing, so
///   `search()` can never fire a network request.
/// - Never call `BooruHandler.afterParseResponse` here: it fires
///   `unawaited(populateTagHandler(...))`, which touches `TagHandler.instance`
///   and makes GetIt throw inside an unawaited future. Drive `fetched` directly.
class HandlerTestEnv {
  HandlerTestEnv._(this.settings, this.handler);

  factory HandlerTestEnv.setUp({
    int itemLimit = Constants.defaultItemLimit,
    bool filterHated = false,
    bool filterMarked = false,
    bool filterAi = false,
    bool filterFavourites = false,
    bool filterSnatched = false,
    Set<String> hiddenTags = const <String>{},
    Set<String> markedTags = const <String>{},
  }) {
    final SettingsHandler settings = SettingsHandler.register();
    settings
      ..itemLimit = itemLimit
      ..filterHated = filterHated
      ..filterMarked = filterMarked
      ..filterAi = filterAi
      ..filterFavourites = filterFavourites
      ..filterSnatched = filterSnatched
      ..hiddenTags = <String>{...hiddenTags}
      ..markedTags = <String>{...markedTags};

    final BooruHandler handler = BooruHandlerFactory()
        .getBooruHandler(
          // A null type falls through the factory's switch to `EmptyHandler`,
          // which overrides nothing and therefore never hits the network.
          <Booru>[Booru('bench', null, '', 'https://example-booru.test', '')],
          itemLimit,
        )
        .booruHandler;

    return HandlerTestEnv._(settings, handler);
  }

  final SettingsHandler settings;
  final BooruHandler handler;

  /// Mirrors what `afterParseResponse` does to the lists, minus the parts that
  /// need GetIt-registered singletons or the network.
  void appendPage(List<BooruItem> page) {
    handler.fetched.addAll(page);
    handler.appendedItemsCount += page.length;
    handler.filterAppendedFetched(page);
  }

  /// The legacy shape: append, then re-filter everything from scratch.
  void appendPageFullRebuild(List<BooruItem> page) {
    handler.fetched.addAll(page);
    handler.appendedItemsCount += page.length;
    handler.filterFetched();
  }

  /// Invalidates `BooruItem`'s memoised tag metadata, so a repeated benchmark
  /// rep pays the same tag-filter cost as the first one instead of hitting the
  /// `identical(_cachedMetadataTags, tagsList)` fast path.
  void bumpTagFilterVersion() {
    settings.tagsFiltersMetadataVersion++;
  }

  Future<void> tearDown() async {
    await GetIt.instance.reset();
  }
}
