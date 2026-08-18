import 'package:flutter/foundation.dart';

import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/handlers/booru_handler.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/utils/content_policy.dart';

/// A verbatim copy of `BooruHandler.filterFetched` as it stood before the
/// incremental rewrite, kept frozen as **both** the benchmark baseline and the
/// correctness oracle.
///
/// DO NOT "optimise" or tidy this function. Its whole value is that it is the
/// old behaviour, running in the same process and the same JIT state as the new
/// one, so a before/after comparison needs no git checkout dance.
///
/// Returns the list it would have produced and the number of `fetched` entries
/// it visited. The visit count is the quadratic signal the benchmarks assert on.
({List<BooruItem> items, int visits}) legacyFilterFetched(BooruHandler handler) {
  final SettingsHandler settingsHandler = SettingsHandler.instance;

  final List<BooruItem> filteredItems = <BooruItem>[];
  final Set<String> seenFileUrls = <String>{};
  final Set<String> seenServerIds = <String>{};
  final bool filterFavourites =
      settingsHandler.filterFavourites && handler.booru.type?.isFavourites != true;
  final bool filterSnatched =
      settingsHandler.filterSnatched && handler.booru.type?.isDownloads != true;

  int visits = 0;

  for (final BooruItem item in handler.fetched) {
    visits++;

    if (!ContentPolicy.isItemAllowed(handler.booru, item)) {
      continue;
    }

    if (settingsHandler.filterHated && item.isHidden) {
      continue;
    }

    if (settingsHandler.filterMarked && item.isMarked) {
      continue;
    }

    if (settingsHandler.filterAi && item.isAI) {
      continue;
    }

    if (filterFavourites && item.isFavourite.value == true) {
      continue;
    }

    if (filterSnatched && item.isSnatched.value == true) {
      continue;
    }

    final String? serverId = item.serverId;
    final bool duplicateFileUrl = item.fileURL.isNotEmpty && seenFileUrls.contains(item.fileURL);
    final bool duplicateServerId = serverId != null && seenServerIds.contains(serverId);
    if (duplicateFileUrl || duplicateServerId) {
      continue;
    }
    if (item.fileURL.isNotEmpty) {
      seenFileUrls.add(item.fileURL);
    }
    if (serverId != null) {
      seenServerIds.add(serverId);
    }

    filteredItems.add(item);
  }

  return (items: filteredItems, visits: visits);
}

/// The legacy append path: recompute from scratch and publish, exactly as
/// `afterParseResponse` used to.
int legacyApplyFilterFetched(BooruHandler handler) {
  final List<BooruItem> before = handler.filteredFetched;
  final ({List<BooruItem> items, int visits}) result = legacyFilterFetched(handler);
  if (!listEquals(before, result.items)) {
    handler.filteredFetched.value = result.items;
  }
  return result.visits;
}
