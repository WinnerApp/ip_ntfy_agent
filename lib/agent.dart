import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'appwrite_service.dart';
import 'config.dart';
import 'feishu_service.dart';
import 'ip_service.dart';
import 'jenkins_service.dart';
import 'ntfy_service.dart';

class Agent {
  Agent(this.config)
      : appwrite = AppwriteService(config),
        jenkins = JenkinsService(),
        ntfy = NtfyService(config),
        feishu = FeishuService(config),
        _http = http.Client();

  final AppConfig config;
  final AppwriteService appwrite;
  final JenkinsService jenkins;
  final NtfyService ntfy;
  final FeishuService feishu;
  final http.Client _http;

  Timer? _ipTimer;
  Timer? _jenkinsTimer;
  String? _currentIp;
  bool _running = false;
  final Completer<void> _done = Completer<void>();
  /// 进行中的 uploadZip requestId，避免同进程重复处理。
  final _inflightUploadIds = <String>{};

  Future<void> start() async {
    if (_running) return;
    _running = true;

    stdout.writeln('[agent] loading Appwrite document tag=${config.tagValue}');
    final doc = await appwrite.loadByTag();
    if (doc == null) {
      throw StateError(
        'No document found for tag=${config.tagValue}',
      );
    }
    stdout.writeln(
      '[agent] document=${doc.id} url=${doc.url} '
      'userName=${doc.userName} active=${doc.active} online=${doc.online}',
    );

    await _syncIp(force: true);
    await _syncJenkins();

    _ipTimer = Timer.periodic(config.ipCheckInterval, (_) {
      unawaited(_syncIp());
    });
    _jenkinsTimer = Timer.periodic(config.jenkinsCheckInterval, (_) {
      unawaited(_syncJenkins());
    });

    stdout.writeln('[agent] running (Ctrl+C to stop)');
    await _done.future;
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _ipTimer?.cancel();
    _jenkinsTimer?.cancel();
    await ntfy.stop();
    jenkins.close();
    feishu.close();
    _http.close();
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> _syncIp({bool force = false}) async {
    try {
      final ip = await getLocalIpv4();
      if (ip == null) {
        stderr.writeln('[agent] no local IPv4 found');
        return;
      }

      final ipChanged = _currentIp != null && _currentIp != ip;
      _currentIp = ip;
      final dbUrl = appwrite.cached?.url;
      final expectedUrl = urlWithHost(dbUrl, ip);

      if (dbUrl != expectedUrl) {
        stdout.writeln('[agent] updating url: db=$dbUrl -> $expectedUrl');
        await appwrite.updateUrl(expectedUrl);
      }

      if (force || ipChanged) {
        final topic = ipToTopic(ip);
        stdout.writeln('[agent] ip=$ip ntfy topic -> $topic');
        ntfy.ensureListening(topic, _handleNtfyPayload);
      }

      // IP changed while Jenkins is offline → notify Feishu with :8080 address.
      if (ipChanged && appwrite.cached?.online != true) {
        await _notifyFeishu(() => feishu.notifyIpChanged(ip));
      }
    } catch (e, st) {
      stderr.writeln('[agent] ip sync failed: $e\n$st');
    }
  }

  Future<void> _syncJenkins() async {
    try {
      final doc = appwrite.cached;
      if (doc == null) return;
      if (doc.active == false) {
        final changed = doc.online != false;
        if (changed) {
          stdout.writeln('[agent] inactive; setting online=false');
          await appwrite.updateOnline(false);
          await _notifyJenkinsStatusChanged(false);
        }
        return;
      }

      final online = await jenkins.isOnline(doc);
      final dbOnline = doc.online;
      if (dbOnline == online) return;

      stdout.writeln(
        '[agent] updating online url=${doc.url}: db=$dbOnline -> $online',
      );
      await appwrite.updateOnline(online);
      await _notifyJenkinsStatusChanged(online);
    } catch (e, st) {
      stderr.writeln('[agent] jenkins sync failed: $e\n$st');
    }
  }

  Future<void> _notifyJenkinsStatusChanged(bool online) async {
    final ip = _currentIp ?? ipFromUrl(appwrite.cached?.url);
    if (ip == null || ip.isEmpty) {
      stderr.writeln('[agent] skip feishu jenkins notify: no ip');
      return;
    }
    await _notifyFeishu(
      () => feishu.notifyJenkinsStatus(ip: ip, online: online),
    );
  }

  Future<void> _notifyFeishu(Future<void> Function() send) async {
    if (!feishu.enabled) {
      stderr.writeln('[agent] FEISHU_WEBHOOK_URL not set; skip notify');
      return;
    }
    try {
      await send();
    } catch (e, st) {
      stderr.writeln('[agent] feishu notify failed: $e\n$st');
    }
  }

  Future<void> _handleNtfyPayload(Map<String, dynamic> payload) async {
    final topic = ntfy.currentTopic;
    if (topic == null) return;

    final action = payload['action']?.toString();
    if (action == 'uploadZip') {
      await _handleUploadZip(topic, payload);
      return;
    }
    if (action == 'deleteZip') {
      await _handleDeleteZip(topic, payload);
      return;
    }

    final url = payload['url']?.toString();
    if (url == null || url.isEmpty) {
      stderr.writeln('[agent] ignore ntfy payload without url: $payload');
      return;
    }

    final method = (payload['method']?.toString() ?? 'GET').toUpperCase();
    final headers = <String, String>{};
    final rawHeaders = payload['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        headers[key.toString()] = value.toString();
      });
    }

    var requestUri = Uri.parse(url);
    final params = payload['params'] ?? payload['query'];
    if (params is Map && params.isNotEmpty) {
      final query = Map<String, String>.from(requestUri.queryParameters);
      params.forEach((key, value) {
        query[key.toString()] = value.toString();
      });
      requestUri = requestUri.replace(queryParameters: query);
    }

    final body = payload['body'] ?? payload['data'];
    String? encodedBody;
    if (body != null) {
      if (body is String) {
        encodedBody = body;
      } else {
        encodedBody = jsonEncode(body);
        headers.putIfAbsent(
          HttpHeaders.contentTypeHeader,
          () => 'application/json; charset=utf-8',
        );
      }
    }

    stdout.writeln('[agent] proxy $method $requestUri');
    late http.Response response;
    try {
      final request = http.Request(method, requestUri);
      request.headers.addAll(headers);
      if (encodedBody != null) request.body = encodedBody;
      final streamed = await _http.send(request).timeout(
            const Duration(seconds: 60),
          );
      response = await http.Response.fromStream(streamed);
    } catch (e) {
      await ntfy.publish(
        topic,
        {
          'type': 'response',
          'requestId': payload['requestId'] ?? payload['id'],
          'ok': false,
          'error': e.toString(),
          'request': {
            'method': method,
            'url': requestUri.toString(),
          },
        },
        tags: const ['response', 'agent-response'],
      );
      return;
    }

    await ntfy.publish(
      topic,
      {
        'type': 'response',
        'requestId': payload['requestId'] ?? payload['id'],
        'ok': true,
        'statusCode': response.statusCode,
        'headers': response.headers,
        'body': _safeBody(response),
        'request': {
          'method': method,
          'url': requestUri.toString(),
        },
      },
      tags: const ['response', 'agent-response'],
    );
  }

  Future<void> _handleUploadZip(
    String topic,
    Map<String, dynamic> payload,
  ) async {
    final requestId = payload['requestId'] ?? payload['id'];
    final requestKey = requestId?.toString() ?? '';
    if (requestKey.isNotEmpty && !_inflightUploadIds.add(requestKey)) {
      stdout.writeln(
        '[agent] skip duplicate uploadZip requestId=$requestKey',
      );
      return;
    }

    try {
      await _doUploadZip(topic, payload, requestId);
    } finally {
      if (requestKey.isNotEmpty) {
        _inflightUploadIds.remove(requestKey);
      }
    }
  }

  Future<void> _doUploadZip(
    String topic,
    Map<String, dynamic> payload,
    Object? requestId,
  ) async {
    final buildId = payload['buildId']?.toString() ??
        payload['buildNumber']?.toString();
    final platform = payload['platform']?.toString();
    final tag = payload['tag']?.toString();

    if (buildId == null ||
        buildId.isEmpty ||
        platform == null ||
        platform.isEmpty) {
      await ntfy.publish(
        topic,
        {
          'type': 'response',
          'action': 'uploadZip',
          'requestId': requestId,
          'ok': false,
          'error': 'uploadZip requires buildId and platform',
        },
        tags: const ['response', 'agent-response'],
      );
      return;
    }

    final doc = appwrite.cached;
    if (doc == null) {
      await ntfy.publish(
        topic,
        {
          'type': 'response',
          'action': 'uploadZip',
          'requestId': requestId,
          'ok': false,
          'error': 'No Jenkins host document loaded',
        },
        tags: const ['response', 'agent-response'],
      );
      return;
    }

    stdout.writeln(
      '[agent] uploadZip buildId=$buildId platform=$platform '
      'tag=${tag ?? config.tagValue}',
    );

    Directory? tempDir;
    try {
      tempDir = await Directory.systemTemp.createTemp('hot_update_');
      final zipPath = '${tempDir.path}/UploadAssets.zip';
      await jenkins.downloadHotUpdateZip(
        doc: doc,
        buildNumber: buildId,
        platform: platform,
        destPath: zipPath,
      );

      DateTime? lastProgressAt;
      Future<void> publishUploadProgress({
        required double percent,
        int? sizeUploaded,
        int? chunksUploaded,
        int? chunksTotal,
        bool force = false,
      }) async {
        final now = DateTime.now();
        final due = force ||
            lastProgressAt == null ||
            now.difference(lastProgressAt!) >= const Duration(seconds: 5);
        if (!due) return;
        lastProgressAt = now;
        try {
          await ntfy.publish(
            topic,
            {
              'type': 'progress',
              'action': 'uploadZip',
              'requestId': requestId,
              'phase': 'uploading',
              'percent': percent,
              'sizeUploaded': ?sizeUploaded,
              'chunksUploaded': ?chunksUploaded,
              'chunksTotal': ?chunksTotal,
            },
            tags: const ['response', 'agent-response'],
          );
        } catch (e) {
          stderr.writeln('[agent] uploadZip progress publish failed: $e');
        }
      }

      await publishUploadProgress(percent: 0, force: true);
      final result = await appwrite.uploadZipResource(
        path: zipPath,
        buildId: buildId,
        tag: tag,
        onProgress: (progress) {
          unawaited(
            publishUploadProgress(
              percent: progress.progress,
              sizeUploaded: progress.sizeUploaded,
              chunksUploaded: progress.chunksUploaded,
              chunksTotal: progress.chunksTotal,
              force: progress.progress >= 100,
            ),
          );
        },
      );
      // Small files skip SDK onProgress; always emit a terminal progress.
      await publishUploadProgress(percent: 100, force: true);
      await ntfy.publish(
        topic,
        {
          'type': 'response',
          'action': 'uploadZip',
          'requestId': requestId,
          'ok': true,
          'body': {
            ...result.toJson(),
            'platform': platform,
          },
        },
        tags: const ['response', 'agent-response'],
      );
    } catch (e) {
      await ntfy.publish(
        topic,
        {
          'type': 'response',
          'action': 'uploadZip',
          'requestId': requestId,
          'ok': false,
          'error': e.toString(),
        },
        tags: const ['response', 'agent-response'],
      );
    } finally {
      if (tempDir != null) {
        try {
          await tempDir.delete(recursive: true);
        } catch (e) {
          stderr.writeln('[agent] cleanup temp dir failed: $e');
        }
      }
    }
  }

  Future<void> _handleDeleteZip(
    String topic,
    Map<String, dynamic> payload,
  ) async {
    final requestId = payload['requestId'] ?? payload['id'];
    final buildId = payload['buildId']?.toString() ??
        payload['buildNumber']?.toString();
    final tag = payload['tag']?.toString();

    if (buildId == null || buildId.isEmpty) {
      await ntfy.publish(
        topic,
        {
          'type': 'response',
          'action': 'deleteZip',
          'requestId': requestId,
          'ok': false,
          'error': 'deleteZip requires buildId',
        },
        tags: const ['response', 'agent-response'],
      );
      return;
    }

    stdout.writeln(
      '[agent] deleteZip buildId=$buildId tag=${tag ?? config.tagValue}',
    );
    try {
      final result = await appwrite.deleteZipResource(
        buildId: buildId,
        tag: tag,
      );
      await ntfy.publish(
        topic,
        {
          'type': 'response',
          'action': 'deleteZip',
          'requestId': requestId,
          'ok': true,
          'body': result.toJson(),
        },
        tags: const ['response', 'agent-response'],
      );
    } catch (e) {
      await ntfy.publish(
        topic,
        {
          'type': 'response',
          'action': 'deleteZip',
          'requestId': requestId,
          'ok': false,
          'error': e.toString(),
        },
        tags: const ['response', 'agent-response'],
      );
    }
  }

  Object _safeBody(http.Response response) {
    final text = response.body;
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }
}
