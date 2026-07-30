import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:path/path.dart' as p;

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

  factory AppConfig.load([String? envPath]) {
    final file = envPath ?? _resolveEnvPath();
    final env = DotEnv(includePlatformEnvironment: true)..load([file]);

    String require(String key) {
      final value = env[key]?.trim();
      if (value == null || value.isEmpty) {
        throw StateError('Missing required env: $key (file: $file)');
      }
      return value;
    }

    String? optional(String key) {
      final value = env[key]?.trim();
      if (value == null || value.isEmpty) return null;
      return value;
    }

    return AppConfig._(
      appwriteEndpoint: require('APPWRITE_ENDPOINT'),
      appwriteProjectId: require('APPWRITE_PROJECT_ID'),
      appwriteApiKey: require('APPWRITE_API_KEY'),
      appwriteDatabaseId: require('APPWRITE_DATABASE_ID'),
      appwriteCollectionId: require('APPWRITE_COLLECTION_ID'),
      appwriteBucketId:
          optional('APPWRITE_BUCKET_ID') ?? '6a6b20d0002630974471',
      appwriteResourceCollectionId: optional(
            'APPWRITE_RESOURCE_COLLECTION_ID',
          ) ??
          '6a6b2e2c001091ff8ef0',
      appwriteSelfSigned:
          (optional('APPWRITE_SELF_SIGNED') ?? 'false').toLowerCase() == 'true',
      tagValue: optional('APPWRITE_TAG_VALUE') ?? 'test',
      urlAttr: optional('APPWRITE_URL_ATTR') ?? 'url',
      userNameAttr: optional('APPWRITE_USERNAME_ATTR') ?? 'userName',
      passwordAttr: optional('APPWRITE_PASSWORD_ATTR') ?? 'password',
      activeAttr: optional('APPWRITE_ACTIVE_ATTR') ?? 'active',
      onlineAttr: optional('APPWRITE_ONLINE_ATTR') ?? 'online',
      ntfyBaseUrl: optional('NTFY_BASE_URL') ?? 'https://ntfy.sh',
      ntfyAuth: optional('NTFY_AUTH'),
      feishuWebhookUrl: optional('FEISHU_WEBHOOK_URL'),
      ipCheckInterval: Duration(
        seconds: int.parse(optional('IP_CHECK_INTERVAL_SECONDS') ?? '5'),
      ),
      jenkinsCheckInterval: Duration(
        seconds: int.parse(optional('JENKINS_CHECK_INTERVAL_SECONDS') ?? '60'),
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
