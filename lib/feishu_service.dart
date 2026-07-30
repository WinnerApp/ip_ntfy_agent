import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'config.dart';

/// Send text alerts to a Feishu (Lark) custom bot webhook.
class FeishuService {
  FeishuService(this.config, {http.Client? client})
      : _client = client ?? http.Client();

  final AppConfig config;
  final http.Client _client;

  bool get enabled {
    final url = config.feishuWebhookUrl;
    return url != null && url.isNotEmpty;
  }

  Future<void> sendText(String text) async {
    final webhook = config.feishuWebhookUrl;
    if (webhook == null || webhook.isEmpty) return;

    final message = text.contains('打包机') ? text : '【打包机】$text';
    final uri = Uri.parse(webhook);
    final response = await _client
        .post(
          uri,
          headers: {
            HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
          },
          body: jsonEncode({
            'msg_type': 'text',
            'content': {'text': message},
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'feishu webhook failed (${response.statusCode}): ${response.body}',
        uri: uri,
      );
    }

    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['code'] != null && body['code'] != 0) {
        throw HttpException(
          'feishu webhook rejected: ${response.body}',
          uri: uri,
        );
      }
    } catch (e) {
      if (e is HttpException) rethrow;
    }
  }

  Future<void> notifyIpChanged(String ip) async {
    await sendText('打包机 IP 已变化，最新地址: http://$ip:8080');
  }

  Future<void> notifyJenkinsStatus({
    required String ip,
    required bool online,
  }) async {
    final status = online ? '在线' : '离线';
    await sendText('打包机 Jenkins $status，地址: http://$ip:8080');
  }

  void close() => _client.close();
}
