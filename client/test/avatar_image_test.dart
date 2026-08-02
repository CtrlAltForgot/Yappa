import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/shared/avatar_image.dart';
import 'package:yappa/shared/network_asset_scope.dart';

void main() {
  testWidgets('avatar updates immediately from a newly selected data image', (
    tester,
  ) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    final source = ValueNotifier<String?>(null);

    await tester.pumpWidget(
      MaterialApp(
        home: NetworkAssetScope(
          loader: (_) async => Uint8List(0),
          child: ValueListenableBuilder<String?>(
            valueListenable: source,
            builder: (context, value, _) =>
                AvatarImage(source: value, fallbackInitial: 'Y', size: 48),
          ),
        ),
      ),
    );
    expect(find.text('Y'), findsOneWidget);

    source.value = 'data:image/png;base64,$png';
    await tester.pumpAndSettle();

    expect(find.text('Y'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });
}
