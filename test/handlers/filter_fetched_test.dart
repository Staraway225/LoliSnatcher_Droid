import 'package:flutter_test/flutter_test.dart';

import 'package:lolisnatcher/src/data/booru_item.dart';

import '../support/booru_item_factory.dart';
import '../support/handler_test_env.dart';
import '../support/legacy_filter_fetched.dart';

void expectIdenticalList(List<BooruItem> actual, List<BooruItem> expected, String reason) {
  expect(actual.length, expected.length, reason: '$reason (length)');
  for (int i = 0; i < actual.length; i++) {
    expect(identical(actual[i], expected[i]), isTrue, reason: '$reason (index $i)');
  }
}

void main() {
  group('filterFetched parity with the frozen oracle', () {
    late HandlerTestEnv env;

    tearDown(() async {
      await env.tearDown();
    });

    test('matches the oracle with all filters off', () {
      env = HandlerTestEnv.setUp();
      final BooruItemFactory factory = BooruItemFactory();

      for (int page = 0; page < 10; page++) {
        final List<BooruItem> page = factory.page(20);
        env.handler.fetched.addAll(page);
        final List<BooruItem> expected = legacyFilterFetched(env.handler).items;
        env.handler.filterAppendedFetched(page);
        expectIdenticalList(env.handler.filteredFetched.value, expected, 'page $page');
      }
    });

    test('matches the oracle with duplicate fileURLs and serverIds', () {
      env = HandlerTestEnv.setUp();
      final BooruItemFactory factory = BooruItemFactory(
        duplicateFileUrlRate: 0.25,
        duplicateServerIdRate: 0.15,
      );

      for (int page = 0; page < 10; page++) {
        final List<BooruItem> page = factory.page(20);
        env.handler.fetched.addAll(page);
        final List<BooruItem> expected = legacyFilterFetched(env.handler).items;
        env.handler.filterAppendedFetched(page);
        expectIdenticalList(env.handler.filteredFetched.value, expected, 'page $page');
      }

      // The corpus must actually exercise dedupe, or this test proves nothing.
      expect(
        env.handler.filteredFetched.length,
        lessThan(env.handler.fetched.length),
        reason: 'expected some items to be dropped as duplicates',
      );
    });

    test('matches the oracle with favourite and snatched filters on', () {
      env = HandlerTestEnv.setUp(filterFavourites: true, filterSnatched: true);
      final BooruItemFactory factory = BooruItemFactory(
        trackedNullRate: 0.2,
        favouriteRate: 0.3,
        snatchedRate: 0.3,
      );

      for (int page = 0; page < 10; page++) {
        final List<BooruItem> page = factory.page(20);
        env.handler.fetched.addAll(page);
        final List<BooruItem> expected = legacyFilterFetched(env.handler).items;
        env.handler.filterAppendedFetched(page);
        expectIdenticalList(env.handler.filteredFetched.value, expected, 'page $page');
      }

      expect(
        env.handler.filteredFetched.length,
        lessThan(env.handler.fetched.length),
        reason: 'expected the tracked-value filters to drop some items',
      );
    });

    test('matches the oracle with hidden and marked tag filters on', () {
      const List<String> hidden = <String>['hidden_a', 'hidden_b'];
      const List<String> marked = <String>['marked_a'];
      env = HandlerTestEnv.setUp(
        filterHated: true,
        filterMarked: true,
        hiddenTags: <String>{...hidden},
        markedTags: <String>{...marked},
      );
      final BooruItemFactory factory = BooruItemFactory(
        hiddenTagRate: 0.25,
        markedTagRate: 0.2,
        hiddenTagPool: hidden,
        markedTagPool: marked,
      );

      for (int page = 0; page < 10; page++) {
        final List<BooruItem> page = factory.page(20);
        env.handler.fetched.addAll(page);
        final List<BooruItem> expected = legacyFilterFetched(env.handler).items;
        env.handler.filterAppendedFetched(page);
        expectIdenticalList(env.handler.filteredFetched.value, expected, 'page $page');
      }

      expect(
        env.handler.filteredFetched.length,
        lessThan(env.handler.fetched.length),
        reason: 'expected the tag filters to drop some items',
      );
    });

    test('the corpus generator is deterministic for a given seed', () {
      final BooruItemFactory a = BooruItemFactory();
      final BooruItemFactory b = BooruItemFactory();
      final List<BooruItem> pageA = a.page(50);
      final List<BooruItem> pageB = b.page(50);

      for (int i = 0; i < pageA.length; i++) {
        expect(pageA[i].fileURL, pageB[i].fileURL);
        expect(pageA[i].serverId, pageB[i].serverId);
        expect(pageA[i].tagsList.length, pageB[i].tagsList.length);
        expect(pageA[i].fileWidth, pageB[i].fileWidth);
        expect(pageA[i].fileHeight, pageB[i].fileHeight);
      }
    });
  });
}
