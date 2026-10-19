import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'package:wenku8_flutter/book_sync.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/legacy_cover.dart';
import 'package:wenku8_flutter/listening/custom_tts.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/pages.dart' show ReaderPage;
import 'package:wenku8_flutter/reader_chrome.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/updates/app_updates.dart';

Future<void> checkpoint(WidgetTester tester, String name) async {
  debugPrint('NATIVE_KEYBOARD_CHECK=major-030-$name');
  await tester.pump(const Duration(milliseconds: 800));
}

Finder button(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (w) => w is GlassIconButton && w.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;
ScrollableState article(WidgetTester tester) => tester.state<ScrollableState>(
  find
      .descendant(
        of: find.byKey(const ValueKey('reader-scroll')),
        matching: find.byType(Scrollable),
      )
      .first,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native local book reader, fading glass and return flight', (
    tester,
  ) async {
    await NativeEffects.prepare();
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    final folder = await Directory(
      '${(await getTemporaryDirectory()).path}/major-reader-check',
    ).create(recursive: true);
    final books = LocalBookStore(Directory('${folder.path}/books'));
    await books.load();
    final body = [
      for (var v = 1; v <= 2; v++) ...[
        '第${v == 1 ? '一' : '二'}卷 远方的档案',
        for (var c = 1; c <= 2; c++) ...[
          '第${c == 1 ? '一' : '二'}章 风经过图书馆',
          for (var p = 0; p < 60; p++)
            '她把书签留在了第 ${p + 1} 段。窗外的雨渐渐停了，淡淡的光落在书页上。我们继续向前，故事还没有结束。',
        ],
      ],
    ].join('\n');
    final book = await books.import(
      LocalBookInput(
        '远方的档案.txt',
        Uint8List.fromList(utf8.encode(body)),
        text: body,
      ),
    );
    await state.setShelfMembership(book.id, true, novel: book);
    final cache = OfflineCacheStore(Directory('${folder.path}/network'));
    final repository = OfflineNovelRepository(
      remote: const DemoNovelRepository(),
      cache: cache,
      local: books,
    );
    await tester.pumpWidget(NovelApp(state: state, repository: repository));
    await tester.pumpAndSettle();
    final info = await AndroidUpdatePlatform().installedApp();
    expect(info.version, '0.3.0');
    expect(info.build, 7);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('dock-tab-1'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('远方的档案').last);
    await tester.pumpAndSettle();
    await checkpoint(tester, 'detail-volumes');
    final timings = <FrameTiming>[];
    void sample(List<FrameTiming> batch) => timings.addAll(batch);
    WidgetsBinding.instance.addTimingsCallback(sample);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    WidgetsBinding.instance.removeTimingsCallback(sample);
    debugPrint(
      'DETAIL_RETURN_FRAME_US=${jsonEncode([
        for (final t in timings) {'ui': t.buildDuration.inMicroseconds, 'raster': t.rasterDuration.inMicroseconds},
      ])}',
    );
    await checkpoint(tester, 'return-shelf');
    await tester.tap(find.text('远方的档案').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('detail-read-button')));
    await tester.pumpAndSettle();
    await checkpoint(tester, 'reader-controls');
    await tester.tapAt(const Offset(210, 300));
    await tester.pump(const Duration(milliseconds: 30));
    final animation =
        tester
                .widget<ReaderChromeLayer>(
                  find.byKey(const ValueKey('reader-chrome-header')),
                )
                .animation
            as AnimationController;
    animation.stop();
    animation.value = .55;
    await tester.pump();
    await checkpoint(tester, 'reader-fade-half');
    animation.value = .15;
    await tester.pump();
    await checkpoint(tester, 'reader-fade-low');
    animation.value = 0;
    await tester.pump();
    expect(find.byType(ReaderEdgeBlur), findsNothing);
    await checkpoint(tester, 'reader-focus');
    await tester.tapAt(const Offset(210, 300));
    await tester.pumpAndSettle();
    await tester.tap(button('阅读设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-paper-parchment')));
    await tester.pumpAndSettle();
    final font = tester.widget<AppGlassSlider>(
      find.byKey(const ValueKey('reader-font-slider')),
    );
    font.onChangeStart!(font.value);
    font.onChanged!(22);
    await tester.pump();
    await checkpoint(tester, 'reader-typography-preview');
    font.onChangeEnd!(22);
    await tester.pumpAndSettle();
    await tester.tap(find.text('操作'));
    await tester.pumpAndSettle();
    await checkpoint(tester, 'reader-tools-actions');
    await tester.tap(find.byKey(const ValueKey('reader-auto-scroll-start')));
    await tester.pump(const Duration(milliseconds: 600));
    final before = article(tester).position.pixels;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(article(tester).position.pixels, greaterThan(before));
    await tester.tapAt(const Offset(210, 300));
    await tester.pumpAndSettle();
    await state.setReaderPreferences(
      state.readerPreferences.copyWith(volumePaging: true, brightness: .6),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    repository.dispose();
    cache.dispose();
    books.dispose();
    state.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'native charcoal appearance across shelf menu settings detail and reader',
    (tester) async {
      await NativeEffects.prepare();
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      await state.setTheme(ThemeMode.dark);
      final cover = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      for (final book in demoNovels) {
        LegacyCover.seedLocalBytes(book.id, cover);
        await state.setShelfMembership(book.id, true, novel: book);
      }
      await tester.pumpWidget(
        NovelApp(state: state, repository: const DemoNovelRepository()),
      );
      await tester.pumpAndSettle();
      await checkpoint(tester, 'charcoal-discover');
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('dock-tab-1'))),
      );
      await tester.pumpAndSettle();
      await tester.tap(button('书架排序'));
      await tester.pumpAndSettle();
      await checkpoint(tester, 'charcoal-menu');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('dock-tab-2'))),
      );
      await tester.pumpAndSettle();
      await checkpoint(tester, 'charcoal-settings');
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('dock-tab-1'))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(demoNovels.first.title).last);
      await tester.pumpAndSettle();
      await checkpoint(tester, 'charcoal-detail');
      await tester.tap(find.byKey(const ValueKey('detail-read-button')));
      await tester.pumpAndSettle();
      await checkpoint(tester, 'charcoal-reader');
      await tester.tap(button('阅读设置'));
      await tester.pumpAndSettle();
      await checkpoint(tester, 'charcoal-tools');
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'native light paper retains dark status icons inside charcoal appearance',
    (tester) async {
      await NativeEffects.prepare();
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      await state.setReaderPreferences(
        const ReaderPreferences(paper: ReaderPaper.parchment),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.dark),
          home: ReaderPage(
            novel: demoNovels.first,
            state: state,
            repository: const DemoNovelRepository(),
            initialChapter: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await checkpoint(tester, 'charcoal-parchment');
      final style = tester
          .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
            find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
          )
          .value;
      expect(style.statusBarIconBrightness, Brightness.dark);
      final titleContext = tester.element(find.text(demoNovels.first.title));
      expect(Theme.of(titleContext).brightness, Brightness.light);
      expect(
        DefaultTextStyle.of(titleContext).style.color!.computeLuminance(),
        lessThan(.2),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'native document decoding and device-bound speech configuration',
    (tester) async {
      final documents = BookDocuments();
      final root = await Directory(
        '${(await getTemporaryDirectory()).path}/book-documents',
      ).create(recursive: true);
      final file = File('${root.path}/import-source');
      await file.writeAsBytes([0xd6, 0xd0, 0xce, 0xc4]);
      expect(await documents.decodeText(file.path), '中文');
      await file.writeAsBytes([0xff, 0xfe, 0x2d, 0x4e, 0x87, 0x65]);
      expect(await documents.decodeText(file.path), '中文');
      final settings = CustomSpeechSettings();
      final config = CustomSpeechConfig(
        endpoint: Uri.parse('https://example.test/cognitiveservices/v1'),
        voiceId: 'zh-CN-XiaoxiaoNeural',
        namespace: 'native-test',
        authentication: SpeechAuthentication.subscriptionKey,
        secret: 'fixture-only-not-a-real-key',
      );
      await settings.save(config);
      final readback = CustomSpeechSettings();
      await readback.load();
      expect(readback.config!.secret, config.secret);
      expect(readback.config!.voice.source.name, 'custom');
      await settings.save(null);
      settings.dispose();
      readback.dispose();
    },
  );

  testWidgets('native SAF sync document is read merged written and read back', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('文库云文档同步验证'))),
      ),
    );
    final documents = BookDocuments();
    final connect = documents.connect(create: true);
    await tester.pump(const Duration(seconds: 2));
    debugPrint('NATIVE_CREATE_SYNC=save-new-document');
    final connection = await tester.runAsync(
      () => connect.timeout(const Duration(seconds: 45)),
    );
    expect(connection, isNotNull);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final state = LibraryState(prefs);
    final books = LocalBookStore(
      Directory('${(await getTemporaryDirectory()).path}/sync-native-books'),
    );
    await books.load();
    final input = LocalBookInput(
      '同步验证.txt',
      Uint8List.fromList(utf8.encode('第一章\n原书正文。')),
      text: '第一章\n原书正文。',
    );
    final book = await books.import(input);
    await state.setShelfMembership(book.id, true, novel: book);
    final sync = BookSync(
      books: books,
      state: state,
      preferences: prefs,
      documents: documents,
    );
    await sync.load();
    await sync.sync();
    expect(sync.error, isNull);
    expect(sync.lastSync, isNotNull);
    final read = await documents.read();
    final bundle = decodeBookSync(await read.before.readAsBytes());
    expect(bundle.books.single.name, '同步验证.txt');
    await documents.disconnect();
    sync.dispose();
    books.dispose();
    state.dispose();
  });
}
