import 'package:flutter/services.dart';

/// The same v1.30 POST bridge. Account cookies never cross into Dart or backups.
abstract final class LegacyTransport {
  static const channel = MethodChannel('org.mewx.wenku8/legacy_api');
  static Future<void> setUpdatePriority(bool enabled) async {
    try {
      await channel.invokeMethod<void>('updatePriority', {'enabled': enabled});
    } on MissingPluginException {
      // Non-Android clients keep the original transport.
    }
  }

  static Future<String> request(String action) => _text('request', action);
  static Future<String> accountRequest(String action) =>
      _text('accountRequest', action);

  /// Read-only routes which the service may gate behind a signed-in session.
  /// Public discovery/search remain independent from account cookies.
  static Future<String> sessionRead(String action) async =>
      await hasSession() ? accountRequest(action) : request(action);
  static Future<String> login(String action) => _text('login', action);
  static Future<Uint8List> accountAvatar() async {
    final bytes = await channel.invokeMethod<Uint8List>('accountAvatar');
    if (bytes == null || bytes.isEmpty) throw const FormatException('账号暂无头像');
    return bytes;
  }

  static Future<String> _text(String method, String action) async {
    final text = await channel.invokeMethod<String>(method, {'action': action});
    if (text == null || text.trim().isEmpty) {
      throw const FormatException('接口返回空内容');
    }
    return text;
  }

  static Future<bool> hasSession() async =>
      await channel.invokeMethod<bool>('hasSession') ?? false;
  static Future<void> clearSession() =>
      channel.invokeMethod<void>('clearSession');
  static Future<void> connectPublications(
    String username,
    String password,
  ) async {
    try {
      await channel.invokeMethod<void>('webLogin', {
        'username': username,
        'password': password,
      });
    } on PlatformException catch (failure) {
      if (failure.code.startsWith('WEB_')) {
        throw FormatException(failure.message ?? '分类连接未成功');
      }
      rethrow;
    }
  }

  static Future<String> publicationPage(int library, int page) async =>
      (await channel.invokeMethod<String>('publicationPage', {
        'library': library,
        'page': page,
      })) ??
      '';
  static Future<Uint8List> illustration(String url) async {
    final bytes = await channel.invokeMethod<Uint8List>('illustration', {
      'url': url,
    });
    if (bytes == null || bytes.isEmpty) throw const FormatException('插图内容为空');
    return bytes;
  }

  static Future<void> clearIllustrations() =>
      channel.invokeMethod<void>('clearIllustrations');
  static Future<String> encodeReview(String text) async {
    try {
      final encoded = await channel.invokeMethod<String>('encodeReview', {
        'text': text,
      });
      if (encoded == null || encoded.isEmpty) {
        throw const FormatException('书评编码返回空内容');
      }
      return encoded;
    } on PlatformException catch (error) {
      if (error.code == 'REVIEW_ENCODING') {
        throw const FormatException('原版书评接口使用 GBK，请移除表情或特殊字符后重试；草稿仍保留');
      }
      rethrow;
    }
  }
}
