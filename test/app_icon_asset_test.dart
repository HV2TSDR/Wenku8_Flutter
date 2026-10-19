import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'approved raster master drives the icon and stays inside adaptive safe bounds',
    () async {
      final config =
          jsonDecode(
                await File('assets/branding/design-source.json').readAsString(),
              )
              as Map;
      expect(config['foreground'], 'app-icon-source.png');
      expect(config['artworkScale'], .88);
      final source = await File(
        'assets/branding/app-icon-source.png',
      ).readAsBytes();
      expect(ByteData.sublistView(source).getUint32(16), 1254);
      final codec = await ui.instantiateImageCodec(
        await File(
          'android/app/src/main/res/drawable-nodpi/ic_archive_mark.png',
        ).readAsBytes(),
      );
      final image = (await codec.getNextFrame()).image;
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      var left = 432, top = 432, right = 0, bottom = 0;
      var visible = 0;
      for (var y = 0; y < 432; y++) {
        for (var x = 0; x < 432; x++) {
          if (pixels[(y * 432 + x) * 4 + 3] <= 32) continue;
          visible++;
          if (x < left) left = x;
          if (x > right) right = x;
          if (y < top) top = y;
          if (y > bottom) bottom = y;
        }
      }
      expect(visible, inInclusiveRange(23500, 24200));
      expect(left, greaterThanOrEqualTo(80));
      expect(top, greaterThanOrEqualTo(80));
      expect(right, lessThanOrEqualTo(352));
      expect(bottom, lessThanOrEqualTo(352));
      expect(bottom - top + 1, inInclusiveRange(226, 234));
      expect(pixels[3], 0);
      image.dispose();
      codec.dispose();
    },
  );
  test(
    'all launcher and iOS icon slots have matching opaque RGB images',
    () async {
      Future<void> check(String path, int side) async {
        final bytes = await File(path).readAsBytes();
        expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
        final header = ByteData.sublistView(bytes);
        expect(header.getUint32(16), side);
        expect(header.getUint32(20), side);
        expect(bytes[25], 2);
      }

      for (final entry in {
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
      }.entries) {
        await check(
          'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
          entry.value,
        );
      }
      const ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
      final contents =
          jsonDecode(await File('$ios/Contents.json').readAsString()) as Map;
      for (final item in contents['images'] as List) {
        final size = double.parse((item['size'] as String).split('x').first);
        final scale = double.parse(
          (item['scale'] as String).replaceAll('x', ''),
        );
        await check('$ios/${item['filename']}', (size * scale).round());
      }
    },
  );
  test(
    'adaptive and themed launchers use the same silhouette and neutral palette',
    () async {
      final source =
          jsonDecode(
                await File('assets/branding/design-source.json').readAsString(),
              )
              as Map;
      final foreground = await File(
        'android/app/src/main/res/drawable/ic_archive_foreground.xml',
      ).readAsString();
      expect(foreground, contains('@drawable/ic_archive_mark'));
      final palette = await File(
        'android/app/src/main/res/values/archive_icon.xml',
      ).readAsString();
      expect(palette, contains(source['background']));
      final adaptive = await File(
        'android/app/src/main/res/drawable-nodpi/ic_archive_mark.png',
      ).readAsBytes();
      final header = ByteData.sublistView(adaptive);
      expect(header.getUint32(16), 432);
      expect(header.getUint32(20), 432);
      expect(adaptive[25], 6); // Transparent overscan, never a baked-in badge.
      final monochrome = await File(
        'android/app/src/main/res/drawable/ic_archive_monochrome.xml',
      ).readAsString();
      expect(monochrome, contains('@drawable/ic_archive_mark'));
      expect(monochrome, contains('android:tintMode="src_in"'));
      final themed = await File(
        'android/app/src/main/res/mipmap-anydpi-v33/ic_launcher.xml',
      ).readAsString();
      expect(themed, contains('<monochrome'));
      expect(themed, contains('@drawable/ic_archive_monochrome'));
    },
  );
}
