import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/app_search_field.dart';
import 'package:wenku8_flutter/archive_carousel.dart';
import 'package:wenku8_flutter/author_works_page.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'package:wenku8_flutter/book_import_limits.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/font_settings_page.dart';
import 'package:wenku8_flutter/frame_rate_settings.dart';
import 'package:wenku8_flutter/glass_choices.dart';
import 'package:wenku8_flutter/legacy_transport.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_scan_page.dart';
import 'package:wenku8_flutter/local_scan_selection.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/review_pages.dart';
import 'package:wenku8_flutter/wenku_account.dart';
import 'support/visual_review.dart';

class _Catalogue extends DemoNovelRepository {
  final books = List.generate(
    80,
    (i) => Novel(
      id: i + 1,
      title: '书籍 ${i + 1}',
      author: '作者',
      genre: i.isEven ? '奇幻 冒险' : '奇幻',
      summary: '',
      colors: const [Colors.grey, Colors.black],
    ),
  );
  @override
  Future<List<Novel>> list() async => books;
  @override
  Future<List<Novel>> search(String query) async => books;
}

class _Documents extends BookDocuments {
  BookScanFolder? folder;
  Set<String> formats = bookFormatLabels.keys.toSet();
  @override
  Future<BookScanFolder?> scanFolderInfo() async => folder;
  @override
  Future<Set<String>> scanFormats() async => formats;
  @override
  Future<void> setScanFormats(Set<String> value) async {
    formats = value;
  }

  @override
  Future<BookScanFolder?> selectScanFolder() async => folder =
      const BookScanFolder(name: '书籍文件夹', automatic: false, readable: true);
}

Finder action(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (w) => w is GlassIconButton && w.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadReviewFonts();
    await (FontLoader('SourceHanSerifCN')..addFont(
          rootBundle.load('assets/fonts/SourceHanSerifCN-Regular.otf'),
        ))
        .load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({'reduceMotion': true}));
  void phone(WidgetTester tester, {double scale = 1}) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  Widget app(Widget child, GlobalKey capture) => RepaintBoundary(
    key: capture,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: novelTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: child,
    ),
  );

  testWidgets(
    'multiple tags filter discovery in place and retain its 3D shelf',
    (tester) async {
      phone(tester);
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final capture = GlobalKey();
      await tester.pumpWidget(
        app(HomeShell(state: state, repository: _Catalogue()), capture),
      );
      await tester.pumpAndSettle();
      await tester.tap(action('分类与排序'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('标签'));
      await tester.pumpAndSettle();
      for (final tag in ['奇幻', '冒险']) {
        await tester.tap(find.byKey(ValueKey('discover-tag-$tag')));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const ValueKey('discover-tags-apply')), findsOneWidget);
      await captureReview(tester, capture, 'discovery-multiple-tags');
      await tester.ensureVisible(
        find.byKey(const ValueKey('discover-tags-apply')),
      );
      await tester.tap(find.byKey(const ValueKey('discover-tags-apply')));
      await tester.pumpAndSettle();
      expect(find.byType(TagWorksPage), findsNothing);
      final discover = tester.widget<DiscoverPage>(find.byType(DiscoverPage));
      expect(discover.feed!.tags.toSet(), {'奇幻', '冒险'});
      expect(discover.feed!.items.length, 20);
      expect(
        discover.feed!.items.every(
          (book) => book.tags.contains('奇幻') && book.tags.contains('冒险'),
        ),
        true,
      );
      expect(find.byType(ArchiveFileCarousel), findsOneWidget);
      await captureReview(tester, capture, 'discovery-filtered-shelf');
      expect(tester.takeException(), isNull);
    },
  );

  String item(int id) =>
      '<item aid="$id"><data name="Title" value="作品$id"/><data name="Author" value="作者"/><data name="Tags" value="奇幻${id.isEven ? ' 冒险' : ''}"/></item>';
  test(
    'capped multi-tag intersections fill complete pages without dropping matches',
    () async {
      final calls = <String>[];
      final source = LegacyWenkuRepository(
        request: (action) async {
          calls.add(action);
          final args = Uri.splitQueryString(action);
          if (args['action'] == 'search') {
            return '<result>${List.generate(20, (i) => item(args['searchkey'] == '冒险' ? (i + 1) * 2 : i + 1)).join()}</result>';
          }
          expect(args['action'], 'novellist');
          final page = int.parse(args['page']!);
          return '<result><page num="8"/>${List.generate(10, (i) => item((page - 1) * 10 + i + 1)).join()}</result>';
        },
      );
      final first = await source.tagPage('奇幻 冒险');
      final second = await source.tagPage('奇幻 冒险', page: 2);
      expect(
        first.items.map((b) => b.id),
        List.generate(20, (i) => (i + 1) * 2),
      );
      expect(
        second.items.map((b) => b.id),
        List.generate(20, (i) => (i + 21) * 2),
      );
      expect(second.hasMore, false);
      expect(calls.where((c) => c.startsWith('action=search')).length, 2);
    },
  );
  test(
    'an uncapped tag seed resolves intersections without scanning the catalogue',
    () async {
      final calls = <String>[];
      final source = LegacyWenkuRepository(
        request: (action) async {
          calls.add(action);
          expect(action, startsWith('action=search'));
          return '<result>${Uri.splitQueryString(action)['searchkey'] == '冒险' ? item(2) : List.generate(20, (i) => item(i + 1)).join()}</result>';
        },
      );
      final result = await source.tagPage('奇幻 冒险');
      expect(result.items.single.id, 2);
      expect(result.hasMore, false);
      expect(calls.length, 2);
    },
  );

  testWidgets('unselected choices have no invisible checkmark gutter', (
    tester,
  ) async {
    phone(tester);
    final capture = GlobalKey();
    await tester.pumpWidget(
      app(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: GlassChoiceGroup<String>(
              name: 'choice',
              label: '选择榜单',
              value: 'one',
              options: const {'one': '最近更新', 'two': '总人气'},
              onChanged: (_) {},
            ),
          ),
        ),
        capture,
      ),
    );
    await tester.pumpAndSettle();
    final unselected = find.byKey(const ValueKey('choice-two'));
    expect(
      find.descendant(of: unselected, matching: find.byType(Icon)),
      findsNothing,
    );
    final gap =
        tester.getRect(unselected).right -
        tester.getRect(find.text('总人气')).right;
    expect(gap, lessThanOrEqualTo(9));
    await captureReview(tester, capture, 'compact-glass-choices');
  });

  testWidgets('shared search is borderless, clears and fits large text', (
    tester,
  ) async {
    phone(tester, scale: 2);
    final capture = GlobalKey(), text = TextEditingController();
    addTearDown(text.dispose);
    final changed = <String>[];
    await tester.pumpWidget(
      app(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: AppSearchField(
              inputKey: const ValueKey('shared-search'),
              controller: text,
              hint: '搜索书名、作者',
              onChanged: changed.add,
            ),
          ),
        ),
        capture,
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('shared-search')), '奇幻');
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('shared-search')),
    );
    expect(field.decoration!.filled, false);
    expect(field.decoration!.focusedBorder, InputBorder.none);
    expect(field.textInputAction, TextInputAction.search);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(text.text, '');
    expect(changed.last, '');
    expect(tester.takeException(), isNull);
    await captureReview(tester, capture, 'shared-search-large-text');
  });

  testWidgets('scan chooses format before asking for a folder or starting', (
    tester,
  ) async {
    phone(tester);
    final docs = _Documents(),
        changes = ValueNotifier(0),
        capture = GlobalKey();
    addTearDown(changes.dispose);
    Set<String>? scanned;
    await tester.pumpWidget(
      app(
        LocalScanPage(
          documents: docs,
          changes: changes,
          isBusy: () => false,
          progress: () => null,
          result: () => null,
          failure: () => null,
          onScan: (_) async {
            scanned = {...docs.formats};
          },
        ),
        capture,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('scan-format-epub')));
    await tester.pumpAndSettle();
    expect(docs.formats, {'epub'});
    expect(scanned, isNull);
    await captureReview(tester, capture, 'scan-format-before');
    await tester.ensureVisible(
      find.byKey(const ValueKey('scan-select-folder')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('scan-select-folder')));
    await tester.pumpAndSettle();
    expect(scanned, {'epub'});
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scan filters format and filename while retaining hidden selections',
    (tester) async {
      phone(tester);
      final capture = GlobalKey();
      const snapshot = BookScanSnapshot(
        books: [
          (token: 'a', name: '星光 第一卷.epub'),
          (token: 'b', name: '星光 第二卷.EPUB'),
          (token: 'c', name: '日常.txt'),
          (token: 'd', name: '冒险.mobi'),
        ],
        details: {
          'a': (size: 100000, folder: '下载/书籍'),
          'b': (size: 200000, folder: '下载/书籍'),
        },
      );
      await tester.pumpWidget(
        app(LocalScanSelection(snapshot: snapshot), capture),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scan-filter-epub')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('scan-candidate-search')),
        '第一卷',
      );
      await tester.pumpAndSettle();
      expect(find.text('显示 1 / 4 个文件 · 已选 0 个'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scan-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('导入 1 个文件'), findsOneWidget);
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      expect(find.text('显示 2 / 4 个文件 · 已选 1 个'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scan-filter-all')));
      await tester.pumpAndSettle();
      expect(find.text('显示 4 / 4 个文件 · 已选 1 个'), findsOneWidget);
      await captureReview(tester, capture, 'scan-results-search');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'frame-rate choices use supported rates and persist the request',
    (tester) async {
      phone(tester);
      const channel = MethodChannel('polish51/frame-rate');
      var target = 0.0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'set') {
              target = (call.arguments['target'] as num).toDouble();
            }
            return {
              'target': target,
              'current': target > 0 ? target : 120,
              'rates': [60.0, 90.0, 120.0],
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final settings = FrameRateSettings(channel: channel),
          capture = GlobalKey();
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        app(
          Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(24),
              children: [FrameRateOptions(settings: settings)],
            ),
          ),
          capture,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('frame-rate-90.0')));
      await tester.pumpAndSettle();
      expect(settings.info!.target, 90);
      expect(find.text('屏幕模式 90 Hz'), findsOneWidget);
      expect(find.text('144 Hz'), findsNothing);
      await captureReview(tester, capture, 'frame-rate-options');
      await tester.tap(find.byKey(const ValueKey('frame-rate--1.0')));
      await tester.pumpAndSettle();
      expect(target, -1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('font choices show compact real samples in one glass language', (
    tester,
  ) async {
    phone(tester);
    final state = await LibraryState.load(), capture = GlobalKey();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      app(FontSettingsPage(state: state, readerOnly: true), capture),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-font-system')), findsOneWidget);
    await captureReview(tester, capture, 'reader-font-choices');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'comment publishing uses existing account once and preserves failed drafts',
    (tester) async {
      phone(tester);
      final capture = GlobalKey();
      var reply = Completer<String>();
      final writes = <String>[];
      final account =
          WenkuAccount(
              request: (action) {
                writes.add(action);
                return reply.future;
              },
            )
            ..authenticated = true
            ..profile = const WenkuProfile(
              id: 51,
              username: 'fixture',
              nickname: '读者',
              score: 0,
              experience: 0,
              rank: '读者',
            );
      addTearDown(account.dispose);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            LegacyTransport.channel,
            (call) async => call.method == 'encodeReview'
                ? base64Encode(
                    utf8.encode(
                      Uri.encodeComponent(call.arguments['text'] as String),
                    ),
                  )
                : null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LegacyTransport.channel, null),
      );
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              child: const Text('打开评论'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ReviewComposerPage(
                    novel: demoNovels.first,
                    account: account,
                    reduceMotion: true,
                  ),
                ),
              ),
            ),
          ),
          capture,
        ),
      );
      await tester.tap(find.text('打开评论'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('review-title')),
        '一篇读后感',
      );
      await tester.enterText(
        find.byKey(const ValueKey('review-body')),
        '这一段故事写得非常细腻，让人记住了人物的选择。',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await captureReview(tester, capture, 'comment-composer');
      await tester.tap(find.byKey(const ValueKey('review-submit')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('review-submit')));
      await tester.pumpAndSettle();
      expect(writes.length, 1);
      expect(writes.single, startsWith('action=review&do=post&aid='));
      reply.complete('11');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('review-body')), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'review_draft_51_${demoNovels.first.id}_0_body',
        ),
        contains('这一段故事'),
      );
      reply = Completer<String>();
      await tester.tap(find.byKey(const ValueKey('review-submit')));
      await tester.pumpAndSettle();
      expect(writes.length, 2);
      reply.complete('1');
      await tester.pumpAndSettle();
      expect(find.byType(ReviewComposerPage), findsNothing);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'review_draft_51_${demoNovels.first.id}_0_body',
        ),
        isNull,
      );
    },
  );
}
