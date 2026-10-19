// Run: flutter test tools/generate_app_icons.dart
// Keep the approved raster master unchanged; derive launcher sizes and masks.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('export launcher icons from the approved raster master', () async {
    final config =
        jsonDecode(
              await File('assets/branding/design-source.json').readAsString(),
            )
            as Map<String, dynamic>;
    final backgroundHex = config['background'] as String;
    final background = ui.Color(
      0xFF000000 | int.parse(backgroundHex.substring(1), radix: 16),
    );
    final codec = await ui.instantiateImageCodec(
      await File('assets/branding/${config['foreground']}').readAsBytes(),
    );
    final source = (await codec.getNextFrame()).image;
    codec.dispose();
    final rgba = (await source.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    // The mark is milk on charcoal. Only the charcoal becomes transparent;
    // the approved highlights/texture remain the source's own pixels.
    final mask = Uint8List.fromList(rgba);
    for (var i = 0; i < mask.length; i += 4) {
      final luminance =
          .2126 * mask[i] + .7152 * mask[i + 1] + .0722 * mask[i + 2];
      mask[i + 3] = ((luminance - 58) / (200 - 58) * 255).round().clamp(0, 255);
    }
    final mark = await _decodeRgba(mask, source.width, source.height);
    final res = Directory('android/app/src/main/res');
    Future<void> write(String path, String text) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
    }

    String bitmap({bool monochrome = false}) =>
        '''<?xml version="1.0" encoding="utf-8"?>
<bitmap xmlns:android="http://schemas.android.com/apk/res/android"
    android:src="@drawable/ic_archive_mark" android:gravity="fill"
    android:filter="true"${monochrome ? '\n    android:tint="#FF000000" android:tintMode="src_in"' : ''}/>
''';
    await write('${res.path}/drawable/ic_archive_foreground.xml', bitmap());
    await write(
      '${res.path}/drawable/ic_archive_monochrome.xml',
      bitmap(monochrome: true),
    );
    await write(
      '${res.path}/values/archive_icon.xml',
      '<?xml version="1.0" encoding="utf-8"?>\n<resources><color name="archive_icon_background">$backgroundHex</color></resources>\n',
    );
    for (final version in [26, 33]) {
      await write(
        '${res.path}/mipmap-anydpi-v$version/ic_launcher.xml',
        '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/archive_icon_background"/>
    <foreground android:drawable="@drawable/ic_archive_foreground"/>
${version >= 33 ? '    <monochrome android:drawable="@drawable/ic_archive_monochrome"/>\n' : ''}</adaptive-icon>
''',
      );
    }

    Future<Uint8List> render(int size, {bool adaptive = false}) async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      if (!adaptive) canvas.drawColor(background, ui.BlendMode.src);
      final side = adaptive
          ? size *
                (config['adaptiveArtworkSide'] as num).toDouble() /
                108 *
                (config['artworkScale'] as num).toDouble()
          : size * (config['artworkScale'] as num).toDouble();
      final artworkImage = adaptive ? mark : source;
      canvas.drawImageRect(
        artworkImage,
        ui.Rect.fromLTWH(
          0,
          0,
          artworkImage.width.toDouble(),
          artworkImage.height.toDouble(),
        ),
        ui.Rect.fromLTWH((size - side) / 2, (size - side) / 2, side, side),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(size, size);
      final data = (await image.toByteData(
        format: adaptive ? ui.ImageByteFormat.png : ui.ImageByteFormat.rawRgba,
      ))!;
      final png = adaptive
          ? data.buffer.asUint8List()
          : _opaquePng(data.buffer.asUint8List(), size);
      image.dispose();
      picture.dispose();
      return png;
    }

    final adaptive = File('${res.path}/drawable-nodpi/ic_archive_mark.png');
    await adaptive.parent.create(recursive: true);
    await adaptive.writeAsBytes(await render(432, adaptive: true));

    final rendered = <int, Uint8List>{};
    Future<void> png(String path, int size) async {
      final bytes = rendered[size] ??= await render(size);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    }

    for (final entry in {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    }.entries) {
      await png('${res.path}/mipmap-${entry.key}/ic_launcher.png', entry.value);
    }
    const ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
    final contents =
        jsonDecode(await File('$ios/Contents.json').readAsString()) as Map;
    for (final item in contents['images'] as List) {
      final side = double.parse((item['size'] as String).split('x').first);
      final scale = double.parse((item['scale'] as String).replaceAll('x', ''));
      await png('$ios/${item['filename']}', (side * scale).round());
    }
    await png('flutter_screenshots/loading-polish/app-icon.png', 512);
    await png('assets/branding/app-icon.png', 512);
    mark.dispose();
    source.dispose();
  });
}

Future<ui.Image> _decodeRgba(Uint8List rgba, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return image;
}

// RGB PNG: iOS app icons must not contain an alpha channel, even if opaque.
Uint8List _opaquePng(Uint8List rgba, int size) {
  final rows = BytesBuilder();
  for (var y = 0; y < size; y++) {
    rows.addByte(0);
    for (var x = 0; x < size; x++) {
      final offset = (y * size + x) * 4;
      assert(rgba[offset + 3] == 255);
      rows.add(rgba.sublist(offset, offset + 3));
    }
  }
  final out = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> payload) {
    final body = Uint8List.fromList([...ascii.encode(type), ...payload]);
    var crc = 0xFFFFFFFF;
    for (final byte in body) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB88320 : 0);
      }
    }
    final length = ByteData(4)..setUint32(0, payload.length);
    final checksum = ByteData(4)..setUint32(0, crc ^ 0xFFFFFFFF);
    out
      ..add(length.buffer.asUint8List())
      ..add(body)
      ..add(checksum.buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, size)
    ..setUint32(4, size)
    ..setUint8(8, 8)
    ..setUint8(9, 2);
  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', ZLibEncoder().convert(rows.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}
