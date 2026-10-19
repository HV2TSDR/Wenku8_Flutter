import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_transport.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';
import 'package:wenku8_flutter/reader_volume_illustrations.dart';
import 'support/cover_fixture.dart';
import 'support/visual_review.dart';

const a = 'https://pic.wenku8.cn/pictures/1/a.jpg';
const b = 'https://pic.wenku8.cn/pictures/1/b.jpg';
const c = 'https://pic.wenku8.cn/pictures/1/c.jpg';
const other = 'https://pic.wenku8.cn/pictures/1/other.jpg';
const note = 'https://pic.wenku8.cn/pictures/1/note.png';
const book = Novel(
  id: 56001,
  title: '插图分卷',
  author: '作者',
  genre: '',
  summary: '',
  colors: [Colors.grey, Colors.white],
  chapters: [
    NovelChapter('第一章', '', id: 1, volumeId: 1, volumeTitle: '第一卷'),
    NovelChapter('插图', '', id: 2, volumeId: 1, volumeTitle: '第一卷'),
    NovelChapter('第二章', '', id: 3, volumeId: 1, volumeTitle: '第一卷'),
    NovelChapter(
      '插图',
      '<!--image-->$other<!--image-->',
      id: 4,
      volumeId: 2,
      volumeTitle: '第二卷',
    ),
  ],
);

class _Images extends DemoNovelRepository {
  final calls = <int>[];
  bool fail = false;
  Completer<void>? pending;
  int active = 0, maxActive = 0;
  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    calls.add(chapter.id);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await pending?.future;
      if (chapter.id == 3 && fail) throw StateError('fixture unavailable');
      return switch (chapter.id) {
        1 => '<!--image-->$a<!--image-->',
        2 => '<!--image-->$a<!--image-->\n\n<!--image-->$b<!--image-->',
        3 => '正文\n\n<!--image-->$c<!--image-->',
        _ => '<!--image-->$other<!--image-->',
      };
    } finally {
      active--;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  setUp(() async {
    final bytes = await coverFixtureBytes();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          LegacyTransport.channel,
          (call) async => call.method == 'illustration' ? bytes : null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LegacyTransport.channel, null);
    ReaderIllustrationCache.shared.clearMemory();
  });

  testWidgets(
    'current volume only; cached prose, dedicated and inline images deduplicate in reading order',
    (tester) async {
      final repository = _Images()..pending = Completer<void>();
      final known = await ReaderContent.parse(
        '正文\n\n<!--image-->$a<!--image-->\n\n<!--image-->$note<!--image--><!--epub-image:w=1em-->',
      );
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            theme: novelTheme(Brightness.light),
            home: ReaderVolumeIllustrationsPage(
              novel: book,
              chapter: 0,
              repository: repository,
              known: {0: known},
              reduceMotion: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('volume-image-$a')), findsOneWidget);
      expect(find.byKey(const ValueKey('volume-image-$note')), findsNothing);
      expect(repository.calls, [2, 3]);
      expect(repository.maxActive, 2);
      repository.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('3 IMAGES'), findsOneWidget);
      expect(find.byKey(const ValueKey('volume-image-$other')), findsNothing);
      expect(repository.calls, [2, 3]);
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
      }
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .where((w) => w.image != null),
        hasLength(3),
      );
      await captureReview(tester, capture, 'volume-illustration-index');
      await tester.tap(find.byKey(const ValueKey('volume-image-$b')));
      await tester.pumpAndSettle();
      final gallery = tester.widget<ReaderIllustrationGallery>(
        find.byType(ReaderIllustrationGallery),
      );
      expect(gallery.urls, [a, b, c]);
      expect(gallery.initialUrl, b);
      expect(find.byKey(const ValueKey('book-image-save')), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'partial failure retains available images and retries only missing chapters',
    (tester) async {
      final repository = _Images()..fail = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: ReaderVolumeIllustrationsPage(
            novel: book,
            chapter: 0,
            repository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 IMAGES'), findsOneWidget);
      expect(find.byKey(const ValueKey('volume-images-retry')), findsOneWidget);
      repository.fail = false;
      await tester.tap(find.byKey(const ValueKey('volume-images-retry')));
      await tester.pumpAndSettle();
      expect(find.text('3 IMAGES'), findsOneWidget);
      expect(repository.calls.where((i) => i == 3), hasLength(2));
      expect(repository.calls.where((i) => i == 2), hasLength(1));
      expect(repository.calls, isNot(contains(4)));
      expect(find.byKey(const ValueKey('volume-images-retry')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
