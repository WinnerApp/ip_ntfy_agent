import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'appwrite_service.dart';

class JenkinsService {
  JenkinsService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const hotAssetJob = 'build_unity_hot_asset';

  /// Map UI/business platform name to Jenkins artifact directory.
  /// HarmonyOS artifacts live under `Harmony`.
  static String artifactPlatformDir(String platform) {
    final lower = platform.trim().toLowerCase();
    if (lower == 'harmonyos' || lower == 'ohos') {
      return 'Harmony';
    }
    return platform.trim().toUpperCase();
  }

  /// Appwrite 里的打包机 url 常省略端口；Jenkins 默认 8080。
  /// 不补端口会打到 80（常见 Apache 404），而触发构建经代理已用 8080。
  static String normalizeJenkinsBase(String jenkinsUrl) {
    final trimmed = jenkinsUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return trimmed;
    if (uri.hasPort) return trimmed;
    return uri.replace(port: 8080).toString().replaceAll(RegExp(r'/+$'), '');
  }

  /// Agent 与 Jenkins 同机：下载 zip 一律走本机 127.0.0.1，端口取自文档 url（缺省 8080）。
  /// 避免用文档里的公网/局域网 IP 且漏端口时打到 80（Apache 404）。
  static String localJenkinsBase(String? jenkinsUrl) {
    final uri = Uri.tryParse((jenkinsUrl ?? '').trim());
    final port = (uri != null && uri.hasPort) ? uri.port : 8080;
    return 'http://127.0.0.1:$port';
  }

  /// Jenkins workspace zip URL for a hot-update build.
  ///
  /// `{jenkinsUrl}/job/build_unity_hot_asset/ws/HotUpdate/{buildNumber}/{PLATFORM}/UploadAssets/*zip*/UploadAssets.zip`
  static String hotUpdateZipUrl({
    required String jenkinsUrl,
    required String buildNumber,
    required String platform,
  }) {
    final base = normalizeJenkinsBase(jenkinsUrl);
    final dir = artifactPlatformDir(platform);
    return '$base/job/$hotAssetJob/ws/HotUpdate/$buildNumber/$dir'
        '/UploadAssets/*zip*/UploadAssets.zip';
  }

  Map<String, String> _authHeaders(HostDocument doc) {
    final headers = <String, String>{};
    final user = doc.userName?.trim();
    final pass = doc.password ?? '';
    if (user != null && user.isNotEmpty) {
      final token = base64Encode(utf8.encode('$user:$pass'));
      headers[HttpHeaders.authorizationHeader] = 'Basic $token';
    }
    return headers;
  }

  /// Returns true when Jenkins responds successfully using document config.
  Future<bool> isOnline(HostDocument doc) async {
    final url = doc.url?.trim();
    if (url == null || url.isEmpty) return false;

    try {
      final uri = Uri.parse(normalizeJenkinsBase(url));
      final response = await _client
          .get(uri, headers: _authHeaders(doc))
          .timeout(const Duration(seconds: 10));
      return response.statusCode >= 200 && response.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  /// Download hot-update `UploadAssets.zip` from Jenkins workspace into [destPath].
  Future<File> downloadHotUpdateZip({
    required HostDocument doc,
    required String buildNumber,
    required String platform,
    required String destPath,
  }) async {
    // 本机下载：用 127.0.0.1 + 文档端口，不依赖 Appwrite url 是否带 :8080。
    final zipUrl = hotUpdateZipUrl(
      jenkinsUrl: localJenkinsBase(doc.url),
      buildNumber: buildNumber,
      platform: platform,
    );
    return downloadUrl(
      doc: doc,
      url: zipUrl,
      destPath: destPath,
      emptyErrorLabel: 'zip',
    );
  }

  /// Download arbitrary [url] (e.g. Jenkins workspace path) into [destPath].
  /// Uses host-document Basic auth when present.
  Future<File> downloadUrl({
    required HostDocument doc,
    required String url,
    required String destPath,
    String emptyErrorLabel = 'file',
  }) async {
    stdout.writeln(
      '[jenkins] download $emptyErrorLabel: $url (doc.url=${doc.url})',
    );

    final dest = File(destPath);
    await dest.parent.create(recursive: true);
    if (await dest.exists()) {
      await dest.delete();
    }

    final request = http.Request('GET', Uri.parse(url));
    request.headers.addAll(_authHeaders(doc));
    final streamed = await _client.send(request).timeout(
          const Duration(minutes: 30),
        );
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final body = await streamed.stream.bytesToString();
      throw StateError(
        'Download failed HTTP ${streamed.statusCode} url=$url '
        'body=${body.length > 500 ? '${body.substring(0, 500)}...' : body}',
      );
    }

    final sink = dest.openWrite();
    try {
      await streamed.stream.pipe(sink);
    } finally {
      await sink.close();
    }

    if (!await dest.exists() || await dest.length() == 0) {
      throw StateError('Downloaded $emptyErrorLabel is empty: $destPath');
    }
    stdout.writeln(
      '[jenkins] saved ${p.basename(destPath)} '
      '(${await dest.length()} bytes) -> $destPath',
    );
    return dest;
  }

  void close() => _client.close();
}
