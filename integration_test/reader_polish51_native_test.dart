import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'package:wenku8_flutter/book_import_limits.dart';
import 'package:wenku8_flutter/frame_rate_settings.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('frame preference bridge validates and persists supported rates', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final settings = FrameRateSettings();
    addTearDown(settings.dispose);
    await settings.load();
    expect(settings.error, isNull);
    final before = settings.info!;
    expect(before.rates, isNotEmpty);
    expect(before.current, greaterThan(0));
    try {
      for (final target in [-1.0, before.rates.first, 0.0]) {
        await settings.select(target);
        expect(settings.error, isNull);
        await settings.load();
        expect(settings.info!.target, closeTo(target, .01));
      }
      await settings.select(12345);
      expect(settings.error, contains('不支持'));
      await settings.load();
      expect(settings.info!.target, 0);
      debugPrint(
        'READER51_FRAME rates=${before.rates} mode=${before.current} persistence=ok invalid_vote=rejected',
      );
    } finally {
      await settings.select(before.target);
    }
  });
  testWidgets('native scanner format preferences expand and persist aliases', (
    tester,
  ) async {
    final documents = BookDocuments();
    final before = await documents.scanFormats();
    try {
      await documents.setScanFormats({'epub', 'kindle'});
      expect(await documents.scanFormats(), {'epub', 'kindle'});
      await documents.setScanFormats(bookFormatLabels.keys.toSet());
      expect(await documents.scanFormats(), bookFormatLabels.keys.toSet());
      debugPrint(
        'READER51_SCAN groups=${bookFormatLabels.length} preference_roundtrip=ok',
      );
    } finally {
      await documents.setScanFormats(before);
    }
  });
}
