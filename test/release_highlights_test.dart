import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/my_page.dart';
import 'package:wenku8_flutter/updates/app_updates.dart';
import 'package:wenku8_flutter/updates/release_highlights.dart';
import 'package:wenku8_flutter/updates/update_page.dart';
import 'support/visual_review.dart';

class _Platform implements UpdatePlatform {
  InstalledApp app = const InstalledApp(
    version: currentAppVersion,
    build: currentAppBuild,
    abis: ['arm64-v8a'],
  );
  @override
  Future<InstalledApp> installedApp() async => app;
  @override
  Future<void> allowInstalls() async {}
  @override
  Future<void> openRelease(Uri page) async {}
  @override
  Future<UpdatePackageInfo> inspect(File apk, String version, {int? build}) =>
      throw UnimplementedError();
  @override
  Future<String> install(File apk, String version, {int? build}) =>
      throw UnimplementedError();
}

class _Source implements UpdateSource {
  int downloads = 0;
  @override
  Future<AppRelease?> latest() async {
    final installed = ReleaseVersion.parse(currentAppVersion)!;
    final next = ReleaseVersion(
      installed.major,
      installed.minor,
      installed.patch + 1,
      currentAppBuild + 1,
    );
    return AppRelease(
      tag: 'v${next.name}',
      version: next,
      notes: 'next release',
      page: Uri.https(
        'github.com',
        '/example/reader/releases/tag/v${next.name}',
      ),
      assets: const [],
    );
  }

  @override
  Future<void> download(
    UpdateAsset asset,
    File file,
    UpdateDownload task,
    void Function(int) progress,
  ) async {
    downloads++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  late AppUpdates updates;
  late AppUpdateNavigation navigation;
  late _Platform platform;
  late _Source source;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    platform = _Platform();
    source = _Source();
    updates = AppUpdates(
      preferences: await SharedPreferences.getInstance(),
      platform: platform,
      source: source,
    );
    navigation = AppUpdateNavigation();
  });
  tearDown(() {
    updates.dispose();
    navigation.dispose();
  });
  Widget host({
    bool monitor = false,
    double scale = 1,
    Brightness brightness = Brightness.light,
    GlobalKey? capture,
  }) => RepaintBoundary(
    key: capture,
    child: MaterialApp(
      theme: novelTheme(brightness),
      navigatorObservers: [navigation],
      builder: (context, child) {
        final content = MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        );
        return monitor
            ? AppUpdateMonitor(
                updates: updates,
                navigation: navigation,
                child: content,
              )
            : content;
      },
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: CurrentReleaseCard(updates: updates),
            ),
          ),
        ),
      ),
    ),
  );
  Future<void> complete(WidgetTester tester) async {
    for (var page = 0; page < currentReleaseSections.length; page++) {
      expect(
        find.text('${page + 1}/${currentReleaseSections.length}'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('release-details-next')));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('My keeps notes in About and exposes no update-source controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = await LibraryState.load(), capture = GlobalKey();
    addTearDown(state.dispose);
    await updates.loadInstalled();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: novelTheme(Brightness.light),
          home: AppUpdatesScope(
            updates: updates,
            child: Scaffold(
              body: Atmosphere(
                child: MyPage(
                  state: state,
                  repository: const DemoNovelRepository(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CurrentReleaseCard), findsNothing);
    expect(find.text('本版更新'), findsNothing);
    await captureReview(tester, capture, 'my-without-release-card');
    await tester.ensureVisible(find.byKey(const ValueKey('my-about')));
    await tester.tap(
      find
          .descendant(
            of: find.byKey(const ValueKey('my-about')),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(CurrentReleaseCard), findsOneWidget);
    expect(find.byKey(const ValueKey('app-update-channel')), findsNothing);
    expect(
      find.byKey(const ValueKey('switch-app-update-channel')),
      findsNothing,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('view-current-release-details')),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();
    await captureReview(tester, capture, 'about-release-summary-phone');
    await tester.tap(
      find
          .descendant(
            of: find.byKey(const ValueKey('view-current-release-details')),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('installed-release-details')),
      findsOneWidget,
    );
    expect(find.text('下一页'), findsOneWidget);
    expect(find.text('上一页'), findsOneWidget);
    expect(find.text('下一步'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('release-details-next')));
    await tester.pumpAndSettle();
    expect(find.text(currentReleaseSections[1].title), findsOneWidget);
    await captureReview(tester, capture, 'my-release-ui-changes-phone');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'summary remains brief; manual details support next, previous, swipe and completion',
    (tester) async {
      await updates.loadInstalled();
      final capture = GlobalKey();
      await tester.pumpWidget(host(capture: capture));
      await tester.pumpAndSettle();
      expect(find.text(currentReleaseSections.first.title), findsNothing);
      for (final summary in currentReleaseSummary) {
        expect(find.text('· $summary'), findsOneWidget);
      }
      await tester.tap(
        find.byKey(const ValueKey('view-current-release-details')),
      );
      await tester.pumpAndSettle();
      await captureReview(tester, capture, 'release-details-features');
      await tester.tap(find.byKey(const ValueKey('release-details-next')));
      await tester.pumpAndSettle();
      expect(find.text('2/${currentReleaseSections.length}'), findsOneWidget);
      expect(find.text(currentReleaseSections[1].title), findsOneWidget);
      await captureReview(tester, capture, 'release-details-ui-moves');
      await tester.tap(find.byKey(const ValueKey('release-details-previous')));
      await tester.pumpAndSettle();
      expect(find.text('1/${currentReleaseSections.length}'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('release-details-pages')),
        const Offset(-650, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('2/${currentReleaseSections.length}'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('release-details-previous')));
      await tester.pumpAndSettle();
      await complete(tester);
      expect(
        find.byKey(const ValueKey('installed-release-details')),
        findsNothing,
      );
      expect(
        updates.preferences.getString('completedReleaseNotes'),
        '$currentAppVersion+$currentAppBuild',
      );
      expect(source.downloads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'installed notes take priority over a newer-release prompt, and completion survives foreground changes',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(host(monitor: true));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('installed-release-details')),
        findsOneWidget,
      );
      await updates.check();
      await tester.pumpAndSettle();
      expect(updates.available, true);
      expect(find.byKey(const ValueKey('app-update-prompt')), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('installed-release-details')),
        findsOneWidget,
      );
      expect(updates.preferences.getString('completedReleaseNotes'), isNull);
      await complete(tester);
      expect(find.byKey(const ValueKey('app-update-prompt')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('postpone-app-update')));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('installed-release-details')),
        findsNothing,
      );
      expect(source.downloads, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'same build stays completed; a new build presents notes even with online checking disabled',
    (tester) async {
      await updates.rememberReleaseNotes(platform.app);
      await updates.setAutoCheck(false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(host(monitor: true));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('installed-release-details')),
        findsNothing,
      );
      platform.app = const InstalledApp(
        version: currentAppVersion,
        build: currentAppBuild + 1,
        abis: ['arm64-v8a'],
      );
      await updates.loadInstalled(refresh: true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('installed-release-details')),
        findsOneWidget,
      );
      expect(
        updates.preferences.getString('completedReleaseNotes'),
        '$currentAppVersion+$currentAppBuild',
      );
      await complete(tester);
      expect(
        updates.preferences.getString('completedReleaseNotes'),
        '$currentAppVersion+${currentAppBuild + 1}',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final scene in [
    (
      name: 'compact-large',
      size: const Size(320, 640),
      scale: 2.0,
      brightness: Brightness.light,
    ),
    (
      name: 'landscape-dark',
      size: const Size(844, 390),
      scale: 1.0,
      brightness: Brightness.dark,
    ),
  ]) {
    testWidgets('${scene.name} sections scroll without obscuring navigation', (
      tester,
    ) async {
      tester.view.physicalSize = scene.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      await tester.pumpWidget(
        host(
          scale: scene.scale,
          brightness: scene.brightness,
          capture: capture,
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('view-current-release-details')),
      );
      await tester.tap(
        find.byKey(const ValueKey('view-current-release-details')),
      );
      await tester.pumpAndSettle();
      await captureReview(tester, capture, 'release-${scene.name}');
      for (var i = 0; i < currentReleaseSections.length; i++) {
        expect(
          find.byKey(const ValueKey('release-details-next')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('release-details-next')));
        await tester.pumpAndSettle();
      }
      expect(
        find.byKey(const ValueKey('installed-release-details')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
