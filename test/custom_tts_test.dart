import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/listening/custom_tts.dart';
import 'package:wenku8_flutter/listening/models.dart';
import 'package:xml/xml.dart';

class _Vault implements SpeechConfigStorage {
  String? value;
  bool fail = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? next) async {
    if (fail) throw const FileSystemException('vault');
    value = next;
  }
}

// Redirect only the transport to a local fixture. The production HTTPS URL,
// protocol validation and complete request construction still execute.
class _FixtureClient implements HttpClient {
  _FixtureClient(this.address);
  final Uri address;
  final HttpClient delegate = HttpClient();
  @override
  set connectionTimeout(Duration? value) {
    delegate.connectionTimeout = value;
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) => delegate.postUrl(address);
  @override
  void close({bool force = false}) => delegate.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CustomSpeechConfig _config({
  String url = 'https://speech.example.test/cognitiveservices/v1',
  SpeechAuthentication auth = SpeechAuthentication.subscriptionKey,
}) => CustomSpeechConfig(
  endpoint: Uri.parse(url),
  voiceId: 'zh-CN-XiaoxiaoNeural',
  namespace: 'device-test-config-1',
  authentication: auth,
  secret: 'fixture-not-a-real-key',
);

void main() {
  test(
    'custom voice survives persistence and cache identity separates endpoint revisions',
    () async {
      final vault = _Vault(), config = _config();
      final settings = CustomSpeechSettings(storage: vault);
      await settings.save(config);
      final next = CustomSpeechSettings(storage: vault);
      await next.load();
      expect(next.config!.endpoint, config.endpoint);
      expect(next.config!.secret, config.secret);
      final restored = SpeechVoice.fromJson(
        jsonDecode(jsonEncode(config.voice.toJson())),
      );
      expect(restored.source, ListeningSource.custom);
      expect(restored.availableForListening, isTrue);
      const segment = SpeechSegment(0, 0, 2, '你好');
      expect(segment.key(restored), isNot(segment.key(defaultEdgeVoice)));
      expect(
        segment.key(restored),
        isNot(
          segment.key(
            const SpeechVoice(
              id: 'zh-CN-XiaoxiaoNeural',
              label: '新接口',
              source: ListeningSource.custom,
              engine: 'device-test-config-2',
            ),
          ),
        ),
      );
      vault.fail = true;
      await expectLater(
        settings.save(null),
        throwsA(isA<FileSystemException>()),
      );
      expect(settings.config, same(config));
    },
  );
  test('rejects insecure URLs, URL credentials and header injection', () {
    for (final url in [
      'http://speech.test/v1',
      'file:///tmp/a',
      'https://user:key@speech.test/v1',
    ]) {
      expect(() => _config(url: url).validate(), throwsFormatException);
    }
    expect(
      () => CustomSpeechConfig(
        endpoint: Uri.parse('https://speech.test'),
        voiceId: 'voice',
        namespace: 'n',
        secret: 'key\r\nHeader: value',
      ).validate(),
      throwsFormatException,
    );
  });
  test(
    'Microsoft-compatible SSML is escaped; POST headers and MP3 response are valid',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requestDone = server.first.then((request) async {
        expect(request.method, 'POST');
        expect(
          request.headers.value('Ocp-Apim-Subscription-Key'),
          'fixture-not-a-real-key',
        );
        expect(
          request.headers.value('X-Microsoft-OutputFormat'),
          'audio-24khz-48kbitrate-mono-mp3',
        );
        final xml = XmlDocument.parse(await utf8.decoder.bind(request).join());
        expect(xml.findAllElements('voice').single.innerText, '你好，A & B < C。');
        expect(
          xml.findAllElements('voice').single.getAttribute('name'),
          'zh-CN-XiaoxiaoNeural',
        );
        request.response.headers.contentType = ContentType('audio', 'mpeg');
        request.response.add([0x49, 0x44, 0x33, ...List.filled(128, 0)]);
        await request.response.close();
      });
      final client = CustomSpeechClient(
        clientFactory: () =>
            _FixtureClient(Uri.parse('http://127.0.0.1:${server.port}/v1')),
      );
      final bytes = await client.synthesize(
        '你好，A & B < C。',
        _config(),
        SpeechCancellation(),
      );
      expect(bytes.length, greaterThan(100));
      await requestDone;
    },
  );
  test(
    'authentication errors and redirects are not retried or exposed as audio',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var hits = 0;
      server.listen((request) async {
        hits++;
        await request.drain<void>();
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'http://127.0.0.1:${server.port}/other',
        );
        await request.response.close();
      });
      final client = CustomSpeechClient(
        clientFactory: () =>
            _FixtureClient(Uri.parse('http://127.0.0.1:${server.port}/v1')),
      );
      await expectLater(
        client.synthesize('你好', _config(), SpeechCancellation()),
        throwsA(
          isA<SpeechFailure>().having(
            (e) => e.message,
            'message',
            contains('重定向'),
          ),
        ),
      );
      expect(hits, 1);
    },
  );
}
