import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/feature_pages.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/network_status.dart';
import 'package:wenku8_flutter/wenku_account.dart';
import 'package:wenku8_flutter/wenku_features.dart';
import 'package:wenku8_flutter/wenku_shelf_sync.dart';

void main() {
  testWidgets(
    'login, shelf edits, reconnect and resume synchronize without manual merge buttons',
    (tester) async {
      SharedPreferences.setMockInitialValues({'reduceMotion': true});
      final prefs = await SharedPreferences.getInstance(),
          library = await LibraryState.load();
      final network = NetworkStatus(initial: NetworkReachability.online),
          remote = <int>{72};
      bool session = false;
      final account = WenkuAccount(
        hasSession: () async => session,
        loginRequest: (_) async {
          session = true;
          return '1';
        },
        clearSession: () async => session = false,
        avatarRequest: () async => Uint8List(0),
        request: (action) async {
          if (action == 'action=userinfo') {
            return '<metadata><item name="uid">321</item><item name="uname">reader</item></metadata>';
          }
          final query = Uri.splitQueryString(action);
          if (query['do'] == null) {
            return '<metadata>${remote.map((id) => '<book aid="$id"><name>Book $id</name></book>').join()}</metadata>';
          }
          final id = int.parse(query['aid']!);
          query['do'] == 'add' ? remote.add(id) : remote.remove(id);
          return '1';
        },
      );
      final sync = WenkuShelfSync(
        account: account,
        library: library,
        preferences: prefs,
        network: network,
      )..start();
      bool syncDisposed = false;
      addTearDown(() {
        if (!syncDisposed) sync.dispose();
        account.dispose();
        library.dispose();
        network.dispose();
      });
      Future<void> scheduled() async {
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pumpAndSettle();
      }

      await library.addShelfIds([71]);
      await account.initialize();
      await account.login('fixture-reader', 'fixture-password');
      await scheduled();
      expect(remote, {71, 72});
      expect(library.shelf, {71, 72});
      expect(sync.error, isNull);
      await library.setShelfMembership(71, false);
      await scheduled();
      expect(remote, {72});
      network.value = NetworkReachability.offline;
      await library.addShelfIds([73]);
      await scheduled();
      expect(remote, {72});
      network.value = NetworkReachability.online;
      await scheduled();
      expect(remote, {72, 73});
      sync.didChangeAppLifecycleState(AppLifecycleState.paused);
      remote.add(74);
      sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await scheduled();
      expect(library.shelf, {72, 73, 74});
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          builder: (_, child) => WenkuFeaturesScope(
            features: WenkuFeatures(
              account: account,
              publications: LegacyWenkuRepository(request: (_) async => ''),
              shelfSync: sync,
            ),
            child: child!,
          ),
          home: CloudBookshelfPage(
            account: account,
            state: library,
            repository: LegacyWenkuRepository(request: (_) async => ''),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cloud-download')), findsNothing);
      expect(find.byKey(const ValueKey('cloud-upload')), findsNothing);
      expect(find.textContaining('自动同步'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      sync.dispose();
      syncDisposed = true;
      await tester.pump();
    },
  );
}
