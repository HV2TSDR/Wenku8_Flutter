import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/author_works_page.dart';
import 'package:wenku8_flutter/book_search.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/feature_pages.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/wenku_account.dart';
import 'feature_completion_state_test.dart' show profileXml;
import 'support/visual_review.dart';

const _book = Novel(
  id: 71,
  title: '午后的阅读档案',
  author: '某位作者',
  genre: '奇幻 女性视角',
  summary: '在书页间发现新的故事。',
  colors: [Color(0xff7186a2), Color(0xff303a4a)],
);

class _Books extends DemoNovelRepository {
  BookSearchField? requestedField;
  @override
  Future<Novel> detail(Novel novel) async => novel;
  @override
  Future<List<NovelChapter>> chapters(int id) async => const [
    NovelChapter('序章', '正文', id: 1),
  ];
  @override
  Future<NovelPage> searchFilteredPage(
    String query, {
    BookSearchField field = BookSearchField.all,
    int page = 1,
    bool refresh = false,
  }) async {
    requestedField = field;
    return NovelPage.fromItems([_book], page);
  }
}

void main() {
  setUpAll(loadReviewFonts);
  for (final profile in [
    (
      name: 'phone',
      size: const Size(390, 844),
      scale: 1.0,
      brightness: Brightness.light,
    ),
    (
      name: 'compact-large-dark',
      size: const Size(320, 700),
      scale: 1.4,
      brightness: Brightness.dark,
    ),
    (
      name: 'tablet',
      size: const Size(1280, 800),
      scale: 1.2,
      brightness: Brightness.light,
    ),
  ]) {
    testWidgets(
      'source filter, search field and connection form fit ${profile.name}',
      (tester) async {
        tester.view.physicalSize = profile.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({
          'reduceMotion': true,
          'shelfLayout': 'list',
          'combinedShelf': true,
        });
        final state = await LibraryState.load();
        addTearDown(state.dispose);
        await state.setShelfMembership(_book.id, true, novel: _book);
        final capture = GlobalKey();
        final repository = _Books();
        Future<void> mount(Widget child) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: novelTheme(profile.brightness),
              builder: (context, child) => RepaintBoundary(
                key: capture,
                child: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(profile.scale)),
                  child: child!,
                ),
              ),
              home: child,
            ),
          );
          await tester.pumpAndSettle();
        }

        await mount(
          Scaffold(
            body: ShelfPage(
              books: const [_book],
              state: state,
              repository: repository,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('shelf-view')));
        await tester.pumpAndSettle();
        expect(find.text('书籍来源'), findsOneWidget);
        await captureReview(tester, capture, '${profile.name}-source-filter');
        final local = find.widgetWithText(GlassTextButton, '本地导入');
        await tester.ensureVisible(local);
        await tester.pumpAndSettle();
        await tester.tap(local);
        await tester.pumpAndSettle();
        expect(state.shelfSourceFilter, 'local');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('shelf-view')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await mount(HomeShell(state: state, repository: repository));
        final search = find.byWidgetPredicate(
          (widget) => widget is GlassIconButton && widget.label == '搜索',
        );
        await tester.tap(
          find.descendant(of: search, matching: find.byType(InkWell)).first,
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('expanded-search-input')),
          '女性视角',
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('search-field-filter')));
        await tester.pumpAndSettle();
        await captureReview(tester, capture, '${profile.name}-search-filter');
        await tester.tap(find.widgetWithText(GlassMenuItem, '标签'));
        await tester.pumpAndSettle();
        expect(repository.requestedField, BookSearchField.tags);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('expanded-search-input')),
              )
              .decoration!
              .hintText,
          contains('女性视角'),
        );
        expect(tester.takeException(), isNull);
        final account = WenkuAccount(
          hasSession: () async => true,
          request: (_) async => profileXml,
          clearSession: () async {},
          publicationLogin: (_, _) async {},
        );
        addTearDown(account.dispose);
        await account.initialize();
        await mount(
          WenkuAccountPage(
            account: account,
            state: state,
            repository: repository,
          ),
        );
        expect(find.text('文库账号'), findsOneWidget);
        expect(find.byKey(const ValueKey('account-password')), findsNothing);
        expect(find.byKey(const ValueKey('account-username')), findsNothing);
        expect(find.text('连接分类'), findsNothing);
        await captureReview(tester, capture, '${profile.name}-shared-account');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets(
    'detail tag opens the same paged collection interaction as author works',
    (tester) async {
      SharedPreferences.setMockInitialValues({'reduceMotion': true});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final repository = _Books();
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          builder: (context, child) =>
              RepaintBoundary(key: capture, child: child),
          home: DetailPage(novel: _book, state: state, repository: repository),
        ),
      );
      await tester.pumpAndSettle();
      final tag = find.byKey(const ValueKey('detail-tag-女性视角'));
      await tester.ensureVisible(tag);
      await tester.pumpAndSettle();
      await tester.tap(tag);
      await tester.pumpAndSettle();
      expect(find.byType(TagWorksPage), findsOneWidget);
      expect(find.text('标签书单'), findsOneWidget);
      expect(repository.requestedField, BookSearchField.tags);
      await captureReview(tester, capture, 'tag-book-list');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
