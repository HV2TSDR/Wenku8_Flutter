import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_ui.dart';
import 'local_platform.dart';

/// Only this small status line updates on a system time/battery broadcast. Reading
/// text, pagination and glass never rebuild to tick a clock.
class ReaderStatusFooter extends StatefulWidget {
  const ReaderStatusFooter({super.key});
  static const height = 24.0;
  // Reuse the cutout/status band, not another row below it. Time and battery
  // sit at opposite edges, leaving the camera/sensor area in the middle clear.
  static double heightFor(BuildContext context) => math.max(
    MediaQuery.viewPaddingOf(context).top,
    (MediaQuery.textScalerOf(context).scale(11) * 1.4 + 4).clamp(
      height,
      double.infinity,
    ),
  );
  static const events = EventChannel('org.mewx.wenku8/reader_status');
  @override
  State<ReaderStatusFooter> createState() => _ReaderStatusFooterState();
}

class _ReaderStatusFooterState extends State<ReaderStatusFooter>
    with WidgetsBindingObserver {
  StreamSubscription<dynamic>? _subscription;
  late DateTime _time = DateTime.now();
  int? _battery;
  bool _charging = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listen();
  }

  void _listen() {
    if (!LocalPlatform.android || _subscription != null) return;
    _subscription = ReaderStatusFooter.events.receiveBroadcastStream().listen((
      value,
    ) {
      if (!mounted || value is! Map) return;
      final milliseconds = value['time'];
      final battery = value['battery'];
      setState(() {
        if (milliseconds is int) {
          _time = DateTime.fromMillisecondsSinceEpoch(milliseconds);
        }
        _battery = battery is int && battery >= 0 && battery <= 100
            ? battery
            : null;
        _charging = value['charging'] == true;
      });
    }, onError: (Object _) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _listen();
    } else {
      _subscription?.cancel();
      _subscription = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final time =
        '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';
    return IgnorePointer(
      child: SizedBox(
        key: const ValueKey('reader-system-footer'),
        height: ReaderStatusFooter.heightFor(context),
        child: DefaultTextStyle.merge(
          style: TextStyle(
            fontSize: 11,
            height: 1.3,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          child: Row(
            children: [
              AppText(time, key: const ValueKey('reader-status-time')),
              const Spacer(),
              if (_charging) const Icon(CupertinoIcons.bolt_fill, size: 11),
              if (_battery != null) ...[
                const Icon(CupertinoIcons.battery_100, size: 15),
                const SizedBox(width: 5),
                AppText(
                  '$_battery%',
                  key: const ValueKey('reader-status-battery'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
