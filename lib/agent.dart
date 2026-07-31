import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

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
    if (action == 'uploadApk') {
      await _handleUploadApk(topic, payload);
      return;
    }
    if (action == 'deleteApk') {
      await _handleDeleteApk(topic, payload);
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

    final clientUri = requestUri;
    final preferredBase = appwrite.cached?.url ??
        (_currentIp != null ? urlFromIp(_currentIp!) : null);
    final resolvedUri =
        JenkinsService.rewriteLoopbackHost(requestUri, preferredBase);
    if (resolvedUri.host != requestUri.host ||
        resolvedUri.port != requestUri.port) {
      stdout.writeln(
        '[agent] rewrite $requestUri -> $resolvedUri',
      );
    }
    requestUri = resolvedUri;

    final useJenkinsPlain =
        method == 'GET' && _isJenkinsWorkspaceDir(requestUri);
    if (useJenkinsPlain) {
      requestUri = _withJenkinsPlainListing(requestUri);
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

    stdout.writeln(
      useJenkinsPlain
          ? '[agent] proxy $method $clientUri -> ${requestUri.path} (dir listing)'
          : '[agent] proxy $method $requestUri',
    );
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
            'url': clientUri.toString(),
          },
        },
        tags: const ['response', 'agent-response'],
      );
      return;
    }

    await ntfy.publish(
      topic,
      _buildProxyResponse(
        requestId: payload['requestId'] ?? payload['id'],
        method: method,
        requestUri: clientUri,
        response: response,
        jenkinsDirListing: useJenkinsPlain,
      ),
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

  Future<void> _handleUploadApk(
    String topic,
    Map<String, dynamic> payload,
  ) async {
    final requestId = payload['requestId'] ?? payload['id'];
    final requestKey = requestId?.toString() ?? '';
    if (requestKey.isNotEmpty && !_inflightUploadIds.add(requestKey)) {
      stdout.writeln(
        '[agent] skip duplicate uploadApk requestId=$requestKey',
      );
      return;
    }

    try {
      await _doUploadApk(topic, payload, requestId);
    } finally {
      if (requestKey.isNotEmpty) {
        _inflightUploadIds.remove(requestKey);
      }
    }
  }

  Future<void> _doUploadApk(
    String topic,
    Map<String, dynamic> payload,
    Object? requestId,
  ) async {
    final path = payload['path']?.toString() ??
        payload['file']?.toString() ??
        payload['filePath']?.toString();
    final buildId = payload['buildId']?.toString() ??
        payload['buildNumber']?.toString();
    final tag = payload['tag']?.toString();
    final fileName = payload['fileName']?.toString() ??
        payload['filename']?.toString();

    if (path == null ||
        path.isEmpty ||
        buildId == null ||
        buildId.isEmpty) {
      await ntfy.publish(
        topic,
        {
          'type': 'response',
          'action': 'uploadApk',
          'requestId': requestId,
          'ok': false,
          'error': 'uploadApk requires path and buildId',
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
          'action': 'uploadApk',
          'requestId': requestId,
          'ok': false,
          'error': 'No Jenkins host document loaded',
        },
        tags: const ['response', 'agent-response'],
      );
      return;
    }

    stdout.writeln(
      '[agent] uploadApk path=$path buildId=$buildId '
      'tag=${tag ?? config.tagValue}',
    );

    Directory? tempDir;
    try {
      final resolved = await _resolveLocalFile(
        doc: doc,
        path: path,
        fileName: fileName,
        defaultName: 'app.apk',
        emptyErrorLabel: 'apk',
        tempPrefix: 'apk_upload_',
      );
      tempDir = resolved.tempDir;
      final apkPath = resolved.localPath;

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
              'action': 'uploadApk',
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
          stderr.writeln('[agent] uploadApk progress publish failed: $e');
        }
      }

      await publishUploadProgress(percent: 0, force: true);
      final result = await appwrite.uploadApkResource(
        path: apkPath,
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
      await publishUploadProgress(percent: 100, force: true);
      await ntfy.publish(
        topic,
        {
          'type': 'response',
          'action': 'uploadApk',
          'requestId': requestId,
          'ok': true,
          'body': {
            ...result.toJson(),
            'path': path,
            'fileName': p.basename(apkPath),
          },
        },
        tags: const ['response', 'agent-response'],
      );
    } catch (e) {
      await ntfy.publish(
        topic,
        {
          'type': 'response',
          'action': 'uploadApk',
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

  Future<void> _handleDeleteApk(
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
          'action': 'deleteApk',
          'requestId': requestId,
          'ok': false,
          'error': 'deleteApk requires buildId',
        },
        tags: const ['response', 'agent-response'],
      );
      return;
    }

    stdout.writeln(
      '[agent] deleteApk buildId=$buildId tag=${tag ?? config.tagValue}',
    );
    try {
      final result = await appwrite.deleteApkResource(
        buildId: buildId,
        tag: tag,
      );
      await ntfy.publish(
        topic,
        {
          'type': 'response',
          'action': 'deleteApk',
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
          'action': 'deleteApk',
          'requestId': requestId,
          'ok': false,
          'error': e.toString(),
        },
        tags: const ['response', 'agent-response'],
      );
    }
  }

  /// Resolve [path] to a local file. HTTP(S) URLs are downloaded with
  /// Jenkins host auth; absolute local paths are used as-is.
  Future<({String localPath, Directory? tempDir})> _resolveLocalFile({
    required HostDocument doc,
    required String path,
    required String defaultName,
    required String emptyErrorLabel,
    required String tempPrefix,
    String? fileName,
  }) async {
    final trimmed = path.trim();
    final uri = Uri.tryParse(trimmed);
    final isRemote = uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;

    if (!isRemote) {
      final local = File(trimmed);
      if (!await local.exists()) {
        throw StateError('Local file not found: $trimmed');
      }
      return (localPath: local.path, tempDir: null);
    }

    final preferredBase = doc.url ??
        (_currentIp != null ? urlFromIp(_currentIp!) : null);
    final downloadUri =
        JenkinsService.rewriteLoopbackHost(uri, preferredBase);
    final name = (fileName != null && fileName.trim().isNotEmpty)
        ? fileName.trim()
        : (downloadUri.pathSegments.isNotEmpty &&
                downloadUri.pathSegments.last.contains('.')
            ? downloadUri.pathSegments.last
            : defaultName);
    final tempDir = await Directory.systemTemp.createTemp(tempPrefix);
    final destPath = '${tempDir.path}/$name';
    await jenkins.downloadUrl(
      doc: doc,
      url: downloadUri.toString(),
      destPath: destPath,
      emptyErrorLabel: emptyErrorLabel,
    );
    return (localPath: destPath, tempDir: tempDir);
  }

  Map<String, dynamic> _buildProxyResponse({
    required Object? requestId,
    required String method,
    required Uri requestUri,
    required http.Response response,
    bool jenkinsDirListing = false,
  }) {
    final requestMeta = {
      'method': method,
      'url': requestUri.toString(),
    };
    final names = _fileFolderNames(
      requestUri: requestUri,
      headers: response.headers,
    );
    final contentType = response.headers[HttpHeaders.contentTypeHeader];
    final declaredLength = response.contentLength;
    final contentLength = (declaredLength != null && declaredLength >= 0)
        ? declaredLength
        : response.bodyBytes.length;

    if (jenkinsDirListing &&
        response.statusCode >= 200 &&
        response.statusCode < 300) {
      final listing = _parseJenkinsPlainListing(response.body);
      return {
        'type': 'response',
        'requestId': requestId,
        'ok': true,
        'statusCode': response.statusCode,
        'body': {
          'files': listing.files,
          'folders': listing.folders,
          'folderName': names.folderName ??
              _workspaceLeafName(requestUri) ??
              'ws',
        },
        'request': requestMeta,
      };
    }

    if (_looksLikeFileResponse(response)) {
      return {
        'type': 'response',
        'requestId': requestId,
        'ok': true,
        'statusCode': response.statusCode,
        'body': null,
        'bodyOmitted': true,
        'omitReason': 'file',
        'fileName': names.fileName,
        'folderName': names.folderName,
        'contentType': ?contentType,
        'contentLength': contentLength,
        'request': requestMeta,
      };
    }

    return {
      'type': 'response',
      'requestId': requestId,
      'ok': true,
      'statusCode': response.statusCode,
      'headers': response.headers,
      'body': _safeBody(response),
      'request': requestMeta,
    };
  }

  /// Jenkins `/job/.../ws/...` 目录页（HTML）过大，改走 `*plain*` 文本列表。
  bool _isJenkinsWorkspaceDir(Uri uri) {
    final segments =
        uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
    final wsIdx = segments.indexOf('ws');
    if (wsIdx < 0) return false;
    if (segments.any((s) =>
        s == '*plain*' || s == '*zip*' || s == '*view*' || s == '*fingerprint*')) {
      return false;
    }
    if (uri.path.endsWith('/')) return true;
    // `/ws` 或子目录无扩展名时按目录处理；带扩展名视为文件。
    final last = segments.last;
    return !last.contains('.');
  }

  Uri _withJenkinsPlainListing(Uri uri) {
    var path = uri.path;
    if (!path.endsWith('/')) path = '$path/';
    return uri.replace(path: '$path*plain*/');
  }

  ({List<String> files, List<String> folders}) _parseJenkinsPlainListing(
    String body,
  ) {
    final files = <String>[];
    final folders = <String>[];
    for (final line in const LineSplitter().convert(body)) {
      final name = line.trim();
      if (name.isEmpty) continue;
      if (name.endsWith('/')) {
        folders.add(name.substring(0, name.length - 1));
      } else {
        files.add(name);
      }
    }
    return (files: files, folders: folders);
  }

  String? _workspaceLeafName(Uri uri) {
    final segments =
        uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
    final wsIdx = segments.indexOf('ws');
    if (wsIdx < 0) return null;
    if (wsIdx == segments.length - 1) return 'ws';
    return segments.last;
  }

  bool _looksLikeFileResponse(http.Response response) {
    final disposition = response.headers['content-disposition'] ?? '';
    if (disposition.toLowerCase().contains('attachment') ||
        disposition.toLowerCase().contains('filename=')) {
      return true;
    }

    final rawType =
        (response.headers[HttpHeaders.contentTypeHeader] ?? '').toLowerCase();
    final mime = rawType.split(';').first.trim();
    if (mime.isEmpty) {
      return false;
    }
    const textLike = {
      'application/json',
      'application/xml',
      'application/javascript',
      'application/x-www-form-urlencoded',
      'application/problem+json',
    };
    if (mime.startsWith('text/') || textLike.contains(mime)) {
      return false;
    }
    if (mime.endsWith('+json') || mime.endsWith('+xml')) {
      return false;
    }
    return true;
  }

  ({String? fileName, String? folderName}) _fileFolderNames({
    required Uri requestUri,
    required Map<String, String> headers,
  }) {
    String? fileName = _filenameFromContentDisposition(
      headers['content-disposition'],
    );

    final segments = requestUri.pathSegments
        .where((s) => s.isNotEmpty)
        .map(Uri.decodeComponent)
        .toList();
    if (fileName == null && segments.isNotEmpty) {
      final last = segments.last;
      if (last.contains('.')) {
        fileName = last;
      }
    }

    String? folderName;
    if (segments.length >= 2) {
      folderName = segments[segments.length - 2];
    } else if (segments.length == 1 && fileName == null) {
      folderName = segments.first;
    }

    return (fileName: fileName, folderName: folderName);
  }

  String? _filenameFromContentDisposition(String? header) {
    if (header == null || header.isEmpty) return null;
    final star = RegExp(
      r"filename\*\s*=\s*(?:UTF-8''|utf-8'')([^;]+)",
      caseSensitive: false,
    ).firstMatch(header);
    if (star != null) {
      try {
        return Uri.decodeComponent(star.group(1)!.trim());
      } catch (_) {
        return star.group(1)!.trim();
      }
    }
    final plain = RegExp(
      r'filename\s*=\s*"([^"]+)"|filename\s*=\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(header);
    if (plain == null) return null;
    return (plain.group(1) ?? plain.group(2))?.trim();
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
