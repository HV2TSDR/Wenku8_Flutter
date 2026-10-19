import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/custom_tts.dart';
import 'package:wenku8_flutter/listening/custom_tts_page.dart';
import 'package:wenku8_flutter/listening/models.dart';
import 'package:wenku8_flutter/listening/store.dart';

import 'support/listening_fixture.dart';

class _Vault implements SpeechConfigStorage {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? record) async => value = record;
}

class _PendingSpeech extends CustomSpeechClient {
  final requests = <Completer<Uint8List>>[];
  final cancellations = <SpeechCancellation>[];
  @override
  Future<Uint8List> synthesize(
    String text,
    CustomSpeechConfig config,
    SpeechCancellation cancellation,
  ) {
    final pending = Completer<Uint8List>();
    requests.add(pending);
    cancellations.add(cancellation);
    return pending.future;
  }
}

void main() {
  late CustomSpeechSettings settings;
  late ListeningController controller;
  late _PendingSpeech client;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = CustomSpeechSettings(storage: _Vault());
    await settings.save(
      CustomSpeechConfig(
        endpoint: Uri.parse('https://speech.example.test/v1'),
        voiceId: 'zh-CN-XiaoxiaoNeural',
        namespace: 'preview-test',
      ),
    );
    client = _PendingSpeech();
  });
  tearDown(() {
    settings.dispose();
  });

  Future<void> open(WidgetTester tester) async {
    controller = ListeningController(
      repository: const DemoNovelRepository(),
      audio: FakeSpeechAudio(),
      store: ListeningStore(await SharedPreferences.getInstance()),
      outputFactory: (_) async => FakeListeningOutput(),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      final closing = controller.dispose();
      // The existing listening fixture crosses storage/command event loops.
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await closing;
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: CustomSpeechPage(
          settings: settings,
          controller: controller,
          client: client,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      find.text(label),
      180,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('stopping a pending preview cancels it and permits another try', (
    tester,
  ) async {
    await open(tester);
    await tap(tester, '试听接口');
    expect(client.requests, hasLength(1));
    expect(find.text('停止试听'), findsOneWidget);
    await tap(tester, '停止试听');
    expect(client.cancellations.first.cancelled, isTrue);
    expect(find.text('停止试听'), findsNothing);
    expect(find.text('试听接口'), findsOneWidget);
    expect(find.textContaining('接口操作未完成'), findsNothing);

    await tap(tester, '试听接口');
    expect(client.requests, hasLength(2));
    expect(client.cancellations.last.cancelled, isFalse);
    client.requests.first.completeError(StateError('late cancelled request'));
    await tester.pumpAndSettle();
    expect(find.text('正在试听'), findsOneWidget);
    expect(find.textContaining('接口操作未完成'), findsNothing);
    await tap(tester, '停止试听');
    client.requests.last.completeError(StateError('late second request'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving the configuration page cancels the pending request', (
    tester,
  ) async {
    await open(tester);
    await tap(tester, '试听接口');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(client.cancellations.single.cancelled, isTrue);
    client.requests.single.completeError(StateError('late page response'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a preview failure leaves the form ready to correct and retry', (
    tester,
  ) async {
    await open(tester);
    await tap(tester, '试听接口');
    client.requests.single.completeError(const SpeechFailure('音色不存在'));
    await tester.pumpAndSettle();
    expect(find.text('音色不存在'), findsOneWidget);
    expect(find.text('停止试听'), findsNothing);
    await tap(tester, '试听接口');
    expect(client.requests, hasLength(2));
    expect(find.text('音色不存在'), findsNothing);
    await tap(tester, '停止试听');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
