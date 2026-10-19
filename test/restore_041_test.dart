import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/updates/app_updates.dart';
import 'package:wenku8_flutter/updates/release_highlights.dart';

void main() {
  test('restoration version upgrades both 0.3.7 and withdrawn 0.4.0', () {
    expect(currentAppVersion, '0.4.1');
    expect(currentAppBuild, greaterThan(87));
    final release = AppRelease.fromGithub({
      'tag_name': 'v0.4.1',
      'draft': false,
      'prerelease': false,
      'body': currentReleaseNotes,
      'assets': [
        for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64'])
          {
            'id': 100 + abi.length,
            'name': 'wenku8-0.4.1-$abi.apk',
            'size': 57000000,
            'browser_download_url':
                'https://github.com/$officialUpdateRepository/releases/download/v0.4.1/wenku8-0.4.1-$abi.apk',
          },
      ],
    }, officialUpdateRepository)!;
    for (final old in [
      (version: '0.3.7', build: 63),
      (version: '0.4.0', build: 87),
    ]) {
      expect(
        release.isNewerThan(
          InstalledApp(
            version: old.version,
            build: old.build,
            abis: const ['arm64-v8a'],
          ),
        ),
        isTrue,
      );
    }
    for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
      expect(release.assetFor([abi])?.name, 'wenku8-0.4.1-$abi.apk');
    }
  });

  test(
    'source policy is first, prominent and repeated without claiming fixes',
    () {
      expect(currentReleaseSummary.first, currentReleaseSourcePolicy);
      expect(currentReleaseSections.first.title, contains('重要说明'));
      expect(
        currentReleaseSections.first.items.first,
        currentReleaseSourcePolicy,
      );
      expect(
        currentReleaseSections.last.items.last,
        contains(currentReleaseSourcePolicy),
      );
      expect(currentReleaseNotes, contains(currentReleaseSourcePolicy));
      expect(
        currentReleaseSections.last.items.first,
        contains('未加入其他功能调整或问题修复'),
      );
    },
  );
}
