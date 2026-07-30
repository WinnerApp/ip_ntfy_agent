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

  /// Jenkins workspace zip URL for a hot-update build.
  ///
  /// `{jenkinsUrl}/job/build_unity_hot_asset/ws/HotUpdate/{buildNumber}/{PLATFORM}/UploadAssets/*zip*/UploadAssets.zip`
  static String hotUpdateZipUrl({
    required String jenkinsUrl,
    required String buildNumber,
    required String platform,
  }) {
    final base = jenkinsUrl.replaceAll(RegExp(r'/+$'), '');
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
      final uri = Uri.parse(url);
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
    final jenkinsUrl = doc.url?.trim();
    if (jenkinsUrl == null || jenkinsUrl.isEmpty) {
      throw StateError('Jenkins url is empty on host document');
    }

    final zipUrl = hotUpdateZipUrl(
      jenkinsUrl: jenkinsUrl,
      buildNumber: buildNumber,
      platform: platform,
    );
    stdout.writeln('[jenkins] download hot-update zip: $zipUrl');

    final dest = File(destPath);
    await dest.parent.create(recursive: true);
    if (await dest.exists()) {
      await dest.delete();
    }

    final request = http.Request('GET', Uri.parse(zipUrl));
    request.headers.addAll(_authHeaders(doc));
    final streamed = await _client.send(request).timeout(
          const Duration(minutes: 30),
        );
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final body = await streamed.stream.bytesToString();
      throw StateError(
        'Jenkins download failed HTTP ${streamed.statusCode} url=$zipUrl '
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
      throw StateError('Downloaded zip is empty: $destPath');
    }
    stdout.writeln(
      '[jenkins] saved ${p.basename(destPath)} '
      '(${await dest.length()} bytes) -> $destPath',
    );
    return dest;
  }

  void close() => _client.close();
}
