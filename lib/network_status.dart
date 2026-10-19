import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum NetworkReachability { unknown, online, offline }

/// Android's default-network callbacks, not periodic HTTP probes. Brief network
/// handovers keep the current UI rather than hiding/showing tabs repeatedly.
class NetworkStatus extends ValueNotifier<NetworkReachability> {
  NetworkStatus({NetworkReachability initial = NetworkReachability.unknown})
    : super(initial);

  static const events = EventChannel('org.mewx.wenku8/network_events');
  static const methods = MethodChannel('org.mewx.wenku8/network_status');
  StreamSubscription<dynamic>? _subscription;
  Timer? _settle;
  bool _disposed = false;
  int _revision = 0;

  bool get offline => value == NetworkReachability.offline;

  Future<void> start() async {
    if (_disposed ||
        _subscription != null ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _subscription = events.receiveBroadcastStream().listen(
      (event) => accept(event, initial: _revision == 0),
      onError: (Object _) => accept(null),
    );
    final revision = _revision;
    try {
      final initial = await methods.invokeMethod<String>('current');
      if (!_disposed && revision == _revision) accept(initial, initial: true);
    } on PlatformException {
      // An unavailable platform signal is unknown, never proof of no network.
    } on MissingPluginException {
      // Non-device harnesses retain their explicitly supplied initial state.
    }
  }

  @visibleForTesting
  void accept(Object? event, {bool initial = false}) {
    if (_disposed) return;
    _revision++;
    _settle?.cancel();
    if (event == 'online') {
      value = NetworkReachability.online;
    } else if (event == 'offline' || event == 'checking') {
      if (initial && event == 'offline') {
        value = NetworkReachability.offline;
      } else {
        _settle = Timer(
          Duration(milliseconds: event == 'checking' ? 1800 : 700),
          () {
            if (!_disposed) value = NetworkReachability.offline;
          },
        );
      }
    } else {
      value = NetworkReachability.unknown;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _settle?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
