import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:wenku8_flutter/catalog.dart';

const coverFixtureBook = Novel(
  id: 752,
  title: '书页与微光',
  author: '作者',
  genre: '奇幻 冒险',
  summary: '封面查看回归样本。',
  colors: [Colors.grey, Colors.black],
  coverUrl: 'https://cover.wenku8.com/752.jpg',
);

Future<Uint8List> coverFixturePicture() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 40, 60),
    Paint()..color = Colors.blueGrey,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(40, 60);
  final bytes = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}
