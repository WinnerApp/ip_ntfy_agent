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

  /// Agent 与 Jenkins 同机：用文档里的局域网 IP + 端口（缺省补 8080）。
  /// 不用 127.0.0.1：部分反代只按机器 IP 的 VirtualHost 转发，localhost 会 502。
  static String localJenkinsBase(String? jenkinsUrl) {
    return normalizeJenkinsBase(jenkinsUrl ?? '');
  }

  /// 请求 URL 无端口时补 Jenkins 默认 8080（Appwrite 文档 url 常不带端口）。
  static Uri ensureJenkinsPort(Uri uri) {
    if (uri.hasPort) return uri;
    if (uri.scheme != 'http' && uri.scheme != 'https') return uri;
    if (uri.host.isEmpty) return uri;
    return uri.replace(port: 8080);
  }

  /// 客户端常写 `http://127.0.0.1:8080/...`；改写为 [preferredBaseUrl] 的 host/port。
  /// [preferredBaseUrl] 缺端口时按 [normalizeJenkinsBase] 补 8080。
  static Uri rewriteLoopbackHost(Uri uri, String? preferredBaseUrl) {
    final host = uri.host.toLowerCase();
    if (host != '127.0.0.1' && host != 'localhost' && host != '::1') {
      return ensureJenkinsPort(uri);
    }
    final base = Uri.tryParse(normalizeJenkinsBase(preferredBaseUrl ?? ''));
    if (base == null || base.host.isEmpty) {
      return ensureJenkinsPort(uri);
    }
    return uri.replace(host: base.host, port: base.hasPort ? base.port : 8080);
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
    // 本机下载：用文档局域网 URL（补默认端口），避免 127.0.0.1 反代 502。
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
