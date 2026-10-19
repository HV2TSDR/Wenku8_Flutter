import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/legacy_transport.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/wenku_account.dart';
import 'package:wenku8_flutter/wenku_reviews.dart';

import '../test/feature_completion_state_test.dart' as state;
import '../test/feature_completion_ui_test.dart' as features;

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(
    pixelRatio: tester.view.devicePixelRatio,
  );
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final directory = Directory('${Directory.systemTemp.path}/ui-refinement');
  await directory.create(recursive: true);
  final file = File('${directory.path}/$name.png');
  await file.writeAsBytes(bytes.buffer.asUint8List());
  debugPrint('UI_REFINEMENT_CAPTURE=${file.path}');
  image.dispose();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('native new feature state', state.main);
  group('native new feature UI', () => features.main(capture: _capture));
  testWidgets('native public publication and review contracts', (tester) async {
    final repository = LegacyWenkuRepository();
    final libraries = await repository.publicationLibraries();
    expect(libraries, isNotEmpty);
    debugPrint(
      'FEATURE_PUBLIC_LIBRARY_IDS ${libraries.map((library) => library.id).join(",")}',
    );
    for (final action in [
      'action=novellist&sort=${libraries.first.id}&page=1&t=0',
      'action=articlelist&sort=${libraries.first.id}&page=1',
      'action=novellist&sort=allvisit&page=1&t=0',
    ]) {
      final diagnostic = await LegacyTransport.request(action);
      debugPrint(
        'FEATURE_PUBLIC_DIAGNOSTIC $action bytes=${diagnostic.length} prefix=${diagnostic.substring(0, diagnostic.length.clamp(0, 120)).replaceAll("\n", " ")}',
      );
    }
    // The current public service gates numeric publication lists with code 4.
    // Never interpret this as an empty category or pretend it was live-tested
    // with an authenticated account. Fixture tests cover the login/resume path.
    await expectLater(
      repository.browsePublication(libraries.first.id),
      throwsA(isA<WenkuApiError>().having((error) => error.code, 'code', 4)),
    );
    debugPrint(
      'FEATURE_PUBLIC_LIBRARIES count=${libraries.length} guest_gate=4',
    );
    final reviewSource = await LegacyTransport.request(
      'action=review&do=list&aid=1239&page=1&t=0',
    );
    final code = wenkuResponseCode(reviewSource);
    if (code != null) {
      expect(code, 4);
      debugPrint('FEATURE_PUBLIC_REVIEWS guest_gate=4');
    } else {
      final reviews = WenkuReviewPage.parse(reviewSource);
      expect(reviews.totalPages, greaterThanOrEqualTo(0));
      debugPrint(
        'FEATURE_PUBLIC_REVIEWS books=1239 items=${reviews.items.length} pages=${reviews.totalPages}',
      );
      if (reviews.items.isNotEmpty) {
        final replies = WenkuReviewPage.parse(
          await LegacyTransport.request(
            'action=review&do=show&rid=${reviews.items.first.id}&page=1&t=0',
          ),
          replies: true,
        );
        expect(replies.items, isNotEmpty);
        debugPrint('FEATURE_PUBLIC_REPLIES count=${replies.items.length}');
      }
    }
    expect(await LegacyTransport.accountRequest('action=userinfo'), '4');
    expect(await LegacyTransport.hasSession(), isFalse);
    expect(
      await LegacyTransport.encodeReview('中文 &'),
      'JUQ2JUQwJUNFJUM0KyUyNg==',
    );
    await expectLater(
      LegacyTransport.encodeReview('中文 😀'),
      throwsFormatException,
    );
    debugPrint('FEATURE_NATIVE_SESSION guest=true gbk_encoder=verified');
  });
  testWidgets('native actual chapter illustration is preserved and cached', (
    tester,
  ) async {
    final repository = LegacyWenkuRepository();
    final chapters = await repository.chapters(1239);
    expect(chapters, isNotEmpty);
    String? imageUrl;
    final candidates = [
      ...chapters.where((chapter) => chapter.title.contains('插图')).take(3),
      ...chapters.take(6),
    ];
    for (final chapter in candidates) {
      final content = await ReaderContent.parse(
        await repository.chapterContent(1239, chapter),
      );
      if (content.illustrations.isNotEmpty) {
        imageUrl = content.illustrations.first;
        break;
      }
    }
    expect(imageUrl, isNotNull);
    final bytes = await LegacyTransport.illustration(imageUrl!);
    expect(bytes.length, greaterThan(1000));
    final again = await LegacyTransport.illustration(imageUrl);
    expect(again, bytes);
    debugPrint(
      'FEATURE_NATIVE_ILLUSTRATION bytes=${bytes.length} cached_read=true',
    );
  });
}
