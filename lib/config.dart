import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:path/path.dart' as p;

class ConfigException implements Exception {
  ConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AppConfig {
  final String appwriteEndpoint;
  final String appwriteProjectId;
  final String appwriteApiKey;
  final String appwriteDatabaseId;
  final String appwriteCollectionId;
  final String appwriteBucketId;
  final String appwriteResourceCollectionId;
  final bool appwriteSelfSigned;
  final String tagValue;
  final String urlAttr;
  final String userNameAttr;
  final String passwordAttr;
  final String activeAttr;
  final String onlineAttr;
  final String ntfyBaseUrl;
  final String? ntfyAuth;
  final String? feishuWebhookUrl;
  final Duration ipCheckInterval;
  final Duration jenkinsCheckInterval;

  AppConfig._({
    required this.appwriteEndpoint,
    required this.appwriteProjectId,
    required this.appwriteApiKey,
    required this.appwriteDatabaseId,
    required this.appwriteCollectionId,
    required this.appwriteBucketId,
    required this.appwriteResourceCollectionId,
    required this.appwriteSelfSigned,
    required this.tagValue,
    required this.urlAttr,
    required this.userNameAttr,
    required this.passwordAttr,
    required this.activeAttr,
    required this.onlineAttr,
    required this.ntfyBaseUrl,
    required this.ntfyAuth,
    required this.feishuWebhookUrl,
    required this.ipCheckInterval,
    required this.jenkinsCheckInterval,
  });

  /// Keys that must be present and non-empty in `.env`.
  static const requiredKeys = <String>[
    'APPWRITE_ENDPOINT',
    'APPWRITE_PROJECT_ID',
    'APPWRITE_API_KEY',
    'APPWRITE_DATABASE_ID',
    'APPWRITE_COLLECTION_ID',
    'APPWRITE_BUCKET_ID',
    'APPWRITE_RESOURCE_COLLECTION_ID',
    'APPWRITE_TAG_VALUE',
    'NTFY_BASE_URL',
  ];

  static const _placeholderValues = <String>{
    'your_api_key_here',
    'changeme',
    'xxx',
    'todo',
    'replace_me',
    '<api_key>',
    '<token>',
  };

  factory AppConfig.load([String? envPath]) {
    final file = envPath ?? _resolveEnvPath();
    if (!File(file).existsSync()) {
      throw ConfigException(
        '未找到 .env 配置文件: $file\n'
        '请复制 .env.example 为 .env 并填写完整配置。\n'
        '示例: cp .env.example .env',
      );
    }

    final env = DotEnv(includePlatformEnvironment: true)..load([file]);

    String? read(String key) {
      final value = env[key]?.trim();
      if (value == null || value.isEmpty) return null;
      return value;
    }

    final missing = <String>[];
    final placeholders = <String>[];
    final values = <String, String>{};

    for (final key in requiredKeys) {
      final value = read(key);
      if (value == null) {
        missing.add(key);
        continue;
      }
      if (_placeholderValues.contains(value.toLowerCase())) {
        placeholders.add(key);
        continue;
      }
      values[key] = value;
    }

    if (missing.isNotEmpty || placeholders.isNotEmpty) {
      final buf = StringBuffer('.env 配置未完成 (file: $file)');
      if (missing.isNotEmpty) {
        buf.writeln();
        buf.writeln('缺少必填项:');
        for (final key in missing) {
          buf.writeln('  - $key');
        }
      }
      if (placeholders.isNotEmpty) {
        buf.writeln();
        buf.writeln('仍为占位符，请替换为真实值:');
        for (final key in placeholders) {
          buf.writeln('  - $key');
        }
      }
      buf.writeln();
      buf.write('参考 .env.example 补全后重试。');
      throw ConfigException(buf.toString());
    }

    String? optional(String key) => read(key);

    int parsePositiveInt(String key, String fallback) {
      final raw = optional(key) ?? fallback;
      final parsed = int.tryParse(raw);
      if (parsed == null || parsed <= 0) {
        throw ConfigException(
          '无效配置 $key=$raw（须为正整数，file: $file）',
        );
      }
      return parsed;
    }

    return AppConfig._(
      appwriteEndpoint: values['APPWRITE_ENDPOINT']!,
      appwriteProjectId: values['APPWRITE_PROJECT_ID']!,
      appwriteApiKey: values['APPWRITE_API_KEY']!,
      appwriteDatabaseId: values['APPWRITE_DATABASE_ID']!,
      appwriteCollectionId: values['APPWRITE_COLLECTION_ID']!,
      appwriteBucketId: values['APPWRITE_BUCKET_ID']!,
      appwriteResourceCollectionId: values['APPWRITE_RESOURCE_COLLECTION_ID']!,
      appwriteSelfSigned:
          (optional('APPWRITE_SELF_SIGNED') ?? 'false').toLowerCase() == 'true',
      tagValue: values['APPWRITE_TAG_VALUE']!,
      urlAttr: optional('APPWRITE_URL_ATTR') ?? 'url',
      userNameAttr: optional('APPWRITE_USERNAME_ATTR') ?? 'userName',
      passwordAttr: optional('APPWRITE_PASSWORD_ATTR') ?? 'password',
      activeAttr: optional('APPWRITE_ACTIVE_ATTR') ?? 'active',
      onlineAttr: optional('APPWRITE_ONLINE_ATTR') ?? 'online',
      ntfyBaseUrl: values['NTFY_BASE_URL']!,
      ntfyAuth: optional('NTFY_AUTH'),
      feishuWebhookUrl: optional('FEISHU_WEBHOOK_URL'),
      ipCheckInterval: Duration(
        seconds: parsePositiveInt('IP_CHECK_INTERVAL_SECONDS', '5'),
      ),
      jenkinsCheckInterval: Duration(
        seconds: parsePositiveInt('JENKINS_CHECK_INTERVAL_SECONDS', '60'),
      ),
    );
  }

  static String _resolveEnvPath() {
    final candidates = <String>[
      '.env',
      p.join(Directory.current.path, '.env'),
      p.join(p.dirname(Platform.script.toFilePath()), '..', '.env'),
      p.join(p.dirname(Platform.resolvedExecutable), '.env'),
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return '.env';
  }
}
