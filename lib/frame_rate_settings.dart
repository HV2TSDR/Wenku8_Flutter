import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_ui.dart';
import 'glass_choices.dart';

class DisplayRateInfo {
  const DisplayRateInfo(this.target, this.current, this.rates);
  factory DisplayRateInfo.fromMap(Map<dynamic, dynamic> value) =>
      DisplayRateInfo(
        (value['target'] as num).toDouble(),
        (value['current'] as num).toDouble(),
        (value['rates'] as List).cast<num>().map((n) => n.toDouble()).toList(),
      );
  final double target, current;
  final List<double> rates;
}

class FrameRateSettings extends ChangeNotifier {
  FrameRateSettings({
    this.channel = const MethodChannel('org.mewx.wenku8/frame_rate'),
  }) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') {
        if (busy) {
          _pending = true;
        } else if (hasListeners) {
          await load();
        }
      }
    });
  }
  static final shared = FrameRateSettings();
  final MethodChannel channel;
  DisplayRateInfo? info;
  bool busy = false, _disposed = false, _pending = false;
  String? error;
  Future<void> load() => _request('info');
  Future<void> select(double target) => _request('set', {'target': target});
  Future<void> _request(String method, [Map<String, Object>? arguments]) async {
    if (busy || _disposed) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final value = await channel.invokeMapMethod<dynamic, dynamic>(
        method,
        arguments,
      );
      if (!_disposed) info = DisplayRateInfo.fromMap(value!);
    } catch (failure) {
      if (!_disposed) {
        error = failure is PlatformException
            ? failure.message ?? '刷新率读取失败，请重试'
            : '刷新率读取失败，请重试';
      }
    } finally {
      busy = false;
      if (!_disposed) {
        notifyListeners();
        if (_pending) {
          _pending = false;
          unawaited(load());
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}

String displayRateLabel(double rate) =>
    '${(rate - rate.round()).abs() < .15 ? rate.round() : rate.toStringAsFixed(1)} Hz';

class FrameRateOptions extends StatefulWidget {
  const FrameRateOptions({super.key, this.settings});
  final FrameRateSettings? settings;
  @override
  State<FrameRateOptions> createState() => _FrameRateOptionsState();
}

class _FrameRateOptionsState extends State<FrameRateOptions>
    with WidgetsBindingObserver {
  late final settings = widget.settings ?? FrameRateSettings.shared;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(settings.load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(settings.load());
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: settings,
    builder: (context, _) {
      final info = settings.info;
      return ContentPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(CupertinoIcons.speedometer, size: 20),
                SizedBox(width: 10),
                AppText(
                  '帧率偏好',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            if (info != null) ...[
              GlassChoiceGroup<double>(
                name: 'frame-rate',
                label: '滚动与动效',
                value: info.target,
                options: {
                  0: '自动高刷',
                  -1: '系统调度',
                  for (final rate in info.rates) rate: displayRateLabel(rate),
                  if (info.target > 0 && !info.rates.contains(info.target))
                    info.target: '${displayRateLabel(info.target)} · 暂不可用',
                },
                optionName: (rate) => rate.toString(),
                onChanged: (rate) {
                  if (!settings.busy) unawaited(settings.select(rate));
                },
              ),
              const SizedBox(height: 6),
              AppText(
                '屏幕模式 ${displayRateLabel(info.current)}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ] else if (settings.busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: InlineSkeleton(width: 160, height: 16, label: '正在读取刷新率'),
              ),
            const SizedBox(height: 10),
            const AppText(
              '高帧率适合滚动与翻页，较低帧率更省电。省电模式和温控可能限制系统实际采用的刷新率。',
              style: TextStyle(fontSize: 12, height: 1.6),
            ),
            if (settings.error != null) ...[
              const SizedBox(height: 8),
              AppText(settings.error!, style: const TextStyle(fontSize: 12)),
              GlassTextButton(
                onPressed: settings.busy ? null : settings.load,
                child: const AppText('重新读取'),
              ),
            ],
          ],
        ),
      );
    },
  );
}
