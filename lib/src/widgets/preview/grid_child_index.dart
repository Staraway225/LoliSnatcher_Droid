import 'package:flutter/widgets.dart';

import 'package:lolisnatcher/src/data/booru_item.dart';

/// Resolves a grid child's key back to its current index.
///
/// Lazy slivers keep built children in a map keyed by *integer index*. On
/// rebuild, `SliverMultiBoxAdaptorElement.performRebuild` asks the delegate
/// `findIndexByKey` for each built child; when the delegate has no
/// `findChildIndexCallback` that returns `null` immediately, every element stays
/// pinned to its old index. The sliding-window trim shifts every surviving item
/// down, so `Widget.canUpdate` then compares two different item keys, fails, and
/// Flutter destroys and re-inflates *every visible tile* — disposing each
/// `Thumbnail`, evicting its decoded bitmap and cancelling its in-flight request.
/// The user sees the whole grid blank out and reload on every trim.
///
/// Supplying this callback lets the sliver relocate the existing elements
/// instead, so nothing is disposed.
///
/// Note this is only half the fix: any key *inside* the tile that encodes the
/// index (e.g. `AutoScrollTag`) must also be made stable, or the subtree is torn
/// down one level lower regardless.
class GridChildIndexResolver {
  const GridChildIndexResolver._();

  // Single-slot memo: only one grid is on screen at a time. Compared by identity
  // rather than a hash so a collision can never hand back a wrong index.
  static List<BooruItem>? _items;
  static int _length = -1;
  static Map<Key, int>? _map;

  /// Returns a callback mapping the key set by the grid builders
  /// (`ValueKey(item.key)`) to that item's current index in [items].
  ///
  /// Flutter unwraps its internal `_SaltedValueKey` before calling this, so the
  /// key received is exactly the one the builder assigned.
  static int? Function(Key) forList(List<BooruItem> items) {
    return (Key key) {
      if (!identical(_items, items) || _length != items.length || _map == null) {
        final Map<Key, int> map = <Key, int>{};
        for (int i = 0; i < items.length; i++) {
          map[ValueKey<Key>(items[i].key)] = i;
        }
        _items = items;
        _length = items.length;
        _map = map;
      }
      return _map![key];
    };
  }

  /// Drops the memo. Only needed if the backing list is mutated in place without
  /// its length changing.
  static void invalidate() {
    _items = null;
    _length = -1;
    _map = null;
  }
}
