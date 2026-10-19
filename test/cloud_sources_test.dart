import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/cloud_sources.dart';

class MemoryCloudVault implements CloudConfigStorage {
  String? value;
  bool fail = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? next) async {
    if (fail) throw const FileSystemException('fixture write failed');
    value = next;
  }
}

class FixtureHttpClient implements HttpClient {
  FixtureHttpClient(this.port);
  final int port;
  final delegate = HttpClient();
  @override
  set connectionTimeout(Duration? value) {
    delegate.connectionTimeout = value;
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) => delegate.openUrl(
    method,
    Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: uri.path,
      query: uri.hasQuery ? uri.query : null,
    ),
  );
  @override
  void close({bool force = false}) => delegate.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const davConfig = CloudSourceConfig(
  kind: CloudSourceKind.webdav,
  address: 'https://books.example.test/dav/小说/',
  username: 'reader',
  password: 'local-fixture-secret',
);
const quarkConfig = CloudSourceConfig(
  kind: CloudSourceKind.quark,
  cookie: '__pus=fixture-user; __puus=fixture-session',
);

void main() {
  test(
    'separate encrypted records persist both providers; failed save retains old state',
    () async {
      final vault = MemoryCloudVault(),
          settings = CloudSourceSettings(storage: MemoryCloudVault());
      settings.dispose();
      final a = CloudSourceSettings(storage: vault);
      addTearDown(a.dispose);
      await Future.wait([
        a.save(CloudSourceKind.webdav, davConfig),
        a.save(CloudSourceKind.quark, quarkConfig),
      ]);
      final b = CloudSourceSettings(storage: vault);
      addTearDown(b.dispose);
      await b.load();
      expect(b[CloudSourceKind.webdav]!.password, davConfig.password);
      expect(b[CloudSourceKind.quark]!.cookie, quarkConfig.cookie);
      vault.fail = true;
      await expectLater(
        a.save(CloudSourceKind.quark, null),
        throwsA(isA<FileSystemException>()),
      );
      expect(a[CloudSourceKind.quark], isNotNull);
      vault.fail = false;
      await a.save(CloudSourceKind.quark, null);
      await a.rotate(quarkConfig, '__puus=late-response');
      expect(a[CloudSourceKind.quark], isNull);
      expect(vault.value, isNot(contains('fixture-session')));
    },
  );
  test(
    'rejects URL credentials, header injection and accidental cleartext',
    () {
      for (final value in [
        const CloudSourceConfig(
          kind: CloudSourceKind.webdav,
          address: 'http://books.test/dav/',
        ),
        const CloudSourceConfig(
          kind: CloudSourceKind.webdav,
          address: 'https://u:p@books.test/dav/',
        ),
        const CloudSourceConfig(
          kind: CloudSourceKind.webdav,
          address: 'https://books.test/dav/?token=x',
        ),
        const CloudSourceConfig(
          kind: CloudSourceKind.webdav,
          address: 'https://books.test/dav/',
          password: 'a\r\nCookie: x',
        ),
        const CloudSourceConfig(
          kind: CloudSourceKind.quark,
          cookie: '__puus=a\nHeader: x',
        ),
        const CloudSourceConfig(kind: CloudSourceKind.quark, cookie: 'other=x'),
      ]) {
        expect(value.validate, throwsA(isA<CloudSourceFailure>()));
      }
      const CloudSourceConfig(
        kind: CloudSourceKind.webdav,
        address: 'http://books.example.test:5244/dav/',
        allowHttp: true,
      ).validate();
    },
  );
  test(
    'DAV namespace, encoded names, failed props and root confinement',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var hits = 0;
      server.listen((req) async {
        hits++;
        expect(req.method, 'PROPFIND');
        expect(req.headers.value('Depth'), '1');
        expect(
          req.headers.value('Authorization'),
          'Basic ${base64Encode(utf8.encode('reader:local-fixture-secret'))}',
        );
        expect(await utf8.decoder.bind(req).join(), contains('resourcetype'));
        req.response.statusCode = 207;
        req.response.write('''<X:multistatus xmlns:X="DAV:">
        <X:response><X:href>/dav/小说/</X:href><X:propstat><X:prop><X:resourcetype><X:collection/></X:resourcetype></X:prop><X:status>HTTP/1.1 200 OK</X:status></X:propstat></X:response>
        <X:response><X:href>/dav/小说/卷一/</X:href><X:propstat><X:prop><X:resourcetype><X:collection/></X:resourcetype></X:prop><X:status>HTTP/1.1 200 OK</X:status></X:propstat></X:response>
        <X:response><X:href>/dav/小说/A%20%26%20B.epub</X:href><X:propstat><X:prop><X:displayname>A &amp; B.epub</X:displayname><X:getcontentlength>1024</X:getcontentlength></X:prop><X:status>HTTP/1.1 200 OK</X:status></X:propstat></X:response>
        <X:response><X:href>/dav/小说/no.txt</X:href><X:propstat><X:prop/><X:status>HTTP/1.1 403 Forbidden</X:status></X:propstat></X:response>
        <X:response><X:href>https://elsewhere.test/evil.txt</X:href></X:response>
        <X:response><X:href>/dav/other/escape.txt</X:href></X:response>
        <X:response><X:href>/dav/小说/卷一/nested.txt</X:href></X:response>
      </X:multistatus>''');
        await req.response.close();
      });
      final client = WebDavBookClient(
        davConfig,
        http: CloudHttp(clientFactory: () => FixtureHttpClient(server.port)),
      );
      addTearDown(client.close);
      final listing = await client.list(client.root);
      expect(listing.entries.map((e) => e.name), ['卷一', 'A & B.epub']);
      expect(listing.entries.last.size, 1024);
      expect(listing.entries.last.id, contains('A%20%26%20B.epub'));
      await expectLater(
        client.list('https://books.example.test/dav/other/'),
        throwsA(isA<CloudSourceFailure>()),
      );
      await expectLater(
        client.list('https://books.example.test/dav/小说/%2e%2e/other/'),
        throwsA(isA<CloudSourceFailure>()),
      );
      expect(hits, 1);
    },
  );
  test(
    'DAV download redirect strips Basic credentials and imports actual bytes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final root = await Directory.systemTemp.createTemp('cloud-transfer-');
      addTearDown(() => root.delete(recursive: true));
      var hits = 0;
      server.listen((req) async {
        hits++;
        if (req.uri.path == '/download') {
          expect(req.headers.value('Authorization'), isNull);
          expect(req.headers.value('Cookie'), isNull);
          req.response.add(utf8.encode('第一章\n你好，书库。'));
        } else {
          expect(req.headers.value('Authorization'), isNotNull);
          req.response.statusCode = 302;
          req.response.headers.set(
            'Location',
            'https://cdn.example.test/download?signature=fixture',
          );
        }
        await req.response.close();
      });
      final client = WebDavBookClient(
        davConfig,
        http: CloudHttp(clientFactory: () => FixtureHttpClient(server.port)),
      );
      addTearDown(client.close);
      final output = File('${root.path}/download');
      await client.download(
        CloudBookEntry(id: '${client.root}书.txt', name: '书.txt', folder: false),
        output,
      );
      expect(await output.readAsString(), '第一章\n你好，书库。');
      expect(hits, 2);
    },
  );
  test(
    'Quark paginates even a page without books, rotates __puus, and uses only download/list APIs',
    () async {
      final vault = MemoryCloudVault(),
          settings = CloudSourceSettings(storage: MemoryCloudVault());
      settings.dispose();
      final saved = CloudSourceSettings(storage: vault);
      addTearDown(saved.dispose);
      await saved.save(CloudSourceKind.quark, quarkConfig);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final root = await Directory.systemTemp.createTemp('quark-transfer-');
      addTearDown(() => root.delete(recursive: true));
      final calls = <String>[];
      server.listen((req) async {
        calls.add(req.uri.path);
        if (req.uri.path.endsWith('/sort')) {
          expect(req.uri.queryParameters['pr'], 'ucpro');
          expect(req.uri.queryParameters['fr'], 'pc');
          final second = req.uri.queryParameters['_page'] == '2';
          if (second) {
            expect(req.headers.value('Cookie'), contains('__puus=rotated'));
          }
          req.response.cookies.add(Cookie('__puus', 'rotated'));
          req.response.write(
            jsonEncode({
              'code': 0,
              'status': 200,
              'data': {
                'list': second
                    ? [
                        {
                          'fid': 'novel-1',
                          'file_name': '书.txt',
                          'file': true,
                          'size': 24,
                        },
                      ]
                    : [
                        {
                          'fid': 'other',
                          'file_name': 'photo.jpg',
                          'file': true,
                        },
                      ],
              },
              'metadata': {'_total': 101},
            }),
          );
        } else if (req.uri.path.endsWith('/file/download')) {
          expect(req.method, 'POST');
          expect(jsonDecode(await utf8.decoder.bind(req).join()), {
            'fids': ['novel-1'],
          });
          expect(req.headers.value('Cookie'), contains('__puus=rotated'));
          req.response.write(
            jsonEncode({
              'code': 0,
              'status': 200,
              'data': [
                {'download_url': 'https://cdn.external.test/book'},
              ],
            }),
          );
        } else {
          expect(req.uri.path, '/book');
          expect(req.headers.value('Cookie'), isNull);
          req.response.add(utf8.encode('第一章\n云端原文。'));
        }
        await req.response.close();
      });
      final client = QuarkBookClient(
        quarkConfig,
        settings: saved,
        http: CloudHttp(clientFactory: () => FixtureHttpClient(server.port)),
      );
      addTearDown(client.close);
      final first = await client.list('0');
      expect(first.entries, isEmpty);
      expect(first.nextPage, 2);
      final second = await client.list('0', page: first.nextPage!);
      expect(second.nextPage, isNull);
      final target = File('${root.path}/book');
      await client.download(second.entries.single, target);
      expect(await target.readAsString(), '第一章\n云端原文。');
      expect(saved[CloudSourceKind.quark]!.cookie, contains('__puus=rotated'));
      expect(calls, [
        '/1/clouddrive/file/sort',
        '/1/clouddrive/file/sort',
        '/1/clouddrive/file/download',
        '/book',
      ]);
    },
  );
  test(
    'authentication failures are not retried or echoed; unsafe redirects and oversized books fail',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final root = await Directory.systemTemp.createTemp('cloud-errors-');
      addTearDown(() => root.delete(recursive: true));
      var hits = 0, mode = 0;
      server.listen((req) async {
        hits++;
        await req.drain<void>();
        if (mode == 0) {
          req.response.statusCode = 401;
          req.response.write('secret echoed should never surface');
        }
        if (mode == 1) {
          req.response.statusCode = 302;
          req.response.headers.set('Location', 'http://unsafe.test/secret');
        }
        if (mode == 2) {
          req.response.contentLength = CloudHttp.maxBookBytes + 1;
          req.response.add([0]);
          await req.response.flush();
        }
        try {
          await req.response.close();
        } catch (_) {
          /* Client deliberately aborts. */
        }
      });
      final client = WebDavBookClient(
        davConfig,
        http: CloudHttp(clientFactory: () => FixtureHttpClient(server.port)),
      );
      addTearDown(client.close);
      await expectLater(
        client.list(client.root),
        throwsA(
          isA<CloudSourceFailure>().having(
            (e) => e.authentication,
            'authentication',
            isTrue,
          ),
        ),
      );
      expect(hits, 1);
      const entry = CloudBookEntry(
        id: 'https://books.example.test/dav/小说/书.txt',
        name: '书.txt',
        folder: false,
      );
      mode = 1;
      await expectLater(
        client.download(entry, File('${root.path}/bad')),
        throwsA(isA<CloudSourceFailure>()),
      );
      expect(hits, 2);
      mode = 2;
      await expectLater(
        client.download(entry, File('${root.path}/large')),
        throwsA(isA<CloudSourceFailure>()),
      );
      expect(await File('${root.path}/large').exists(), isFalse);
      client.cancel();
      await expectLater(
        client.list(client.root),
        throwsA(isA<CloudTransferCancelled>()),
      );
    },
  );
}
