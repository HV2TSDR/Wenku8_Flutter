import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_library_page.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/listening/audio_output.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/models.dart';
import 'package:wenku8_flutter/listening/store.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_status.dart';
import '../test/reader_modes_test.dart' as fixture;
import '../test/collection_inertia_test.dart' as inertia;
import '../test/support/listening_fixture.dart';

class _SilentAudio extends FakeSpeechAudio {
  _SilentAudio(this.file);
  final File file;
  @override
  Future<File> prepare(
    SpeechSegment segment,
    SpeechVoice voice,
    SpeechCancellation cancellation,
  ) async {
    cancellation.check();
    return file;
  }
}

class _PendingBook extends DemoNovelRepository {
  final ready = Completer<Novel>();
  @override
  Future<Novel> detail(Novel novel) => ready.future;
  @override
  Future<List<NovelChapter>> chapters(int id) async => fixture.book.chapters;
}

Uint8List _silence() {
  const rate = 16000, seconds = 6, length = rate * seconds * 2;
  final bytes = ByteData(44 + length);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, 36 + length, Endian.little);
  text(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, length, Endian.little);
  return bytes.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native chrome reflow capture in each reading mode',
    (tester) async {
      for (final mode in ReaderMode.values) {
        final state = await fixture.library(mode);
        await state.setReduceMotion(false);
        await tester.pumpWidget(fixture.app(state));
        await fixture.settleReader(tester);
        if (mode.paginated) {
          tester
              .widget<ReaderPagedView>(find.byType(ReaderPagedView))
              .controller
              .seek(.4);
          await fixture.settleReader(tester);
        }
        debugPrint('READER54_CAPTURE ${mode.name} visible');
        await Future<void>.delayed(const Duration(seconds: 2));
        for (final phase in ['hide', 'show', 'hide', 'show']) {
          debugPrint('READER54_CAPTURE ${mode.name} $phase');
          await tester.tapAt(tester.getCenter(fixture.content()));
          await fixture.settleReader(tester);
          await Future<void>.delayed(const Duration(milliseconds: 800));
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      }
      debugPrint('READER54_CAPTURE_DONE');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  testWidgets(
    'native fullscreen status and collection inertia verification',
    (tester) async {
      final state = await fixture.library(ReaderMode.scroll);
      await state.setReaderChromeVisible(false);
      await state.setReduceMotion(false);
      await state.setReaderPreferences(
        state.readerPreferences.copyWith(hideSystemStatus: true),
      );
      final repository = _PendingBook();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: ReaderLoaderPage(
            novel: fixture.book,
            state: state,
            repository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FrostedHeader), findsNothing);
      debugPrint('READER54_CHECKPOINT loading-hidden');
      await Future<void>.delayed(const Duration(seconds: 2));
      repository.ready.complete(fixture.book);
      await fixture.settleReader(tester);
      final status = tester.state(find.byType(ReaderStatusFooter));
      for (final mode in ReaderMode.values) {
        await state.setReaderPreferences(
          state.readerPreferences.copyWith(mode: mode),
        );
        await fixture.settleReader(tester);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
        expect(tester.state(find.byType(ReaderStatusFooter)), same(status));
        final time = tester.getRect(
          find.byKey(const ValueKey('reader-status-time')),
        );
        final battery = tester.getRect(
          find.byKey(const ValueKey('reader-status-battery')),
        );
        final chapter = tester.getRect(
          find.byKey(const ValueKey('reader-chapter-title')).first,
        );
        final statusBand = tester.getRect(find.byType(ReaderStatusFooter));
        expect(time.center.dy, closeTo(battery.center.dy, 1));
        expect(statusBand.top, 0);
        expect(chapter.top, greaterThanOrEqualTo(statusBand.bottom));
        if (mode.paginated) {
          final count = tester.getRect(
            find.byKey(const ValueKey('reader-page-count')),
          );
          expect(count.center.dy, closeTo(chapter.center.dy, 1));
        }
        expect(time.top, lessThan(40));
        debugPrint('READER54_CHECKPOINT ${mode.name}-hidden');
        await Future<void>.delayed(const Duration(seconds: 2));
        await tester.tapAt(tester.getCenter(fixture.content()));
        await fixture.settleReader(tester);
        expect(
          tester.getRect(find.byType(ArchiveHeaderBar)).top,
          greaterThanOrEqualTo(
            tester.getRect(find.byType(ReaderStatusFooter)).bottom,
          ),
        );
        debugPrint('READER54_CHECKPOINT ${mode.name}-shown');
        await Future<void>.delayed(const Duration(seconds: 2));
        await tester.tapAt(tester.getCenter(fixture.content()));
        await fixture.settleReader(tester);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      for (final scene in ['discover', 'shelf', 'local']) {
        SharedPreferences.setMockInitialValues({});
        final library = await LibraryState.load(),
            local = inertia.InertiaLocalBooks();
        if (scene == 'shelf') {
          for (final book in inertia.inertiaBooks) {
            await library.setShelfMembership(book.id, true, novel: book);
          }
        }
        final page = switch (scene) {
          'discover' => DiscoverPage(
            books: inertia.inertiaBooks,
            state: library,
            repository: const DemoNovelRepository(),
            onSearch: () {},
          ),
          'shelf' => ShelfPage(
            books: inertia.inertiaBooks,
            state: library,
            repository: const DemoNovelRepository(),
          ),
          _ => LocalLibraryPage(
            books: local,
            state: library,
            onOpen: (_, _) {},
          ),
        };
        await tester.pumpWidget(
          MaterialApp(
            theme: novelTheme(Brightness.light),
            scrollBehavior: const NovelScrollBehavior(),
            home: Scaffold(body: Atmosphere(shareGlass: true, child: page)),
          ),
        );
        await tester.pumpAndSettle();
        final scroll = find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .first;
        final position = tester.state<ScrollableState>(scroll).position;
        position.jumpTo(650);
        await tester.pumpAndSettle();
        debugPrint('READER54_CHECKPOINT $scene-inertia');
        (position as ScrollPositionWithSingleContext).goBallistic(900);
        var previous = position.pixels;
        for (var i = 0; i < 50; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(position.pixels, greaterThanOrEqualTo(previous));
          previous = position.pixels;
        }
        await tester.pumpAndSettle();
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        local.dispose();
        library.dispose();
      }
      debugPrint('READER54_NATIVE_FULLSCREEN_DONE');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  testWidgets(
    'native audio applies 3x speed across consecutive clips',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Native audio timing fixture')),
          ),
        ),
      );
      SharedPreferences.setMockInitialValues({});
      final file = File(
        '${(await getTemporaryDirectory()).path}/reader54-silence.wav',
      );
      await file.writeAsBytes(_silence());
      final controller = ListeningController(
        repository: const DemoNovelRepository(),
        audio: _SilentAudio(file),
        store: ListeningStore(await SharedPreferences.getInstance()),
        outputFactory: (controller) async {
          final native = NativeListeningOutput(controller);
          await native.initialize();
          return native;
        },
      );
      final completed = Completer<void>(), playing = <int>{};
      controller.snapshot.addListener(() {
        final state = controller.snapshot.value;
        if (state.phase == ListeningPhase.playing) {
          expect(state.speed, 3);
          playing.add(state.current!.paragraph);
        }
        if (state.phase == ListeningPhase.completed && !completed.isCompleted) {
          completed.complete();
        }
        if (state.phase == ListeningPhase.failed && !completed.isCompleted) {
          completed.completeError(
            StateError(state.error ?? 'native audio failed'),
          );
        }
      });
      try {
        await controller.setSpeed(3);
        final watch = Stopwatch()..start();
        await controller.start(
          demoNovels.first.withChapters([
            const NovelChapter('连续播放', '第一段。\n\n第二段。', id: 54001),
          ]),
          chapter: 0,
        );
        await completed.future.timeout(const Duration(seconds: 10));
        watch.stop();
        expect(playing, {0, 1});
        expect(watch.elapsedMilliseconds, inInclusiveRange(2000, 6500));
        expect(controller.store.speed, 3);
        debugPrint(
          'READER54_NATIVE_SPEED clips=2 source_ms=12000 speed=3 elapsed_ms=${watch.elapsedMilliseconds}',
        );
      } finally {
        await controller.dispose();
        await file.delete();
      }
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
