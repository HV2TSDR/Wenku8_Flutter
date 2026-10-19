import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';
import 'edge_tts.dart';
import 'models.dart';

enum SpeechAuthentication { none, subscriptionKey, bearer }

class CustomSpeechConfig {
  const CustomSpeechConfig({
    required this.endpoint,
    required this.voiceId,
    required this.namespace,
    this.locale = 'zh-CN',
    this.label = '自定义音色',
    this.authentication = SpeechAuthentication.none,
    this.secret = '',
  });
  final Uri endpoint;
  final String voiceId, namespace, locale, label, secret;
  final SpeechAuthentication authentication;
  SpeechVoice get voice => SpeechVoice(
    id: voiceId,
    label: label,
    source: ListeningSource.custom,
    locale: locale,
    engine: namespace,
  );
  void validate() {
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasFragment ||
        endpoint.toString().length > 2048) {
      throw const FormatException('请填写完整的 HTTPS 语音合成地址');
    }
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,160}$').hasMatch(voiceId) ||
        !RegExp(
          r'^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}$',
        ).hasMatch(locale) ||
        namespace.isEmpty ||
        label.trim().isEmpty ||
        label.length > 80) {
      throw const FormatException('请检查音色 ID、语言代码和名称');
    }
    if (secret.length > 8192 ||
        RegExp(r'[\r\n\x00]').hasMatch(secret) ||
        (authentication != SpeechAuthentication.none &&
            secret.trim().isEmpty)) {
      throw const FormatException('请填写有效的密钥或令牌');
    }
  }

  Map<String, Object> toSecureRecord() => {
    'endpoint': endpoint.toString(),
    'voice': voiceId,
    'namespace': namespace,
    'locale': locale,
    'label': label,
    'authentication': authentication.name,
    'secret': secret,
  };
  factory CustomSpeechConfig.fromSecureRecord(Map<String, dynamic> json) {
    final config = CustomSpeechConfig(
      endpoint: Uri.parse(json['endpoint']),
      voiceId: json['voice'],
      namespace: json['namespace'],
      locale: json['locale'],
      label: json['label'],
      authentication: SpeechAuthentication.values.firstWhere(
        (a) => a.name == json['authentication'],
      ),
      secret: json['secret'],
    );
    config.validate();
    return config;
  }
}

abstract interface class SpeechConfigStorage {
  Future<String?> read();
  Future<void> write(String? value);
}

class AndroidSpeechConfigStorage implements SpeechConfigStorage {
  static const channel = MethodChannel('org.mewx.wenku8/custom_speech');
  @override
  Future<String?> read() => channel.invokeMethod<String>('read');
  @override
  Future<void> write(String? value) =>
      channel.invokeMethod<void>('write', value);
}

class CustomSpeechSettings extends ChangeNotifier {
  CustomSpeechSettings({SpeechConfigStorage? storage})
    : storage = storage ?? AndroidSpeechConfigStorage();
  final SpeechConfigStorage storage;
  CustomSpeechConfig? config;
  String? error;
  Future<void> load() async {
    try {
      final record = await storage.read();
      config = record == null
          ? null
          : CustomSpeechConfig.fromSecureRecord(jsonDecode(record));
      error = null;
    } catch (_) {
      error = '无法读取本机语音配置，请重新保存接口';
    }
    notifyListeners();
  }

  Future<void> save(CustomSpeechConfig? value) async {
    value?.validate();
    await storage.write(
      value == null ? null : jsonEncode(value.toSecureRecord()),
    );
    config = value;
    error = null;
    notifyListeners();
  }
}

/// Microsoft REST SSML protocol. Never forward credentials on redirects or log
/// endpoint response bodies (which may echo submitted text or credentials).
class CustomSpeechClient {
  CustomSpeechClient({HttpClient Function()? clientFactory})
    : clientFactory = clientFactory ?? HttpClient.new;
  final HttpClient Function() clientFactory;
  String ssml(String text, CustomSpeechConfig config) {
    final builder = XmlBuilder();
    builder.element(
      'speak',
      attributes: {
        'version': '1.0',
        'xmlns': 'http://www.w3.org/2001/10/synthesis',
        'xml:lang': config.locale,
      },
      nest: () => builder.element(
        'voice',
        attributes: {'name': config.voiceId},
        nest: () => builder.text(speechText(text)),
      ),
    );
    return builder.buildDocument().toXmlString();
  }

  Future<Uint8List> synthesize(
    String text,
    CustomSpeechConfig config,
    SpeechCancellation cancellation,
  ) async {
    config.validate();
    cancellation.check();
    final client = clientFactory()
      ..connectionTimeout = const Duration(seconds: 12);
    final detach = cancellation.onCancel(() => client.close(force: true));
    try {
      final request = await cancellation.wait(
        client.postUrl(config.endpoint).timeout(const Duration(seconds: 15)),
      );
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/ssml+xml; charset=utf-8',
      );
      request.headers.set(
        'X-Microsoft-OutputFormat',
        'audio-24khz-48kbitrate-mono-mp3',
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'Wenku8-Flutter');
      switch (config.authentication) {
        case SpeechAuthentication.none:
          break;
        case SpeechAuthentication.subscriptionKey:
          request.headers.set('Ocp-Apim-Subscription-Key', config.secret);
        case SpeechAuthentication.bearer:
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${config.secret}',
          );
      }
      request.add(utf8.encode(ssml(text, config)));
      final response = await cancellation.wait(
        request.close().timeout(const Duration(seconds: 25)),
      );
      if (response.statusCode != 200) {
        throw SpeechFailure(switch (response.statusCode) {
          401 || 403 => '自定义接口认证失败，请检查密钥或令牌',
          404 => '自定义接口地址不存在，请检查完整的合成 URL',
          429 => '自定义接口请求过于频繁，请稍后重试',
          301 || 302 || 307 || 308 => '接口发生重定向，请填写最终的 HTTPS 合成地址',
          _ => '自定义语音接口返回 ${response.statusCode}，请检查接口与音色配置',
        });
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 25))) {
        cancellation.check();
        bytes.add(chunk);
        if (bytes.length > 16 * 1024 * 1024) {
          throw const SpeechFailure('自定义接口返回的音频过大');
        }
      }
      final data = bytes.takeBytes();
      if (data.length <= 100 ||
          !((data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33) ||
              (data[0] == 0xff && data[1] & 0xe0 == 0xe0))) {
        throw const SpeechFailure('接口没有返回 MP3 音频，请选择 Microsoft SSML 兼容接口');
      }
      return data;
    } on SpeechFailure {
      rethrow;
    } on TimeoutException {
      cancellation.check();
      throw const SpeechFailure('自定义语音接口超时', kind: SpeechFailureKind.timeout);
    } on SpeechCancelled {
      rethrow;
    } catch (_) {
      cancellation.check();
      throw const SpeechFailure('自定义语音接口连接失败，请检查网络与地址');
    } finally {
      detach();
      client.close(force: true);
    }
  }
}

CustomSpeechConfig makeCustomSpeechConfig({
  required String endpoint,
  required String voice,
  required String locale,
  required String label,
  required SpeechAuthentication authentication,
  required String secret,
}) => CustomSpeechConfig(
  endpoint: Uri.parse(endpoint.trim()),
  voiceId: voice.trim(),
  namespace: EdgeSpeechClient.connectionId(),
  locale: locale.trim(),
  label: label.trim(),
  authentication: authentication,
  secret: secret.trim(),
);
