import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/app_interactions.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/legacy_transport.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/review_pages.dart';
import 'package:wenku8_flutter/wenku_account.dart';
import 'package:wenku8_flutter/wenku_reviews.dart';

import '../test/feature_completion_ui_test.dart' as features;

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(
    pixelRatio: tester.view.devicePixelRatio,
  );
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    final file = File('${Directory.systemTemp.path}/ui-refinement/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes.buffer.asUint8List());
    debugPrint('UI_REFINEMENT_CAPTURE=${file.path}');
  } finally {
    image.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('native review regression', () => features.main(capture: _capture));

  testWidgets(
    'native public review navigation preserves original post and replies',
    (tester) async {
      await NativeEffects.prepare();
      final repository = LegacyWenkuRepository();
      final novel = await repository.find(1239);
      expect(novel, isNotNull);
      final source = await LegacyTransport.request(
        'action=review&do=list&aid=1239&page=1&t=0',
      );
      final list = WenkuReviewPage.parse(source);
      expect(list.items, isNotEmpty);
      final thread = list.items.first;
      final threadSource = await LegacyTransport.request(
        'action=review&do=show&rid=${thread.id}&page=1&t=0',
      );
      final expected = WenkuReviewPage.parse(threadSource, replies: true);
      expect(expected.items, isNotEmpty);
      debugPrint(
        'PUBLIC_REVIEW_CONTRACT aid=1239 rid=${thread.id} list_items=${list.items.length} list_pages=${list.totalPages} thread_items=${expected.items.length} thread_pages=${expected.totalPages} body_chars=${expected.items.first.content.length}',
      );
      final account = WenkuAccount();
      final state = await LibraryState.load();
      final feed = WenkuReviewFeed(id: 1239, request: (_) async => source);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: novelTheme(Brightness.light),
            builder: (context, child) => GlassAppearance(child: child!),
            home: Scaffold(
              body: Builder(
                builder: (context) => GlassTextButton(
                  child: const Text('打开真实书评'),
                  onPressed: () => pushNovelPage<void>(
                    context,
                    WenkuReviewsPage(
                      novel: novel!,
                      account: account,
                      state: state,
                      repository: repository,
                      feed: feed,
                    ),
                    reduceMotion: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开真实书评'));
      await tester.pumpAndSettle();
      await _capture(tester, key, 'review-public-list');
      await tester.tap(find.text(thread.title));
      await tester.pumpAndSettle();
      // Native network futures are not advanced by the fake Flutter clock.
      for (
        var attempt = 0;
        attempt < 30 &&
            find.text(expected.items.first.content).evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)),
        );
        await tester.pumpAndSettle();
      }
      expect(find.text(expected.items.first.content), findsOneWidget);
      expect(find.text('01 / ORIGINAL POST'), findsOneWidget);
      expect(find.text('回复这条书评'), findsOneWidget);
      await _capture(tester, key, 'review-public-thread');
      if (expected.items.length > 1) {
        final reply = find.text(expected.items[1].content);
        await tester.scrollUntilVisible(
          reply,
          200,
          scrollable: find.byType(Scrollable),
        );
        await tester.pumpAndSettle();
        expect(reply, findsOneWidget);
        await _capture(tester, key, 'review-public-reply');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      feed.dispose();
      account.dispose();
      state.dispose();
    },
  );
}
