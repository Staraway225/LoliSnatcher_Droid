import 'package:flutter_test/flutter_test.dart';

import 'package:lolisnatcher/src/widgets/image/custom_network_image.dart';

CustomNetworkImage providerFor(String url, Map<String, String> headers) {
  return CustomNetworkImage(
    url,
    headers: headers,
    cacheFolder: 'thumbnails',
  );
}

void main() {
  group('CustomNetworkImage cache key', () {
    // obtainKey returns `this`, so these ARE the imageCache key. If equality is
    // broken the cache can never hit and every rebuilt tile re-decodes.
    test('separately allocated but equal header maps compare equal', () {
      final CustomNetworkImage a = providerFor(
        'https://cdn.example.test/a.jpg',
        <String, String>{'User-Agent': 'LoliSnatcher', 'Cookie': 'x=1'},
      );
      final CustomNetworkImage b = providerFor(
        'https://cdn.example.test/a.jpg',
        <String, String>{'User-Agent': 'LoliSnatcher', 'Cookie': 'x=1'},
      );

      expect(identical(a.headers, b.headers), isFalse, reason: 'maps must be distinct objects');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('header order does not affect equality or hash', () {
      final CustomNetworkImage a = providerFor(
        'https://cdn.example.test/a.jpg',
        <String, String>{'User-Agent': 'LoliSnatcher', 'Cookie': 'x=1'},
      );
      final CustomNetworkImage b = providerFor(
        'https://cdn.example.test/a.jpg',
        <String, String>{'Cookie': 'x=1', 'User-Agent': 'LoliSnatcher'},
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('different headers still compare unequal', () {
      final CustomNetworkImage a = providerFor(
        'https://cdn.example.test/a.jpg',
        <String, String>{'User-Agent': 'LoliSnatcher'},
      );
      final CustomNetworkImage b = providerFor(
        'https://cdn.example.test/a.jpg',
        <String, String>{'User-Agent': 'SomethingElse'},
      );
      expect(a, isNot(equals(b)));
    });

    test('different urls compare unequal', () {
      final Map<String, String> headers = <String, String>{'User-Agent': 'LoliSnatcher'};
      expect(
        providerFor('https://cdn.example.test/a.jpg', headers),
        isNot(equals(providerFor('https://cdn.example.test/b.jpg', headers))),
      );
    });

    test('providers work as map keys, which is what imageCache relies on', () {
      final Map<CustomNetworkImage, String> cache = <CustomNetworkImage, String>{};
      cache[providerFor('https://cdn.example.test/a.jpg', <String, String>{'A': '1'})] = 'hit';

      expect(
        cache[providerFor('https://cdn.example.test/a.jpg', <String, String>{'A': '1'})],
        'hit',
      );
    });
  });
}
