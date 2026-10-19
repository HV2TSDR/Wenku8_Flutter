import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/updates/app_updates.dart';
import 'package:wenku8_flutter/updates/update_page.dart';

const _repo = 'example/reader';
Map<String, dynamic> _json({
  String tag = 'v0.3.0',
  List<Map<String, dynamic>>? assets,
}) => {
  'tag_name': tag,
  'draft': false,
  'prerelease': false,
  'body': '### 新功能\n- 阅读改进',
  'assets':
      assets ??
      [
        for (final abi in ['armeabi-v7a', 'arm64-v8a', 'x86_64'])
          {
            'name': 'wenku8-${ReleaseVersion.parse(tag)!.name}-$abi.apk',
            'size': 16,
            'browser_download_url':
                'https://github.com/$_repo/releases/download/$tag/wenku8-${ReleaseVersion.parse(tag)!.name}-$abi.apk',
          },
      ],
};
const _installed = InstalledApp(
  version: '0.2.0',
  build: 2,
  abis: ['arm64-v8a', 'armeabi-v7a'],
);

class _Platform implements UpdatePlatform {
  String result = 'opened';
  String? failure;
  String failureCode = 'APK_REJECTED';
  int installs = 0;
  int reads = 0;
  InstalledApp current = _installed;
  Completer<void>? installGate;
  final handedOff = <File>[];
  final opened = <Uri>[];
  String? inspectFailure;
  int? installBuild;
  int verifiedBuild = 7;
  @override
  Future<InstalledApp> installedApp() async {
    reads++;
    return current;
  }

  @override
  Future<UpdatePackageInfo> inspect(
    File apk,
    String version, {
    int? build,
  }) async {
    if (inspectFailure != null) {
      throw PlatformException(code: 'APK_REJECTED', message: inspectFailure);
    }
    return UpdatePackageInfo(version: version, build: build ?? verifiedBuild);
  }

  @override
  Future<String> install(File apk, String version, {int? build}) async {
    installs++;
    installBuild = build;
    handedOff.add(apk);
    if (installGate != null) await installGate!.future;
    if (failure != null) {
      throw PlatformException(code: failureCode, message: failure);
    }
    return result;
  }

  @override
  Future<void> allowInstalls() async {}
  @override
  Future<void> openRelease(Uri page) async {
    opened.add(page);
  }
}

class _Source implements UpdateSource {
  AppRelease? release = AppRelease.fromGithub(_json(), _repo);
  int checks = 0;
  bool fail = false;
  Object? failure;
  bool? fileExistedBeforeDownload;
  Completer<void>? gate;
  Completer<void>? checkGate;
  List<int> data = [1, 2, 3];
  int downloads = 0;
  @override
  Future<AppRelease?> latest() async {
    checks++;
    if (checkGate != null) await checkGate!.future;
    if (fail) throw const SocketException('offline');
    if (failure != null) throw failure!;
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
    fileExistedBeforeDownload = await file.exists();
    await file.writeAsBytes(data);
    progress(data.length);
    if (gate != null) await gate!.future;
    task.check();
    if (fail) throw const SocketException('offline');
    if (failure != null) throw failure!;
  }
}

class _Headers extends Fake implements HttpHeaders {
  _Headers([this.location]);
  final String? location;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  String? value(String name) =>
      name == HttpHeaders.locationHeader ? location : null;
}

class _Reply extends Stream<List<int>> implements HttpClientResponse {
  _Reply(this.statusCode, this.chunks, [String? location])
    : headers = _Headers(location);
  @override
  final int statusCode;
  final List<List<int>> chunks;
  @override
  final HttpHeaders headers;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.fromIterable(chunks).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.reply);
  final _Reply reply;
  @override
  final HttpHeaders headers = _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  Future<HttpClientResponse> close() async => reply;
}

class _Client extends Fake implements HttpClient {
  _Client(this.replies);
  final List<_Reply> replies;
  final urls = <Uri>[];
  Completer<HttpClientRequest>? requestGate;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    if (requestGate != null) return requestGate!.future;
    return _Request(replies.removeAt(0));
  }

  @override
  void close({bool force = false}) {}
  @override
  Future<HttpClientRequest> headUrl(Uri url) => getUrl(url);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'semantic versions compare numerically and build-only releases are newer',
    () {
      expect(
        ReleaseVersion.parse(
          'v0.10.0',
        )!.compareTo(ReleaseVersion.parse('0.9.9')!),
        greaterThan(0),
      );
      for (final tag in ['v1', 'v0.3.0-beta', 'v0.3.0/../../x', '0.3.0+bad']) {
        expect(ReleaseVersion.parse(tag), isNull);
      }
      expect(
        AppRelease.fromGithub(
          _json(tag: 'v0.2.0'),
          _repo,
        )!.isNewerThan(_installed),
        false,
      );
      expect(
        AppRelease.fromGithub(
          _json(tag: 'v0.2.0+3'),
          _repo,
        )!.isNewerThan(_installed),
        true,
      );
      expect(
        AppRelease.fromGithub(_json(), _repo)!.isNewerThan(_installed),
        true,
      );
    },
  );
  test(
    'stable, repository-bound assets select the device ABI without mixing architectures',
    () {
      final release = AppRelease.fromGithub(_json(), _repo)!;
      expect(
        release.assetFor(_installed.abis)!.name,
        endsWith('-arm64-v8a.apk'),
      );
      expect(release.assetFor(['riscv64']), isNull);
      for (final field in ['draft', 'prerelease']) {
        expect(AppRelease.fromGithub(_json()..[field] = true, _repo), isNull);
      }
      final bad = _json(
        assets: [
          {
            'name': 'wenku8-x-arm64-v8a.apk',
            'size': 16,
            'browser_download_url': 'https://evil.example/a.apk',
          },
          {
            'name': 'wenku8-x-arm64-v8a.apk',
            'size': 16,
            'browser_download_url':
                'https://github.com/other/repo/releases/download/v0.3.0/wenku8-x-arm64-v8a.apk',
          },
          {
            'name': 'wenku8-x-arm64-v8a.apk',
            'size': 0,
            'browser_download_url':
                'https://github.com/$_repo/releases/download/v0.3.0/wenku8-x-arm64-v8a.apk',
          },
        ],
      );
      expect(AppRelease.fromGithub(bad, _repo)!.assets, isEmpty);
    },
  );

  test(
    'encoded build tags retain all APKs and reject mismatched URL segments',
    () {
      const tag = 'v0.3.0+29';
      const name = 'wenku8-0.3.0-arm64-v8a.apk';
      final encoded = _json(tag: tag);
      for (final asset
          in (encoded['assets'] as List).cast<Map<String, dynamic>>()) {
        asset['browser_download_url'] =
            (asset['browser_download_url'] as String).replaceFirst(
              '/$tag/',
              '/${Uri.encodeComponent(tag)}/',
            );
      }
      final release = AppRelease.fromGithub(encoded, _repo)!;
      expect(release.assets, hasLength(3));
      for (final abi in ['armeabi-v7a', 'arm64-v8a', 'x86_64']) {
        expect(release.assetFor([abi])!.name, 'wenku8-0.3.0-$abi.apk');
      }
      expect(
        release.isNewerThan(
          const InstalledApp(version: '0.3.0', build: 27, abis: ['arm64-v8a']),
        ),
        true,
      );
      for (final path in [
        '/other/repo/releases/download/v0.3.0%2B29/$name',
        '/$_repo/releases/download/v0.3.0%2B28/$name',
        '/$_repo/releases/download/v0.3.0%252B29/$name',
        '/example%2Freader/releases/download/v0.3.0%2B29/$name',
        '/$_repo/releases/download/v0.3.0%2B29/extra/$name',
        '/$_repo/releases/download/v0.3.0%2B29/wenku8-other-arm64-v8a.apk',
      ]) {
        final rejected = AppRelease.fromGithub(
          _json(
            tag: tag,
            assets: [
              {
                'name': name,
                'size': 16,
                'browser_download_url': 'https://github.com$path',
              },
            ],
          ),
          _repo,
        )!;
        expect(rejected.assets, isEmpty, reason: path);
      }
    },
  );

  late Directory temp;
  late _Source source;
  late _Platform platform;
  late AppUpdates updates;
  var now = DateTime(2026, 10, 15);
  setUp(() async {
    now = DateTime(2026, 10, 15);
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('wenku8-update-test-');
    source = _Source();
    platform = _Platform();
    updates = AppUpdates(
      preferences: await SharedPreferences.getInstance(),
      source: source,
      platform: platform,
      directory: () async => temp,
      clock: () => now,
    );
  });
  tearDown(() async {
    updates.dispose();
    await temp.delete(recursive: true);
  });
  test(
    'each foreground check ignores the old six-hour timestamp and respects opt-out',
    () async {
      await updates.preferences.setInt(
        'lastAppUpdateCheck',
        now.millisecondsSinceEpoch,
      );
      await updates.check(automatic: true);
      await updates.check(automatic: true);
      expect(source.checks, 2);
      expect(updates.available, true);
      await updates.setAutoCheck(false);
      await updates.check(automatic: true);
      expect(source.checks, 2);
      await updates.check();
      expect(source.checks, 3);
    },
  );
  test(
    'update reminders persist for 24 hours without suppressing a newer release',
    () async {
      await updates.check();
      expect(updates.shouldPrompt, isTrue);
      await updates.rememberPrompt(updates.release!);
      expect(updates.shouldPrompt, isFalse);
      final restarted = AppUpdates(
        preferences: updates.preferences,
        source: source,
        platform: platform,
        clock: () => now,
      );
      addTearDown(restarted.dispose);
      await restarted.check();
      expect(restarted.shouldPrompt, isFalse);
      now = now.add(const Duration(hours: 23, minutes: 59));
      expect(restarted.shouldPrompt, isFalse);
      now = now.add(const Duration(minutes: 1));
      expect(restarted.shouldPrompt, isTrue);
      await restarted.rememberPrompt(restarted.release!);
      source.release = AppRelease.fromGithub(_json(tag: 'v0.4.0'), _repo);
      await restarted.check();
      expect(restarted.shouldPrompt, isTrue);
      // The reminder does not block an explicit check/download of the same tag.
      await updates.check();
      await updates.download();
      expect(updates.downloaded, isNotNull);
    },
  );
  testWidgets(
    'launch and real background returns check once, transient inactive does not',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      Widget monitor() =>
          AppUpdateMonitor(updates: updates, child: const SizedBox());
      await tester.pumpWidget(monitor());
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(source.checks, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 2));
      expect(source.checks, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(source.checks, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(monitor());
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(
        source.checks,
        3,
      ); // A new launch inside the former six-hour window.
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'manual check refreshes an installed version cached before an APK update',
    () async {
      await updates.check();
      expect(updates.available, isTrue);
      platform.current = const InstalledApp(
        version: '0.3.0',
        build: 7,
        abis: ['arm64-v8a'],
      );
      await updates.check();
      expect(updates.installed!.build, 7);
      expect(updates.available, isFalse);
      expect(platform.reads, 2);
    },
  );
  test(
    'installation re-reads package metadata and rejects a stale downloaded APK',
    () async {
      await updates.check();
      await updates.download();
      platform.current = const InstalledApp(
        version: '0.3.0',
        build: 7,
        abis: ['arm64-v8a'],
      );
      await updates.install();
      expect(platform.installs, 0);
      expect(updates.downloaded, isNull);
      expect(updates.error, contains('已安装 0.3.0（7）'));
    },
  );
  test('no release and network failure remain recoverable', () async {
    source.release = null;
    await updates.check();
    expect(updates.checked, true);
    expect(updates.available, false);
    expect(updates.error, null);
    source.fail = true;
    await updates.check();
    expect(updates.error, isNotNull);
    source.fail = false;
    source.release = AppRelease.fromGithub(_json(), _repo);
    await updates.check();
    expect(updates.available, true);
    expect(updates.error, null);
  });
  test(
    'download, explicit permission and installation are separate actions',
    () async {
      await updates.check();
      await updates.download();
      expect(await updates.downloaded!.readAsBytes(), [1, 2, 3]);
      expect(platform.installs, 0);
      platform.result = 'permission';
      await updates.install();
      expect(updates.needsPermission, true);
      platform.result = 'opened';
      await updates.install();
      expect(updates.needsPermission, false);
      platform.failure = '安装包签名与当前版本不一致，无法覆盖升级';
      await updates.install();
      expect(updates.error, contains('签名'));
    },
  );
  test(
    'cancel and interrupted downloads remove partial files and can be retried',
    () async {
      await updates.check();
      source.gate = Completer<void>();
      final downloading = updates.download();
      for (var i = 0; i < 20 && updates.bytes == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      updates.cancelDownload();
      source.gate!.complete();
      await downloading;
      expect(updates.downloaded, isNull);
      expect(updates.error, null);
      expect(await Directory('${temp.path}/updates').list().toList(), isEmpty);
      source.gate = null;
      source.fail = true;
      await updates.download();
      expect(updates.error, isNotNull);
      source.fail = false;
      await updates.download();
      expect(updates.downloaded, isNotNull);
    },
  );
  test(
    'a new download cannot replace an APK already handed to Android',
    () async {
      await updates.check();
      await updates.download();
      await updates.install();
      final first = platform.handedOff.single;
      source.release = AppRelease.fromGithub(_json(tag: 'v0.4.0'), _repo);
      source.data = [4, 5, 6];
      await updates.check();
      await updates.download();
      expect(updates.downloaded!.path, isNot(first.path));
      expect(await first.readAsBytes(), [1, 2, 3]);
      expect(await updates.downloaded!.readAsBytes(), [4, 5, 6]);
    },
  );
  test(
    'checking excludes download and install until metadata is settled',
    () async {
      await updates.check();
      await updates.download();
      source.checkGate = Completer<void>();
      final checking = updates.check();
      await Future<void>.delayed(Duration.zero);
      expect(updates.checking, isTrue);
      await updates.install();
      await updates.download();
      expect(platform.installs, 0);
      expect(source.downloads, 1);
      source.checkGate!.complete();
      await checking;
    },
  );
  test(
    'installer handoff excludes metadata changes and another download',
    () async {
      await updates.check();
      await updates.download();
      platform.installGate = Completer<void>();
      final installing = updates.install();
      await Future<void>.delayed(Duration.zero);
      expect(updates.installing, isTrue);
      await updates.check();
      await updates.download();
      expect(source.checks, 1);
      expect(source.downloads, 1);
      platform.installGate!.complete();
      await installing;
    },
  );
  test(
    'replacing an asset under the same tag invalidates the ready APK',
    () async {
      await updates.check();
      await updates.download();
      final replacement = _json();
      for (final asset in replacement['assets'] as List) {
        (asset as Map<String, dynamic>)['size'] = 32;
      }
      source.release = AppRelease.fromGithub(replacement, _repo);
      await updates.check();
      expect(updates.downloaded, isNull);
      await updates.install();
      expect(platform.installs, 0);
    },
  );
  test(
    'a rejected APK returns to download instead of repeating a bad install',
    () async {
      await updates.check();
      await updates.download();
      platform.failure = '安装包版本不匹配，请重新下载';
      await updates.install();
      expect(updates.downloaded, isNull);
      expect(updates.error, contains('重新下载'));
      platform.failure = null;
      await updates.download();
      await updates.install();
      expect(source.downloads, 2);
      expect(platform.installs, 2);
    },
  );
  test(
    'unchanged metadata preserves a verified APK across permission returns',
    () async {
      await updates.check();
      await updates.download();
      final ready = updates.downloaded;
      platform.result = 'permission';
      await updates.install();
      await updates.check();
      expect(updates.downloaded!.path, ready!.path);
      expect(updates.needsPermission, isTrue);
      platform.failureCode = 'OPEN';
      platform.failure = '系统页面无法打开，请重试';
      await updates.install();
      expect(updates.downloaded!.path, ready.path);
      platform.failure = null;
      platform.result = 'opened';
      await updates.install();
      expect(updates.needsPermission, isFalse);
    },
  );
  test(
    'same-tag asset IDs invalidate an equal-sized APK, retries have unique paths',
    () async {
      await updates.check();
      await updates.download();
      final first = updates.downloaded!;
      await updates.download();
      expect(updates.downloaded!.path, isNot(first.path));
      final replaced = _json();
      for (final raw in replaced['assets'] as List) {
        (raw as Map<String, dynamic>)['id'] = 42;
      }
      source.release = AppRelease.fromGithub(replaced, _repo);
      await updates.check();
      expect(updates.downloaded, isNull);
    },
  );
  test(
    'download validates the actual APK before offering installation',
    () async {
      await updates.check();
      platform.inspectFailure = '安装包是 0.2.0（2），不是较新版本，请重新下载';
      await updates.download();
      expect(updates.downloaded, isNull);
      expect(updates.error, contains('0.2.0（2）'));
      expect(await Directory('${temp.path}/updates').list().toList(), isEmpty);
      platform.inspectFailure = null;
      await updates.download();
      expect(updates.downloadedInfo!.version, '0.3.0');
      expect(updates.downloadedInfo!.build, 7);
      await updates.install();
      expect(platform.installBuild, 7);
    },
  );
  test(
    'an APK must have a newer native build even with a newer release name',
    () async {
      await updates.check();
      platform.verifiedBuild = 2;
      await updates.download();
      expect(updates.downloaded, isNull);
      expect(updates.error, contains('版本不符'));
      expect(platform.installs, 0);
    },
  );
  test(
    'GitHub transport checks status and treats 404 as no published release',
    () async {
      final client = _Client([
        _Reply(404, []),
        _Reply(200, [utf8.encode(jsonEncode(_json()))]),
        _Reply(403, []),
      ]);
      final github = GithubUpdateSource(
        repository: _repo,
        clientFactory: () => client,
      );
      expect(await github.latest(), isNull);
      expect((await github.latest())!.version.name, '0.3.0');
      await expectLater(github.latest(), throwsA(isA<HttpException>()));
      expect(
        client.urls.first.toString(),
        'https://api.github.com/repos/$_repo/releases/latest',
      );
    },
  );
  test(
    'APK transfer validates redirect destinations, byte count and supplied integrity digest',
    () async {
      final data = utf8.encode('signed APK fixture');
      final asset = UpdateAsset(
        name: 'wenku8-0.3.0-arm64-v8a.apk',
        url: Uri.parse(
          'https://github.com/$_repo/releases/download/v0.3.0/app.apk',
        ),
        size: data.length,
        digest: sha256.convert(data).toString(),
      );
      final file = File('${temp.path}/transfer.apk');
      final good = _Client([
        _Reply(302, [], 'https://release-assets.githubusercontent.com/asset'),
        _Reply(200, [data.sublist(0, 4), data.sublist(4)]),
      ]);
      await GithubUpdateSource(
        clientFactory: () => good,
      ).download(asset, file, UpdateDownload(), (_) {});
      expect(await file.readAsBytes(), data);
      final evil = _Client([
        _Reply(302, [], 'https://evil.example/package.apk'),
      ]);
      await expectLater(
        GithubUpdateSource(
          clientFactory: () => evil,
        ).download(asset, file, UpdateDownload(), (_) {}),
        throwsFormatException,
      );
      final incomplete = _Client([
        _Reply(200, [data.sublist(1)]),
      ]);
      await expectLater(
        GithubUpdateSource(
          clientFactory: () => incomplete,
        ).download(asset, file, UpdateDownload(), (_) {}),
        throwsA(isA<UpdateServiceUnavailable>()),
      );
      final changed = [...data]..[0] ^= 1;
      final tampered = _Client([
        _Reply(200, [changed]),
      ]);
      await expectLater(
        GithubUpdateSource(
          clientFactory: () => tampered,
        ).download(asset, file, UpdateDownload(), (_) {}),
        throwsFormatException,
      );
    },
  );
  test(
    'mirror changes transport only and keeps canonical release identity',
    () async {
      final metadata = _json(tag: 'v0.3.0+57');
      (metadata['assets'] as List).first['id'] = 57;
      final client = _Client([
        _Reply(200, [utf8.encode(jsonEncode(metadata))]),
      ]);
      final source = GithubUpdateSource(
        repository: _repo,
        gateway: Uri.parse(updateMirrorOrigin),
        clientFactory: () => client,
      );
      final release = (await source.latest())!;
      expect(
        client.urls.single.toString(),
        '$updateMirrorOrigin/api/releases/latest',
      );
      expect(release.page.host, 'github.com');
      expect(release.assets.first.url.host, 'github.com');
      expect(release.assets.first.id, 57);
    },
  );
  test(
    'mirror downloads immutable asset ID and still checks digest and size',
    () async {
      final bytes = utf8.encode('APK bytes');
      final asset = UpdateAsset(
        name: 'wenku8-0.3.0-arm64-v8a.apk',
        url: Uri.parse(
          'https://github.com/$_repo/releases/download/v0.3.0%2B57/wenku8-0.3.0-arm64-v8a.apk',
        ),
        size: bytes.length,
        id: 57,
        digest: sha256.convert(bytes).toString(),
      );
      final client = _Client([
        _Reply(200, [bytes]),
      ]);
      final file = File('${temp.path}/mirror.apk');
      await GithubUpdateSource(
        repository: _repo,
        gateway: Uri.parse(updateMirrorOrigin),
        clientFactory: () => client,
      ).download(asset, file, UpdateDownload(), (_) {});
      expect(client.urls.single.host, 'git.3952039.xyz');
      expect(client.urls.single.pathSegments, asset.url.pathSegments);
      expect(client.urls.single.queryParameters, {'asset': '57'});
      expect(await file.readAsBytes(), bytes);
      final changed = _Client([
        _Reply(200, [utf8.encode('bad bytes')]),
      ]);
      await expectLater(
        GithubUpdateSource(
          repository: _repo,
          gateway: Uri.parse(updateMirrorOrigin),
          clientFactory: () => changed,
        ).download(asset, file, UpdateDownload(), (_) {}),
        throwsFormatException,
      );
    },
  );
  test(
    'mirror transport reports redirects as unavailable and rejects external assets',
    () async {
      final client = _Client([
        _Reply(
          302,
          [],
          'https://github.com/$_repo/releases/download/v0.3.0/app.apk',
        ),
      ]);
      final source = GithubUpdateSource(
        repository: _repo,
        gateway: Uri.parse(updateMirrorOrigin),
        clientFactory: () => client,
      );
      final file = File('${temp.path}/mirror.apk');
      final release = AppRelease.fromGithub(_json(), _repo)!;
      await expectLater(
        source.download(release.assets.first, file, UpdateDownload(), (_) {}),
        throwsA(isA<UpdateServiceUnavailable>()),
      );
      expect(client.urls, hasLength(1));
      final external = UpdateAsset(
        name: 'file.apk',
        url: Uri.parse('https://evil.test/file.apk'),
        size: 4,
      );
      await expectLater(
        source.download(external, file, UpdateDownload(), (_) {}),
        throwsFormatException,
      );
      expect(client.urls, hasLength(1));
    },
  );
  test(
    'official app always chooses mirror-first without a user channel preference',
    () async {
      final service = AppUpdates(preferences: updates.preferences);
      addTearDown(service.dispose);
      expect(service.source, isA<MirrorFirstUpdateSource>());
      expect(service.projectPage.host, 'git.3952039.xyz');
      expect(service.releasePage.host, 'git.3952039.xyz');
      await updates.preferences.setString('appUpdateChannel', 'github');
      final restarted = AppUpdates(preferences: updates.preferences);
      addTearDown(restarted.dispose);
      expect(restarted.source, isA<MirrorFirstUpdateSource>());
    },
  );

  test(
    'mirror rate limiting falls back once; a real no-release response does not',
    () async {
      final mirrorClient = _Client([_Reply(429, []), _Reply(404, [])]);
      final original = _Source();
      final source = MirrorFirstUpdateSource(
        mirror: GithubUpdateSource(
          repository: _repo,
          gateway: Uri.parse(updateMirrorOrigin),
          clientFactory: () => mirrorClient,
        ),
        original: original,
      );
      expect(await source.latest(), original.release);
      expect(original.checks, 1);
      expect(await source.latest(), isNull);
      expect(original.checks, 1);
      expect(mirrorClient.urls, hasLength(2));
    },
  );

  test(
    'an interrupted mirror transfer restarts cleanly and retains the verified asset',
    () async {
      final mirror = _Source()..fail = true;
      final original = _Source()..data = [8, 9, 10, 11];
      final routes = <bool>[], progress = <int>[];
      final source = MirrorFirstUpdateSource(
        mirror: mirror,
        original: original,
        onRoute: routes.add,
      );
      final file = File('${temp.path}/fallback.apk');
      await source.download(
        mirror.release!.assets.first,
        file,
        UpdateDownload(),
        progress.add,
      );
      expect(await file.readAsBytes(), original.data);
      expect(original.fileExistedBeforeDownload, false);
      expect(routes, [false, true]);
      expect(progress, [3, 0, 4]);
      expect(original.downloads, 1);
    },
  );

  test(
    'cancelled transfers and integrity/identity failures never retry another source',
    () async {
      final mirror = _Source()..failure = const FormatException('安装包校验失败');
      final original = _Source();
      final source = MirrorFirstUpdateSource(
        mirror: mirror,
        original: original,
      );
      final file = File('${temp.path}/cancelled.apk');
      await expectLater(
        source.download(
          mirror.release!.assets.first,
          file,
          UpdateDownload(),
          (_) {},
        ),
        throwsFormatException,
      );
      expect(original.downloads, 0);
      mirror.failure = null;
      mirror.gate = Completer<void>();
      final task = UpdateDownload();
      final download = source.download(
        mirror.release!.assets.first,
        file,
        task,
        (_) {},
      );
      final assertion = expectLater(download, throwsA(isA<UpdateCancelled>()));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      task.cancel();
      mirror.gate!.complete();
      await assertion;
      expect(original.downloads, 0);
    },
  );
  test(
    'direct fallback revalidates the exact release asset ID before downloading',
    () async {
      final data = utf8.encode('verified update');
      final metadata = _json(
        assets: [
          {
            'name': 'wenku8-0.3.0-arm64-v8a.apk',
            'size': data.length,
            'id': 57,
            'digest': 'sha256:${sha256.convert(data)}',
            'browser_download_url':
                'https://github.com/$_repo/releases/download/v0.3.0/wenku8-0.3.0-arm64-v8a.apk',
          },
        ],
      );
      final asset = AppRelease.fromGithub(metadata, _repo)!.assets.single;
      final good = _Client([
        _Reply(200, [utf8.encode(jsonEncode(metadata))]),
        _Reply(200, [data]),
      ]);
      final file = File('${temp.path}/immutable.apk');
      await GithubUpdateSource(
        repository: _repo,
        clientFactory: () => good,
      ).download(asset, file, UpdateDownload(), (_) {});
      expect(good.urls.first.path, '/repos/$_repo/releases/tags/v0.3.0');
      expect(await file.readAsBytes(), data);
      final replaced = jsonDecode(jsonEncode(metadata)) as Map<String, dynamic>;
      (replaced['assets'] as List).single['id'] = 58;
      final bad = _Client([
        _Reply(200, [utf8.encode(jsonEncode(replaced))]),
      ]);
      await expectLater(
        GithubUpdateSource(
          repository: _repo,
          clientFactory: () => bad,
        ).download(asset, file, UpdateDownload(), (_) {}),
        throwsFormatException,
      );
      expect(bad.urls, hasLength(1));
    },
  );
  test(
    'update requests release public-content priority after success and failure',
    () async {
      final calls = <bool>[];
      final service = AppUpdates(
        preferences: updates.preferences,
        source: source,
        platform: platform,
        directory: () async => temp,
        networkPriority: (enabled) async {
          calls.add(enabled);
        },
      );
      addTearDown(service.dispose);
      await service.check();
      expect(calls, [true, false]);
      source.fail = true;
      await service.download();
      expect(calls, [true, false, true, false]);
      expect(service.downloading, false);
    },
  );
  testWidgets(
    'a stalled mirror DNS/connection times out and falls back automatically',
    (tester) async {
      final client = _Client([])..requestGate = Completer<HttpClientRequest>();
      final original = _Source();
      final source = MirrorFirstUpdateSource(
        mirror: GithubUpdateSource(
          repository: _repo,
          gateway: Uri.parse(updateMirrorOrigin),
          clientFactory: () => client,
        ),
        original: original,
      );
      AppRelease? result;
      final pending = source.latest().then((value) {
        result = value;
      });
      await tester.pump(const Duration(seconds: 4, milliseconds: 1));
      await pending;
      expect(result, original.release);
      expect(original.checks, 1);
    },
  );
  test(
    'project/download entry opens the mirror first and falls back without a source picker',
    () async {
      final client = _Client([_Reply(200, []), _Reply(503, [])]);
      await HttpOverrides.runZoned(() async {
        await updates.openProjectPage();
        expect(platform.opened.last.host, 'git.3952039.xyz');
        await updates.openProjectPage(showRelease: true);
        expect(platform.opened.last.host, 'github.com');
        expect(client.urls, hasLength(2));
      }, createHttpClient: (_) => client);
    },
  );
}
