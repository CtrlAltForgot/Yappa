import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/models/link_preview_model.dart';

void main() {
  test('uses a provider-supplied portrait media ratio', () {
    final preview = LinkPreview.fromJson({
      'mediaUrl': 'https://www.tiktok.com/player/v1/123',
      'mediaAspectRatio': 9 / 16,
    });

    expect(preview.mediaAspectRatio, closeTo(9 / 16, 0.0001));
  });

  test('uses widescreen for missing or unsafe media ratios', () {
    expect(LinkPreview.fromJson({}).mediaAspectRatio, closeTo(16 / 9, 0.0001));
    expect(
      LinkPreview.fromJson({
        'mediaAspectRatio': double.infinity,
      }).mediaAspectRatio,
      closeTo(16 / 9, 0.0001),
    );
    expect(
      LinkPreview.fromJson({'mediaAspectRatio': 0.01}).mediaAspectRatio,
      closeTo(16 / 9, 0.0001),
    );
  });
}
