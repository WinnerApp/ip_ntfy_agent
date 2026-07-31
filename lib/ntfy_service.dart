import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'config.dart';

typedef NtfyMessageHandler = Future<void> Function(Map<String, dynamic> payload);

/// Listen / publish via ntfy JSON stream.
class NtfyService {
  NtfyService(this.config, {http.Client? client})
      : _client = client ?? http.Client();

  final AppConfig config;
  final http.Client _client;

  StreamSubscription<List<int>>? _subscription;
  http.Client? _streamClient;
  String? _currentTopic;
  NtfyMessageHandler? _handler;
  bool _stopping = false;
  bool _loopStarted = false;

  String? get currentTopic => _currentTopic;

  /// Start background listen loop. Safe to call multiple times.
  void ensureListening(String topic, NtfyMessageHandler onMessage) {
    _handler = onMessage;
    _currentTopic = topic;
    if (_loopStarted) {
      // Force reconnect on topic change by closing current stream.
      unawaited(_disconnectStream());
      return;
    }
    _loopStarted = true;
    _stopping = false;
    unawaited(_runLoop());
  }

  Future<void> publish(String topic, Object body, {List<String>? tags}) async {
    final base = config.ntfyBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/$topic');
    final headers = <String, String>{
      HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
      ..._authHeaders(),
    };
    if (tags != null && tags.isNotEmpty) {
      headers['Tags'] = tags.join(',');
    }
    headers['Title'] = 'ip_ntfy_agent';

    final payload = body is String ? body : jsonEncode(body);
    _logSend(topic, payload);
    final response = await _client.post(uri, headers: headers, body: payload);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'ntfy publish failed (${response.statusCode}): ${response.body}',
        uri: uri,
      );
    }
  }

  Future<void> stop() async {
    _stopping = true;
    _currentTopic = null;
    _handler = null;
    await _disconnectStream();
    _client.close();
  }

  Future<void> _runLoop() async {
    while (!_stopping) {
      final topic = _currentTopic;
      final handler = _handler;
      if (topic == null || handler == null) {
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }

      try {
        await _connectOnce(topic, handler);
      } catch (e, st) {
        if (!_stopping) {
          stderr.writeln('[ntfy] listen error on $topic: $e\n$st');
        }
      }

      if (_stopping) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    _loopStarted = false;
  }

  Future<void> _connectOnce(
    String topic,
    NtfyMessageHandler onMessage,
  ) async {
    final base = config.ntfyBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/$topic/json');
    final request = http.Request('GET', uri);
    request.headers.addAll(_authHeaders());

    final streamClient = http.Client();
    _streamClient = streamClient;
    final response = await streamClient.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      streamClient.close();
      throw HttpException(
        'ntfy subscribe failed (${response.statusCode}): $body',
        uri: uri,
      );
    }

    stdout.writeln('[ntfy] subscribed: $topic');
    final completer = Completer<void>();
    var buffer = '';

    _subscription = response.stream.listen(
      (chunk) {
        buffer += utf8.decode(chunk, allowMalformed: true);
        final lines = buffer.split('\n');
        buffer = lines.removeLast();
        for (final line in lines) {
          unawaited(_handleLine(line, onMessage));
        }
      },
      onError: (Object e, StackTrace st) {
        stderr.writeln('[ntfy] stream error: $e\n$st');
        if (!completer.isCompleted) completer.completeError(e, st);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );

    await completer.future;
  }

  Future<void> _handleLine(String line, NtfyMessageHandler onMessage) async {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    try {
      final event = jsonDecode(trimmed) as Map<String, dynamic>;
      final eventType = event['event']?.toString();
      if (eventType != null && eventType != 'message') return;

      final message = event['message']?.toString();
      if (message == null || message.isEmpty) return;

      final tags =
          (event['tags'] as List?)?.map((e) => e.toString()).toList() ??
              const <String>[];
      if (tags.contains('response') || tags.contains('agent-response')) {
        return;
      }

      Map<String, dynamic> payload;
      try {
        final decoded = jsonDecode(message);
        if (decoded is Map<String, dynamic>) {
          payload = decoded;
        } else {
          payload = {'raw': decoded};
        }
      } catch (_) {
        payload = {'raw': message};
      }

      final payloadType = payload['type']?.toString();
      if (payloadType == 'response' || payloadType == 'progress') return;

      _logRecv(_currentTopic ?? event['topic']?.toString() ?? '?', message);
      await onMessage(payload);
    } catch (e, st) {
      stderr.writeln('[ntfy] message handle error: $e\n$st');
    }
  }

  void _logRecv(String topic, String message) {
    stdout.writeln('$_ansiBlue[ntfy] recv $topic: $message$_ansiReset');
  }

  void _logSend(String topic, String payload) {
    stdout.writeln('$_ansiGreen[ntfy] send $topic: $payload$_ansiReset');
  }

  static const _ansiBlue = '\x1B[34m';
  static const _ansiGreen = '\x1B[32m';
  static const _ansiReset = '\x1B[0m';

  Map<String, String> _authHeaders() {
    final auth = config.ntfyAuth;
    if (auth == null || auth.isEmpty) return {};
    return {HttpHeaders.authorizationHeader: auth};
  }

  Future<void> _disconnectStream() async {
    await _subscription?.cancel();
    _subscription = null;
    _streamClient?.close();
    _streamClient = null;
  }
}
