// Standalone, isolated update harness. Its APK fixtures are generated locally;
// this entry point is never used by a production build.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/updates/app_updates.dart';
import 'package:wenku8_flutter/updates/update_page.dart';

class _FixtureSource implements UpdateSource {
  _FixtureSource(this.file);
  final File file;

  @override
  Future<AppRelease> latest() async => AppRelease(
    tag: 'v0.3.4',
    version: const ReleaseVersion(0, 3, 4),
    notes: '隔离测试：实际 Android 安装包 0.3.4（36）。',
    page: Uri.https('github.com', '/example/reader/releases/tag/v0.3.4'),
    assets: [
      UpdateAsset(
        name: 'wenku8-0.3.4-universal.apk',
        url: Uri.https(
          'github.com',
          '/example/reader/releases/download/v0.3.4/wenku8-0.3.4-universal.apk',
        ),
        size: await file.length(),
      ),
    ],
  );

  @override
  Future<void> download(
    UpdateAsset asset,
    File destination,
    UpdateDownload task,
    void Function(int) progress,
  ) async {
    task.check();
    await file.copy(destination.path);
    progress(await destination.length());
    task.check();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final info = await AndroidUpdatePlatform().installedApp();
  // Fixture version 36 must be an upgrade to the isolated baseline, never a
  // way to install a fixture over the real application.
  if (info.build != 35) {
    throw StateError('Build the isolated probe as 0.3.3+35');
  }
  const channel = AndroidUpdatePlatform.channel;
  final native = await channel.invokeMapMethod<String, dynamic>('info');
  if (native?['package'] != 'org.mewx.wenku8_flutter.render_probe') {
    throw StateError('Update probe requires the render_probe application ID');
  }
  final directory = await getApplicationSupportDirectory();
  final updates = AppUpdates(
    preferences: await SharedPreferences.getInstance(),
    source: _FixtureSource(File('${directory.path}/update-fixtures/36.apk')),
  );
  await updates.check();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: novelTheme(Brightness.light),
      home: AppUpdatePage(updates: updates),
    ),
  );
}
