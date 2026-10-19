import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/backup_page.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/cloud_library_page.dart';
import 'package:wenku8_flutter/cloud_sources.dart';
import 'package:wenku8_flutter/legacy_import_page.dart';
import 'package:wenku8_flutter/legacy_transport.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/custom_tts.dart';
import 'package:wenku8_flutter/listening/custom_tts_page.dart';
import 'package:wenku8_flutter/listening/store.dart';
import 'package:wenku8_flutter/low_performance_page.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_book_layout.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reading_history.dart';
import 'package:wenku8_flutter/updates/update_page.dart';

import 'cloud_sources_test.dart' show MemoryCloudVault;
import 'support/listening_fixture.dart';
import 'support/visual_review.dart';

class _SpeechVault implements SpeechConfigStorage {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String? value) async {}
}

Future<Uint8List> _picture(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFB9CDC8),
  );
  // A complete inset frame makes cropping and letterboxing visible in captures.
  canvas.drawRect(
    Rect.fromLTWH(5, 5, width - 10, height - 10),
    Paint()
      ..color = const Color(0xFF374943)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4,
  );
  canvas.drawLine(
    Offset.zero,
    Offset(width.toDouble(), height.toDouble()),
    Paint()
      ..color = const Color(0xFFF1EDE2)
      ..strokeWidth = 8,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final bytes = Uint8List.fromList(data.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return bytes;
}

void main({
  bool native = false,
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!native) setUpAll(loadReviewFonts);
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
      'reduceMotion': true,
    }),
  );

  Future<GlobalKey> mount(
    WidgetTester tester,
    Widget page, {
    bool compact = false,
  }) async {
    tester.view.physicalSize = Size(compact ? 320 : 390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(compact ? Brightness.dark : Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(compact ? 1.4 : 1)),
            child: child!,
          ),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    if (capture != null) {
      await capture(tester, key, name);
    } else {
      await captureReview(tester, key, name);
    }
  }

  Future<void> decode(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
  }

  for (final compact in [false, true]) {
    testWidgets(
      '${compact ? 'compact' : 'phone'} all settings destinations center their actual title',
      (tester) async {
        final library = await LibraryState.load();
        final cloud = CloudSourceSettings(storage: MemoryCloudVault());
        final speech = CustomSpeechSettings(storage: _SpeechVault());
        final listening = ListeningController(
          repository: const DemoNovelRepository(),
          audio: FakeSpeechAudio(),
          store: ListeningStore(await SharedPreferences.getInstance()),
          outputFactory: (_) async => FakeListeningOutput(),
        );
        addTearDown(library.dispose);
        addTearDown(cloud.dispose);
        addTearDown(speech.dispose);
        final pages = <(String, Widget)>[
          ('备份与恢复', LibraryBackupPage(state: library)),
          ('低性能设备模式', LowPerformancePage(state: library)),
          ('关于轻小说文库', const AppUpdatePage()),
          ('导入旧版记录', LegacyImportPage(state: library)),
          (
            '阅读历史',
            ReadingHistoryPage(
              state: library,
              repository: const DemoNovelRepository(),
              onOpen: (_, _, _) {},
            ),
          ),
          (
            '自定义语音接口',
            CustomSpeechPage(settings: speech, controller: listening),
          ),
          (
            '网盘导入',
            CloudLibraryPage(
              settings: cloud,
              onImport: (_, _) async => throw UnimplementedError(),
            ),
          ),
        ];
        for (final (name, page) in pages) {
          final key = await mount(tester, page, compact: compact);
          final title = find.descendant(
            of: find.byType(ArchiveHeaderBar),
            matching: find.text(name),
          );
          expect(
            tester.getCenter(title).dx,
            closeTo((compact ? 320 : 390) / 2, .1),
            reason: name,
          );
          final text = tester.getRect(title);
          final back = tester.getRect(find.byType(GlassIconButton).first);
          expect(text.left, greaterThanOrEqualTo(back.right + 6), reason: name);
          expect(tester.takeException(), isNull, reason: name);
          if (name == '低性能设备模式' || (compact && name == '自定义语音接口')) {
            await shot(
              tester,
              key,
              'route-${pages.indexOf((name, page))}-${compact ? 'compact' : 'phone'}',
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
        final closing = listening.dispose();
        await tester.runAsync(() => closing);
      },
    );
  }

  testWidgets('asymmetric header actions do not shift or overlap the title', (
    tester,
  ) async {
    final key = await mount(
      tester,
      Scaffold(
        body: Atmosphere(
          child: GlassHeaderLayout(
            header: ArchiveHeaderBar(
              leading: GlassIconButton(
                icon: CupertinoIcons.back,
                label: '返回',
                onPressed: () {},
              ),
              title: const ArchiveRouteTitle(
                title: '图书详情',
                code: 'FILE / 001305',
              ),
              actions: [
                GlassIconButton(
                  icon: CupertinoIcons.cloud_download,
                  label: '缓存',
                  onPressed: () {},
                ),
                GlassIconButton(
                  icon: CupertinoIcons.bookmark,
                  label: '收藏',
                  onPressed: () {},
                ),
              ],
            ),
            body: const SizedBox.expand(),
          ),
        ),
      ),
      compact: true,
    );
    final title = tester.getRect(find.text('图书详情'));
    expect(title.center.dx, closeTo(160, .1));
    final buttons = find.byType(GlassIconButton);
    expect(title.left, greaterThan(tester.getRect(buttons.at(0)).right));
    expect(title.right, lessThan(tester.getRect(buttons.at(1)).left));
    await shot(tester, key, 'route-asymmetric-compact');
    expect(tester.takeException(), isNull);
  });

  for (final (name, width, height) in [
    ('wide', 480, 240),
    ('tall', 240, 600),
  ]) {
    testWidgets(
      '$name inline illustration fills its real text column without cropping',
      (tester) async {
        final bytes = (await tester.runAsync(() => _picture(width, height)))!;
        final cache = ReaderIllustrationCache(request: (_) async => bytes);
        final key = await mount(
          tester,
          Scaffold(
            body: SingleChildScrollView(
              child: Center(
                child: SizedBox(
                  width: 260,
                  child: ReaderIllustration(url: 'fixture:$name', cache: cache),
                ),
              ),
            ),
          ),
        );
        await decode(tester);
        final image = find.byType(Image);
        expect(image, findsOneWidget);
        expect(tester.getSize(image).width, closeTo(260, .1));
        expect(tester.getSize(image).height, closeTo(260 * height / width, .1));
        expect(tester.widget<Image>(image).fit, BoxFit.contain);
        expect(
          cache.sizeOf('fixture:$name'),
          Size(width.toDouble(), height.toDouble()),
        );
        await shot(tester, key, 'illustration-$name-inline');
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
    testWidgets(
      '$mode reader illustration and missing slot fit the entire leaf',
      (tester) async {
        final bytes = (await tester.runAsync(() => _picture(240, 600)))!;
        final library = await LibraryState.load();
        addTearDown(library.dispose);
        await library.setReaderPreferences(ReaderPreferences(mode: mode));
        ReaderIllustrationCache.shared.clearMemory();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          LegacyTransport.channel,
          (call) async => call.method == 'illustration' ? bytes : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            LegacyTransport.channel,
            null,
          ),
        );
        for (final missing in [false, true]) {
          final novel = Novel(
            id: 71071,
            title: '插图阅读',
            author: '',
            genre: '',
            summary: '',
            colors: const [Colors.black, Colors.grey],
            chapters: [
              NovelChapter(
                '插图',
                missing
                    ? '[插图]'
                    : '<!--image-->https://pic.wenku8.cn/pictures/layout-test.png<!--image-->',
                id: 7107101,
              ),
            ],
          );
          final key = await mount(
            tester,
            ReaderPage(
              novel: novel,
              state: library,
              repository: const DemoNovelRepository(),
              initialChapter: 0,
            ),
          );
          for (var i = 0; i < 60; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            final paged = find.byType(ReaderPagedView);
            if (paged.evaluate().isNotEmpty &&
                tester.widget<ReaderPagedView>(paged).controller.ready) {
              break;
            }
          }
          await decode(tester);
          final slot = tester.getRect(
            find.byType(ReaderIllustrationFrame).first,
          );
          final leaf = tester
              .widget<ReaderBookSpread>(find.byType(ReaderBookSpread).first)
              .layout
              .pages
              .first
              .size;
          expect(slot.size.width, closeTo(leaf.width, .1));
          expect(slot.size.height, closeTo(leaf.height, .1));
          expect(tester.getCenter(find.text('插图阅读')).dx, closeTo(195, .1));
          if (!missing) {
            await shot(tester, key, 'illustration-reader-${mode.name}');
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
    );
  }

  testWidgets(
    'image change drops the old frame and retry evicts only its own image',
    (tester) async {
      final bytes = (await tester.runAsync(() => _picture(240, 360)))!;
      final pending = Completer<Uint8List>();
      var retries = 0;
      final cache = ReaderIllustrationCache(
        request: (url) async {
          if (url == 'fixture:next') return pending.future;
          if (url == 'fixture:broken' && retries++ == 0) {
            return Uint8List.fromList([1, 2, 3]);
          }
          return bytes;
        },
      );
      Widget page(String url) => Scaffold(
        body: Center(
          child: SizedBox(
            width: 220,
            height: 340,
            child: ReaderIllustration(
              key: const ValueKey('reused-image'),
              url: url,
              cache: cache,
              fitPage: true,
            ),
          ),
        ),
      );
      final url = ValueNotifier('fixture:first');
      addTearDown(url.dispose);
      await mount(
        tester,
        ValueListenableBuilder<String>(
          valueListenable: url,
          builder: (context, value, _) => page(value),
        ),
      );
      await decode(tester);
      expect(find.byType(Image), findsOneWidget);
      url.value = 'fixture:next';
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.byType(LoadingSkeleton), findsOneWidget);
      pending.complete(bytes);
      await decode(tester);
      url.value = 'fixture:broken';
      await tester.pump();
      await decode(tester);
      expect(find.text('插图加载失败'), findsOneWidget);
      await tester.tap(find.text('重试插图'));
      await decode(tester);
      expect(find.byType(Image), findsOneWidget);
      expect(cache.peek('fixture:first'), same(bytes));
      expect(retries, 2);
      expect(tester.takeException(), isNull);
    },
  );

  if (native) {
    testWidgets(
      'live chapter illustration occupies its full width at native render',
      (tester) async {
        final repository = LegacyWenkuRepository();
        final chapters = await repository.chapters(1305);
        final chapter = chapters.firstWhere((c) => c.title.contains('插图'));
        final content = await ReaderContent.parse(
          await repository.chapterContent(1305, chapter),
        );
        expect(content.illustrations, isNotEmpty);
        expect(content.paragraphs.where((p) => p.trim() == '[插图]'), isEmpty);
        final key = await mount(
          tester,
          ReaderIllustrationGallery(
            urls: content.illustrations,
            initialUrl: content.illustrations.first,
          ),
        );
        for (var i = 0; i < 120 && find.byType(Image).evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(find.byType(Image), findsWidgets);
        expect(find.text('插图加载失败'), findsNothing);
        expect(tester.getCenter(find.text('章节插图')).dx, closeTo(195, .1));
        await shot(tester, key, 'illustration-live-gallery');
        debugPrint(
          'LIVE_ILLUSTRATION_LAYOUT_OK book=1305 cid=${chapter.id} images=${content.illustrations.length}',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
