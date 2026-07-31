import 'dart:io';

/// Resolve the preferred local IPv4 address (non-loopback).
Future<String?> getLocalIpv4() async {
  final interfaces = await NetworkInterface.list(
    includeLinkLocal: false,
    type: InternetAddressType.IPv4,
  );

  final preferredPrefixes = ['10.', '192.168.', '172.'];
  final addresses = <String>[];

  for (final iface in interfaces) {
    for (final addr in iface.addresses) {
      if (addr.isLoopback) continue;
      addresses.add(addr.address);
    }
  }

  for (final prefix in preferredPrefixes) {
    for (final ip in addresses) {
      if (ip.startsWith(prefix)) return ip;
    }
  }

  return addresses.isEmpty ? null : addresses.first;
}

String ipToTopic(String ip) => 'topic_${ip.replaceAll('.', '_')}';

String urlFromIp(String ip) => 'http://$ip:8080';

/// Replace host in [existingUrl] with [ip], keeping scheme/port/path/query.
/// Falls back to `http://$ip:8080` when [existingUrl] is missing or invalid.
/// 若原 URL 无端口，补 Jenkins 默认 8080，避免下载 zip 打到 80 端口。
String urlWithHost(String? existingUrl, String ip) {
  if (existingUrl == null || existingUrl.trim().isEmpty) {
    return urlFromIp(ip);
  }
  try {
    final uri = Uri.parse(existingUrl.trim());
    if (uri.host.isEmpty) return urlFromIp(ip);
    var next = uri.replace(host: ip);
    if (!next.hasPort) {
      next = next.replace(port: 8080);
    }
    return next.toString();
  } catch (_) {
    return urlFromIp(ip);
  }
}

String? ipFromUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  try {
    final uri = Uri.parse(url);
    return uri.host.isEmpty ? null : uri.host;
  } catch (_) {
    return null;
  }
}
