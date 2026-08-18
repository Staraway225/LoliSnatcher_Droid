import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/data/tag.dart';

import '../support/booru_item_factory.dart';
import '../support/handler_test_env.dart';

BooruItem itemWith({
  required String fileURL,
  required String serverId,
  List<String> tags = const <String>[],
}) {
  return BooruItem(
    fileURL: fileURL,
    sampleURL: fileURL,
    thumbnailURL: fileURL,
    tagsList: tags.map((String t) => Tag(t, updatedAt: BooruItemFactory.fixedTagTimestamp)).toList(),
    postURL: 'https://example-booru.test/$serverId',
    serverId: serverId,
  );
}

void main() {
  group('sliding-window trim', () {
    late HandlerTestEnv env;

    tearDown(() async {
      await GetIt.instance.reset();
    });

    test('keeps the list bounded across many appends', () {
      env = HandlerTestEnv.setUp();
      final BooruItemFactory factory = BooruItemFactory();
      const int cap = 200;

      for (int page = 0; page < 200; page++) {
        env.appendPage(factory.page(20));
        final int over = env.handler.filteredFetched.length - cap;
        if (over > 0) {
          env.handler.trimFrontByFilteredCount(over);
        }
      }

      expect(env.handler.filteredFetched.length, lessThanOrEqualTo(cap));
      expect(env.handler.fetched.length, lessThanOrEqualTo(cap));
      // Uncapped this would have been 4000.
      expect(env.handler.fetched.length, lessThan(4000));
    });

    test('trim removes exactly a prefix, preserving order and identity', () {
      env = HandlerTestEnv.setUp();
      final BooruItemFactory factory = BooruItemFactory();
      for (int page = 0; page < 10; page++) {
        env.appendPage(factory.page(20));
      }

      final List<BooruItem> before = List<BooruItem>.of(env.handler.filteredFetched.value);
      final int removed = env.handler.trimFrontByFilteredCount(37);
      expect(removed, 37);

      final List<BooruItem> after = env.handler.filteredFetched.value;
      expect(after.length, before.length - 37);
      for (int i = 0; i < after.length; i++) {
        expect(identical(after[i], before[i + 37]), isTrue, reason: 'index $i');
      }
    });

    test('filteredFetched stays an order-preserving subsequence of fetched', () {
      env = HandlerTestEnv.setUp();
      final BooruItemFactory factory = BooruItemFactory(duplicateFileUrlRate: 0.3);
      for (int page = 0; page < 10; page++) {
        env.appendPage(factory.page(20));
      }
      env.handler.trimFrontByFilteredCount(25);

      final List<BooruItem> fetched = env.handler.fetched.value;
      final List<BooruItem> filtered = env.handler.filteredFetched.value;
      int j = 0;
      for (int i = 0; i < fetched.length && j < filtered.length; i++) {
        if (identical(fetched[i], filtered[j])) {
          j++;
        }
      }
      expect(j, filtered.length, reason: 'every filtered item must appear in fetched, in order');
    });

    test('evicted items are no longer referenced by the handler', () {
      env = HandlerTestEnv.setUp();
      final BooruItemFactory factory = BooruItemFactory();
      for (int page = 0; page < 10; page++) {
        env.appendPage(factory.page(20));
      }

      final List<BooruItem> evicted = env.handler.filteredFetched.value.sublist(0, 40);
      env.handler.trimFrontByFilteredCount(40);

      for (final BooruItem gone in evicted) {
        expect(
          env.handler.fetched.value.any((BooruItem e) => identical(e, gone)),
          isFalse,
          reason: 'fetched still retains an evicted item',
        );
        expect(
          env.handler.filteredFetched.value.any((BooruItem e) => identical(e, gone)),
          isFalse,
          reason: 'filteredFetched still retains an evicted item',
        );
      }
    });

    test('a duplicate whose original was evicted is NOT re-admitted', () {
      // Re-admitting would insert an item mid-list, shifting every index after
      // it and silently invalidating the scroll-offset compensation.
      env = HandlerTestEnv.setUp();
      env.appendPage(<BooruItem>[
        itemWith(fileURL: 'https://x/dupe.jpg', serverId: '1'),
        itemWith(fileURL: 'https://x/b.jpg', serverId: '2'),
        itemWith(fileURL: 'https://x/c.jpg', serverId: '3'),
      ]);
      expect(env.handler.filteredFetched.length, 3);

      env.handler.trimFrontByFilteredCount(1);
      expect(env.handler.filteredFetched.length, 2);

      env.appendPage(<BooruItem>[
        itemWith(fileURL: 'https://x/dupe.jpg', serverId: '99'),
        itemWith(fileURL: 'https://x/d.jpg', serverId: '4'),
      ]);

      final List<String> urls =
          env.handler.filteredFetched.map((BooruItem e) => e.fileURL).toList();
      expect(urls.where((String u) => u == 'https://x/dupe.jpg'), isEmpty);
      expect(urls, <String>['https://x/b.jpg', 'https://x/c.jpg', 'https://x/d.jpg']);
    });

    test('evicting a filtered-out item does not release a surviving owner key', () {
      // The trap a naive `seen.remove(item.fileURL)` falls into: the hidden item
      // never claimed the URL, so the later item owns it. Releasing on eviction
      // would let a third copy through as a visible duplicate.
      env = HandlerTestEnv.setUp(
        filterHated: true,
        hiddenTags: <String>{'hidden_tag'},
      );

      env.appendPage(<BooruItem>[
        itemWith(fileURL: 'https://x/shared.jpg', serverId: '1', tags: <String>['hidden_tag']),
        itemWith(fileURL: 'https://x/keep.jpg', serverId: '2'),
        itemWith(fileURL: 'https://x/shared.jpg', serverId: '3'),
      ]);

      // The hidden item is filtered out; serverId 3 owns the shared URL.
      final List<String> ids = env.handler.filteredFetched.map((BooruItem e) => e.serverId!).toList();
      expect(ids, <String>['2', '3']);

      // Trim only the first filtered item (serverId 2). The hidden item sits in
      // the evicted prefix of `fetched` but owns nothing.
      env.handler.trimFrontByFilteredCount(1);
      expect(env.handler.filteredFetched.map((BooruItem e) => e.serverId).toList(), <String>['3']);

      env.appendPage(<BooruItem>[
        itemWith(fileURL: 'https://x/shared.jpg', serverId: '4'),
      ]);

      expect(
        env.handler.filteredFetched.map((BooruItem e) => e.serverId).toList(),
        <String>['3'],
        reason: 'serverId 4 duplicates a URL still owned by serverId 3',
      );
    });

    test('trim is a single notification, not one per element', () {
      env = HandlerTestEnv.setUp();
      final BooruItemFactory factory = BooruItemFactory();
      for (int page = 0; page < 5; page++) {
        env.appendPage(factory.page(20));
      }

      int notifications = 0;
      void listener() => notifications++;
      env.handler.filteredFetched.addListener(listener);
      env.handler.trimFrontByFilteredCount(30);
      env.handler.filteredFetched.removeListener(listener);

      expect(notifications, 1);
    });

    test('trim refuses to remove everything', () {
      env = HandlerTestEnv.setUp();
      final BooruItemFactory factory = BooruItemFactory();
      env.appendPage(factory.page(20));

      expect(env.handler.trimFrontByFilteredCount(20), 0);
      expect(env.handler.trimFrontByFilteredCount(999), 0);
      expect(env.handler.filteredFetched.length, 20);
    });

    test('paging still advances after a trim', () {
      env = HandlerTestEnv.setUp();
      final BooruItemFactory factory = BooruItemFactory();
      for (int page = 0; page < 5; page++) {
        env.appendPage(factory.page(20));
      }
      final int appendedBefore = env.handler.appendedItemsCount;

      env.handler.trimFrontByFilteredCount(40);

      // The end-of-results check keys off this monotone counter, so a trim can
      // no longer make a tab look like it reached its last page.
      expect(env.handler.appendedItemsCount, appendedBefore);
      env.appendPage(factory.page(20));
      expect(env.handler.appendedItemsCount, appendedBefore + 20);
      expect(env.handler.filteredFetched.length, 80);
    });
  });
}
