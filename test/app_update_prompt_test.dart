import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/updates/app_updates.dart';
import 'package:wenku8_flutter/updates/update_page.dart';

const _captureDirectory = String.fromEnvironment('UPDATE_PROMPT_CAPTURE');
const _captureKey = ValueKey('update-prompt-render');

AppRelease _release([String tag = 'v0.3.2']) => AppRelease(
  tag: tag,
  version: ReleaseVersion.parse(tag)!,
  notes: currentReleaseNotes,
  page: Uri.parse('https://github.com/example/reader/releases/tag/$tag'),
  assets: [
    UpdateAsset(
      name: 'wenku8-0.3.2-arm64-v8a.apk',
      url: Uri.parse(
        'https://github.com/example/reader/releases/download/$tag/wenku8-0.3.2-arm64-v8a.apk',
      ),
      size: 3,
    ),
  ],
);

AppRelease _withLongNotes(AppRelease release) => AppRelease(
  tag: release.tag,
  version: release.version,
  notes: List.filled(12, '阅读器支持上下滚动、横排翻页与竖排翻页，大屏自动对页阅读，窗口变化保留阅读位置。').join('\n'),
  page: release.page,
  assets: release.assets,
);

class _Source implements UpdateSource {
  AppRelease? release = _release();
  Completer<void>? pending;
  int downloads = 0;
  bool fail = false;

  @override
  Future<AppRelease?> latest() async {
    if (pending != null) await pending!.future;
    if (fail) throw const SocketException('offline');
    return release;
  }

  @override
  Future<void> download(
    UpdateAsset asset,
    File file,
    UpdateDownload task,
    void Function(int) progress,
  ) async {
    downloads++;
    await file.writeAsBytes([1, 2, 3]);
    progress(3);
  }
}

class _Platform implements UpdatePlatform {
  int installs = 0;
  InstalledApp app = const InstalledApp(
    version: '0.3.1',
    build: 30,
    abis: ['arm64-v8a'],
  );

  @override
  Future<InstalledApp> installedApp() async => app;
  @override
  Future<UpdatePackageInfo> inspect(
    File apk,
    String version, {
    int? build,
  }) async => UpdatePackageInfo(version: version, build: build ?? 31);
  @override
  Future<String> install(File apk, String version, {int? build}) async {
    installs++;
    return 'opened';
  }

  @override
  Future<void> allowInstalls() async {}
  @override
  Future<void> openRelease(Uri page) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppUpdates updates;
  late AppUpdateNavigation navigation;
  late GlobalKey<NavigatorState> navigator;
  late _Source source;
  late _Platform platform;
  late Directory directory;

  setUpAll(() async {
    if (_captureDirectory.isEmpty) return;
    await (FontLoader('SourceHanSerifCN')
          ..addFont(
            rootBundle.load('assets/fonts/SourceHanSerifCN-Regular.otf'),
          )
          ..addFont(rootBundle.load('assets/fonts/SourceHanSerifCN-Bold.otf')))
        .load();
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'completedReleaseNotes': '0.3.1+30',
    });
    source = _Source();
    platform = _Platform();
    directory = await Directory.systemTemp.createTemp('wenku-update-prompt-');
    updates = AppUpdates(
      preferences: await SharedPreferences.getInstance(),
      source: source,
      platform: platform,
      directory: () async => directory,
    );
    navigation = AppUpdateNavigation();
    navigator = GlobalKey<NavigatorState>();
  });
  tearDown(() async {
    updates.dispose();
    navigation.dispose();
    await directory.delete(recursive: true);
  });

  Widget host({
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool reduced = false,
  }) => RepaintBoundary(
    key: _captureKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: navigator,
      navigatorObservers: [navigation],
      theme: novelTheme(
        brightness,
        fontFamily: _captureDirectory.isEmpty ? null : 'SourceHanSerifCN',
      ),
      builder: (context, child) => AppUpdateMonitor(
        updates: updates,
        navigation: navigation,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reduced,
          ),
          child: child!,
        ),
      ),
      home: Scaffold(
        body: Atmosphere(
          child: Center(
            child: Builder(
              builder: (context) => GlassTextButton(
                onPressed: () => showJellySheet<void>(
                  context: context,
                  builder: (context) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: GlassTextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭菜单'),
                    ),
                  ),
                ),
                child: const Text('打开菜单'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> start(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double scale = 1,
    bool reduced = false,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      host(brightness: brightness, textScale: scale, reduced: reduced),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'new release prompts once; later persists across foreground checks',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await start(tester);
      expect(find.byKey(const ValueKey('app-update-prompt')), findsOneWidget);
      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('轻小说文库 0.3.2'), findsOneWidget);
      expect(source.downloads, 0);
      expect(platform.installs, 0);
      if (_captureDirectory.isNotEmpty) {
        await expectLater(
          find.byKey(_captureKey),
          matchesGoldenFile(Uri.file('$_captureDirectory/current-release.png')),
        );
      }
      await tester.tap(find.byKey(const ValueKey('postpone-app-update')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-update-prompt')), findsNothing);
      expect(updates.shouldPrompt, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-update-prompt')), findsNothing);
      expect(source.downloads, 0);
      await close(tester);
    },
  );

  testWidgets(
    'confirm opens the update page and downloads, but never installs',
    (tester) async {
      await start(tester);
      await tester.tap(find.byKey(const ValueKey('confirm-app-update')));
      await tester.pumpAndSettle();
      // File IO completes outside the fake clock; pump its continuations back
      // into the widget zone before checking the download state.
      for (var i = 0; i < 30 && updates.downloaded == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(AppUpdatePage), findsOneWidget);
      expect(find.byKey(const ValueKey('app-update-prompt')), findsNothing);
      expect(source.downloads, 1);
      expect(updates.downloaded, isNotNull);
      expect(platform.installs, 0);
      await close(tester);
    },
  );

  testWidgets('system back dismisses the prompt without download or exit', (
    tester,
  ) async {
    await start(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-prompt')), findsNothing);
    expect(find.text('打开菜单'), findsOneWidget);
    expect(updates.shouldPrompt, isFalse);
    expect(source.downloads, 0);
    await close(tester);
  });

  testWidgets(
    'an unsupported architecture offers details instead of starting a download',
    (tester) async {
      platform.app = const InstalledApp(
        version: '0.3.1',
        build: 30,
        abis: ['riscv64'],
      );
      await start(tester);
      expect(find.text('查看更新'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-app-update')));
      await tester.pumpAndSettle();
      expect(find.byType(AppUpdatePage), findsOneWidget);
      expect(source.downloads, 0);
      await close(tester);
    },
  );

  testWidgets(
    'a menu delays the announcement until its reverse transition completes',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(host());
      await tester.tap(find.text('打开菜单'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(updates.available, isTrue);
      expect(find.text('关闭菜单'), findsOneWidget);
      expect(find.byKey(const ValueKey('app-update-prompt')), findsNothing);
      expect(updates.preferences.getString('lastAppUpdatePrompt'), isNull);
      await tester.tap(find.text('关闭菜单'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('app-update-prompt')), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-update-prompt')), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets('a back gesture delays the prompt without losing it', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(host());
    navigator.currentState!.didStartUserGesture();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-prompt')), findsNothing);
    navigator.currentState!.didStopUserGesture();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-prompt')), findsOneWidget);
    await close(tester);
  });

  testWidgets('a response arriving in the background waits for foreground', (
    tester,
  ) async {
    source.pending = Completer<void>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(host());
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    source.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-prompt')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-prompt')), findsOneWidget);
    await close(tester);
  });

  testWidgets('the prompt waits until the input keyboard closes', (
    tester,
  ) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await start(tester);
    expect(updates.available, isTrue);
    expect(find.byKey(const ValueKey('app-update-prompt')), findsNothing);
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-prompt')), findsOneWidget);
    await close(tester);
  });

  for (final state in ['disabled', 'latest', 'error', 'no release']) {
    testWidgets('$state does not announce an update', (tester) async {
      switch (state) {
        case 'disabled':
          await updates.setAutoCheck(false);
        case 'latest':
          source.release = _release('v0.3.1');
        case 'error':
          source.fail = true;
        case 'no release':
          source.release = null;
      }
      await start(tester);
      expect(find.byKey(const ValueKey('app-update-prompt')), findsNothing);
      expect(source.downloads, 0);
      await close(tester);
    });
  }

  for (final entry in [
    (name: 'phone', size: const Size(390, 844), scale: 1.0, dark: false),
    (
      name: 'narrow-large-type',
      size: const Size(320, 640),
      scale: 2.0,
      dark: false,
    ),
    (
      name: 'landscape-dark',
      size: const Size(844, 390),
      scale: 1.0,
      dark: true,
    ),
  ]) {
    testWidgets(
      '${entry.name}: long notes scroll while actions remain reachable',
      (tester) async {
        source.release = _withLongNotes(source.release!);
        tester.view.physicalSize = entry.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await start(
          tester,
          brightness: entry.dark ? Brightness.dark : Brightness.light,
          scale: entry.scale,
          reduced: true,
        );
        final later = find.byKey(const ValueKey('postpone-app-update'));
        final confirm = find.byKey(const ValueKey('confirm-app-update'));
        expect(later.hitTestable(), findsOneWidget);
        expect(confirm.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(later).overlaps(tester.getRect(confirm)),
          isFalse,
        );
        expect(tester.takeException(), isNull);
        final notes = find.descendant(
          of: find.byKey(const ValueKey('app-update-prompt')),
          matching: find.byType(SingleChildScrollView),
        );
        if (_captureDirectory.isNotEmpty) {
          await expectLater(
            find.byKey(_captureKey),
            matchesGoldenFile(Uri.file('$_captureDirectory/${entry.name}.png')),
          );
        }
        await tester.drag(notes, const Offset(0, -180));
        await tester.pumpAndSettle();
        expect(confirm.hitTestable(), findsOneWidget);
        await close(tester);
      },
    );
  }
}
