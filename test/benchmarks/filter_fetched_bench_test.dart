import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'package:lolisnatcher/src/data/booru_item.dart';

import '../support/bench.dart';
import '../support/booru_item_factory.dart';
import '../support/handler_test_env.dart';
import '../support/legacy_filter_fetched.dart';

/// Number of `fetched` entries the legacy full-rescan path visits when [pages]
/// pages of [pageSize] items are appended one page at a time.
///
/// Page 1 rescans N items, page 2 rescans 2N, ... page K rescans K*N, so the
/// total is N * K(K+1)/2 -- quadratic in the page count.
int legacyExpectedVisits({required int pages, required int pageSize}) =>
    pageSize * pages * (pages + 1) ~/ 2;

/// The incremental path visits each appended item exactly once.
int incrementalExpectedVisits({required int pages, required int pageSize}) => pages * pageSize;

void main() {
  const int pageSize = 50;
  const List<int> pageCounts = <int>[50, 100, 200];

  group('filterFetched complexity', () {
    late HandlerTestEnv env;

    tearDown(() async {
      await GetIt.instance.reset();
    });

    test('legacy append path is quadratic in the page count', () {
      for (final int pages in pageCounts) {
        env = HandlerTestEnv.setUp();
        final BooruItemFactory factory = BooruItemFactory();
        final List<List<BooruItem>> corpus = factory
            .corpus(pageCount: pages, pageSize: pageSize)
            .pages;

        int visits = 0;
        for (final List<BooruItem> page in corpus) {
          env.handler.fetched.addAll(page);
          visits += legacyApplyFilterFetched(env.handler);
        }

        expect(
          visits,
          legacyExpectedVisits(pages: pages, pageSize: pageSize),
          reason: 'legacy baseline for $pages pages',
        );
        expect(env.handler.filteredFetched.length, pages * pageSize);

        // ignore: avoid_print
        print(
          'legacy  pages=${pages.toString().padLeft(4)}  '
          'visits=${visits.toString().padLeft(9)}  '
          'per-page=${(visits / pages).toStringAsFixed(1)}',
        );
      }
    });

    test('legacy per-page cost grows linearly with the page count', () {
      final Map<int, double> perPage = <int, double>{};

      for (final int pages in pageCounts) {
        env = HandlerTestEnv.setUp();
        final BooruItemFactory factory = BooruItemFactory();
        final List<List<BooruItem>> corpus = factory
            .corpus(pageCount: pages, pageSize: pageSize)
            .pages;

        int visits = 0;
        for (final List<BooruItem> page in corpus) {
          env.handler.fetched.addAll(page);
          visits += legacyApplyFilterFetched(env.handler);
        }
        perPage[pages] = visits / pages;
      }

      // 4x the pages => ~4x the per-page rescan cost. This is the shape the
      // incremental rewrite must flatten.
      expect(perPage[200]! / perPage[50]!, closeTo(4, 0.1));
    });
  });

  group('filterFetched incremental complexity', () {
    late HandlerTestEnv env;

    tearDown(() async {
      await GetIt.instance.reset();
    });

    test('incremental append visits each fetched item exactly once', () {
      // THE regression test. If the full rescan ever returns, the observed
      // count jumps by ~100x and this fails loudly rather than subtly.
      for (final int pages in pageCounts) {
        env = HandlerTestEnv.setUp();
        final BooruItemFactory factory = BooruItemFactory();
        final List<List<BooruItem>> corpus = factory
            .corpus(pageCount: pages, pageSize: pageSize)
            .pages;

        env.handler.debugResetFilterCounters();
        for (final List<BooruItem> page in corpus) {
          env.appendPage(page);
        }

        expect(
          env.handler.debugFilterVisits,
          incrementalExpectedVisits(pages: pages, pageSize: pageSize),
          reason: 'incremental append for $pages pages',
        );
        expect(env.handler.filteredFetched.length, pages * pageSize);

        // ignore: avoid_print
        print(
          'incr    pages=${pages.toString().padLeft(4)}  '
          'visits=${env.handler.debugFilterVisits.toString().padLeft(9)}  '
          'per-page=${(env.handler.debugFilterVisits / pages).toStringAsFixed(1)}',
        );
      }
    });

    test('per-page cost is constant regardless of how far you have scrolled', () {
      final Map<int, double> perPage = <int, double>{};

      for (final int pages in pageCounts) {
        env = HandlerTestEnv.setUp();
        final BooruItemFactory factory = BooruItemFactory();
        final List<List<BooruItem>> corpus = factory
            .corpus(pageCount: pages, pageSize: pageSize)
            .pages;

        env.handler.debugResetFilterCounters();
        for (final List<BooruItem> page in corpus) {
          env.appendPage(page);
        }
        perPage[pages] = env.handler.debugFilterVisits / pages;
      }

      // Exact equality, no tolerance: the count is integral and deterministic.
      expect(perPage[50], pageSize.toDouble());
      expect(perPage[200], perPage[50]);
    });

    test('dedupe state stays proportional to retained items', () {
      env = HandlerTestEnv.setUp();
      final BooruItemFactory factory = BooruItemFactory();
      for (final List<BooruItem> page
          in factory.corpus(pageCount: 100, pageSize: pageSize).pages) {
        env.appendPage(page);
      }

      // At most one fileURL key plus one serverId key per retained item.
      expect(
        env.handler.debugDedupeKeyCount,
        lessThanOrEqualTo(2 * env.handler.fetched.length),
      );
    });

    test('incremental and legacy paths agree on the final list', () {
      env = HandlerTestEnv.setUp(filterFavourites: true, filterSnatched: true);
      final BooruItemFactory incrementalFactory = BooruItemFactory(
        duplicateFileUrlRate: 0.2,
        trackedNullRate: 0.3,
        favouriteRate: 0.3,
        snatchedRate: 0.3,
      );
      final BooruItemFactory legacyFactory = BooruItemFactory(
        duplicateFileUrlRate: 0.2,
        trackedNullRate: 0.3,
        favouriteRate: 0.3,
        snatchedRate: 0.3,
      );

      for (int i = 0; i < 20; i++) {
        env.appendPage(incrementalFactory.page(pageSize));
      }
      final List<String> incrementalUrls =
          env.handler.filteredFetched.map((BooruItem e) => e.fileURL).toList();

      // Same seed, same corpus, driven through the frozen algorithm instead.
      final HandlerTestEnv legacyEnv = HandlerTestEnv.setUp(
        filterFavourites: true,
        filterSnatched: true,
      );
      for (int i = 0; i < 20; i++) {
        legacyEnv.handler.fetched.addAll(legacyFactory.page(pageSize));
        legacyApplyFilterFetched(legacyEnv.handler);
      }
      final List<String> legacyUrls =
          legacyEnv.handler.filteredFetched.map((BooruItem e) => e.fileURL).toList();

      expect(incrementalUrls, legacyUrls);
    });

    test('incremental timing report', () {
      if (!timingEnabled) {
        markTestSkipped('set LS_BENCH=timing and --concurrency=1 for timing runs');
        return;
      }

      final Map<int, double> perPageMicros = <int, double>{};

      for (final int pages in pageCounts) {
        env = HandlerTestEnv.setUp();
        final BooruItemFactory factory = BooruItemFactory();
        final List<List<BooruItem>> corpus = factory
            .corpus(pageCount: pages, pageSize: pageSize)
            .pages;

        final BenchResult result = runBench(
          'incremental append x$pages pages',
          setup: () {
            env.handler.resetFetched();
            env.handler.filteredFetched.value = <BooruItem>[];
          },
          body: () {
            for (final List<BooruItem> page in corpus) {
              env.appendPage(page);
            }
          },
          opCount: pages,
        );
        perPageMicros[pages] = result.bestMicrosPerOp;

        // ignore: avoid_print
        print(result.format());
      }

      // Ideal is 1.0 (flat). The quadratic path measures around 4-6.
      expect(
        perPageMicros[200]! / perPageMicros[50]!,
        lessThan(2),
        reason: 'per-page cost must not grow with the page count',
      );
    });
  });

  group('filterFetched wall clock', () {
    late HandlerTestEnv env;

    tearDown(() async {
      await GetIt.instance.reset();
    });

    test('legacy timing report', () {
      if (!timingEnabled) {
        markTestSkipped('set LS_BENCH=timing and --concurrency=1 for timing runs');
        return;
      }

      for (final int pages in pageCounts) {
        env = HandlerTestEnv.setUp();
        final BooruItemFactory factory = BooruItemFactory();
        // Built once, outside the timed region: BooruItem's constructor dwarfs
        // the filtering we are trying to measure.
        final List<List<BooruItem>> corpus = factory
            .corpus(pageCount: pages, pageSize: pageSize)
            .pages;

        final BenchResult result = runBench(
          'legacy append x$pages pages',
          setup: () => env.handler
            ..fetched.value = <BooruItem>[]
            ..filteredFetched.value = <BooruItem>[],
          body: () {
            for (final List<BooruItem> page in corpus) {
              env.handler.fetched.addAll(page);
              legacyApplyFilterFetched(env.handler);
            }
          },
          opCount: pages,
        );

        // ignore: avoid_print
        print(result.format());
      }
    });
  });
}
