import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import '../app_interactions.dart';
import '../app_ui.dart';
import 'controller.dart';
import 'custom_tts.dart';
import 'models.dart';

class CustomSpeechPage extends StatefulWidget {
  const CustomSpeechPage({
    super.key,
    required this.settings,
    required this.controller,
    this.client,
  });
  final CustomSpeechSettings settings;
  final ListeningController controller;
  final CustomSpeechClient? client;
  @override
  State<CustomSpeechPage> createState() => _CustomSpeechPageState();
}

class _CustomSpeechPageState extends State<CustomSpeechPage> {
  final _endpoint = TextEditingController(),
      _voice = TextEditingController(),
      _locale = TextEditingController(),
      _label = TextEditingController(),
      _secret = TextEditingController();
  SpeechAuthentication _auth = SpeechAuthentication.none;
  SpeechCancellation? _previewCancel;
  bool _previewing = false;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final config = widget.settings.config;
    _endpoint.text = config?.endpoint.toString() ?? '';
    _voice.text = config?.voiceId ?? 'zh-CN-XiaoxiaoNeural';
    _locale.text = config?.locale ?? 'zh-CN';
    _label.text = config?.label ?? '自定义音色';
    _auth = config?.authentication ?? SpeechAuthentication.none;
    _secret.text = config?.secret ?? '';
    _error = widget.settings.error;
  }

  CustomSpeechConfig _draft() {
    final config = makeCustomSpeechConfig(
      endpoint: _endpoint.text,
      voice: _voice.text,
      locale: _locale.text,
      label: _label.text,
      authentication: _auth,
      secret: _auth == SpeechAuthentication.none ? '' : _secret.text,
    );
    config.validate();
    return config;
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on SpeechCancelled {
      // Stopping a preview or leaving this page is not an interface failure.
    } catch (failure) {
      if (mounted) {
        setState(
          () => _error = failure is FormatException
              ? failure.message
              : failure is SpeechFailure
              ? failure.message
              : '接口操作未完成，请检查配置后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _run(() async {
    final config = _draft();
    await widget.settings.save(config);
    await widget.controller.setVoice(config.voice);
    if (mounted) Navigator.pop(context);
  });
  Future<void> _preview() => _run(() async {
    final draft = _draft();
    final cancel = _previewCancel = SpeechCancellation();
    _previewing = true;
    Directory? folder;
    AudioPlayer? player;
    try {
      await cancel.wait(widget.controller.pause());
      final bytes = await cancel.wait(
        (widget.client ?? CustomSpeechClient()).synthesize(
          '你好，欢迎来到轻小说文库。让故事陪伴每一次阅读。',
          draft,
          cancel,
        ),
      );
      cancel.check();
      folder = await Directory(
        (await getTemporaryDirectory()).path,
      ).createTemp('wenku-speech-preview-');
      final file = File('${folder.path}/sample.mp3');
      await file.writeAsBytes(bytes, flush: true);
      cancel.check();
      player = AudioPlayer();
      await cancel.wait(player.setFilePath(file.path));
      cancel.check();
      await cancel.wait(player.play());
    } finally {
      try {
        await player?.dispose();
      } finally {
        if (folder != null) {
          await folder
              .delete(recursive: true)
              .catchError((Object _) => folder!);
        }
        _previewCancel = null;
        _previewing = false;
      }
    }
  });
  Future<void> _reset() => _run(() async {
    await widget.controller.setVoice(defaultEdgeVoice);
    await widget.settings.save(null);
    if (mounted) {
      showNovelFeedback(context, '已移除自定义接口，使用自然在线');
      Navigator.pop(context);
    }
  });
  @override
  void dispose() {
    _previewCancel?.cancel();
    for (final c in [_endpoint, _voice, _locale, _label, _secret]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(
    String title,
    TextEditingController controller, {
    String? hint,
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        CupertinoTextField(
          controller: controller,
          enabled: !_busy,
          placeholder: hint,
          obscureText: secret,
          autocorrect: false,
          enableSuggestions: !secret,
          keyboardType: title.contains('地址')
              ? TextInputType.url
              : TextInputType.text,
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: .045),
            borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Atmosphere(
      child: GlassHeaderLayout(
        header: ArchiveHeaderBar(
          leading: GlassIconButton(
            icon: CupertinoIcons.back,
            label: '返回',
            onPressed: () => Navigator.pop(context),
          ),
          title: const ArchiveRouteTitle(
            title: '自定义语音接口',
            code: 'READER / SPEECH ENDPOINT',
          ),
        ),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            24,
            MediaQuery.paddingOf(context).top +
                FrostedHeader.toolbarHeight +
                20,
            24,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: [
            const ArchiveSection(
              title: '用自己的声音服务',
              code: 'MICROSOFT SSML / HTTPS',
            ),
            const SizedBox(height: 14),
            const AppText(
              '支持 Microsoft Azure 及兼容的 SSML 合成接口。填写完整的 POST 地址，输出格式为 MP3。',
              style: TextStyle(height: 1.65),
            ),
            const SizedBox(height: 22),
            _field(
              '合成地址',
              _endpoint,
              hint: 'https://服务地址/cognitiveservices/v1',
            ),
            _field('音色 ID', _voice),
            _field('显示名称', _label),
            _field('语言', _locale),
            const AppText(
              '认证方式',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            AppControls.segments<SpeechAuthentication>(
              context,
              groupValue: _auth,
              children: const {
                SpeechAuthentication.none: AppText('无认证'),
                SpeechAuthentication.subscriptionKey: AppText('Azure Key'),
                SpeechAuthentication.bearer: AppText('Bearer'),
              },
              onValueChanged: (value) {
                if (!_busy && value != null) setState(() => _auth = value);
              },
            ),
            const SizedBox(height: 18),
            AnimatedOptionSection(
              expanded: _auth != SpeechAuthentication.none,
              child: _field(
                _auth == SpeechAuthentication.subscriptionKey ? '订阅密钥' : '访问令牌',
                _secret,
                secret: true,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: AppText(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            GlassPillButton(
              icon: CupertinoIcons.checkmark,
              label: _busy && !_previewing ? '正在保存' : '保存并使用',
              onPressed: _busy ? null : _save,
            ),
            GlassTextButton(
              onPressed: _busy ? null : _preview,
              child: AppText(_previewing ? '正在试听' : '试听接口'),
            ),
            if (_previewing)
              GlassTextButton(
                onPressed: () => _previewCancel?.cancel(),
                child: const AppText('停止试听'),
              ),
            const AppText(
              '试听会发送一条测试句；接口可能按提供方规则计费。密钥仅加密保存在本机，不进入书库备份与云同步。',
              style: TextStyle(fontSize: 12, height: 1.6),
            ),
            if (widget.settings.config != null)
              GlassTextButton(
                onPressed: _busy ? null : _reset,
                child: const AppText('移除自定义接口'),
              ),
          ],
        ),
      ),
    ),
  );
}
