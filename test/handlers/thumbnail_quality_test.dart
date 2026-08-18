import 'package:flutter_test/flutter_test.dart';

import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/widgets/thumbnail/thumbnail.dart';

void main() {
  group('grid thumbnail quality choice', () {
    test('uses the small preview when the post has no separate sample', () {
      // The regression: rule34.xxx returns sample_url == file_url for ~25% of
      // posts, so asking for "sample" quality downloaded the full original --
      // 20.28 MB per page of 20 tiles instead of 0.20 MB.
      expect(
        shouldUseThumbnailQuality(
          previewModeIsThumbnail: false,
          mediaType: MediaType.image,
          fileURL: 'https://cdn.example.test/full/abc.png',
          sampleURL: 'https://cdn.example.test/full/abc.png',
        ),
        isTrue,
      );
    });

    test('uses the sample when a real one exists', () {
      expect(
        shouldUseThumbnailQuality(
          previewModeIsThumbnail: false,
          mediaType: MediaType.image,
          fileURL: 'https://cdn.example.test/full/abc.png',
          sampleURL: 'https://cdn.example.test/samples/sample_abc.jpg',
        ),
        isFalse,
      );
    });

    test('honours an explicit thumbnail preview mode', () {
      expect(
        shouldUseThumbnailQuality(
          previewModeIsThumbnail: true,
          mediaType: MediaType.image,
          fileURL: 'https://cdn.example.test/full/abc.png',
          sampleURL: 'https://cdn.example.test/samples/sample_abc.jpg',
        ),
        isTrue,
      );
    });

    test('never loads sample quality for video or unresolved media', () {
      for (final MediaType type in <MediaType>[
        MediaType.video,
        MediaType.needToGuess,
        MediaType.needToLoadItem,
      ]) {
        expect(
          shouldUseThumbnailQuality(
            previewModeIsThumbnail: false,
            mediaType: type,
            fileURL: 'https://cdn.example.test/full/abc.mp4',
            sampleURL: 'https://cdn.example.test/samples/sample_abc.jpg',
          ),
          isTrue,
          reason: '$type must not pull sample quality',
        );
      }
    });
  });
}
