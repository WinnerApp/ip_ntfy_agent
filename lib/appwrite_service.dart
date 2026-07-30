import 'dart:convert';
import 'dart:io';

import 'package:dart_appwrite/dart_appwrite.dart';
import 'package:dart_appwrite/models.dart' hide File;
import 'package:path/path.dart' as p;

import 'config.dart';

class HostDocument {
  HostDocument({
    required this.id,
    required this.url,
    required this.userName,
    required this.password,
    required this.active,
    required this.online,
    required this.raw,
  });

  final String id;
  final String? url;
  final String? userName;
  final String? password;
  final bool? active;
  final bool? online;
  final Map<String, dynamic> raw;
}

class ResourceUploadResult {
  ResourceUploadResult({
    required this.fileId,
    required this.buildId,
    required this.tag,
    required this.documentId,
    required this.downloadUrl,
    required this.replaced,
  });

  final String fileId;
  final String buildId;
  final String tag;
  final String documentId;
  final String downloadUrl;
  final bool replaced;

  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'buildId': buildId,
        'tag': tag,
        'documentId': documentId,
        'downloadUrl': downloadUrl,
        'replaced': replaced,
      };
}

class ResourceDeleteResult {
  ResourceDeleteResult({
    required this.buildId,
    required this.tag,
    required this.deleted,
    this.documentId,
    this.fileId,
    this.fileDeleted = false,
  });

  final String buildId;
  final String tag;
  final bool deleted;
  final String? documentId;
  final String? fileId;
  final bool fileDeleted;

  Map<String, dynamic> toJson() => {
        'buildId': buildId,
        'tag': tag,
        'deleted': deleted,
        'documentId': documentId,
        'fileId': fileId,
        'fileDeleted': fileDeleted,
      };
}

class AppwriteService {
  AppwriteService(this.config) {
    final client = Client(endPoint: config.appwriteEndpoint)
        .setProject(config.appwriteProjectId)
        .setKey(config.appwriteApiKey)
        .setSelfSigned(status: config.appwriteSelfSigned);
    _databases = Databases(client);
    _storage = Storage(client);
  }

  final AppConfig config;
  late final Databases _databases;
  late final Storage _storage;

  HostDocument? _cached;

  HostDocument? get cached => _cached;

  Future<HostDocument?> loadByTag() async {
    // Databases API matches console collection path; TablesDB is the newer alias.
    // ignore: deprecated_member_use
    final list = await _databases.listDocuments(
      databaseId: config.appwriteDatabaseId,
      collectionId: config.appwriteCollectionId,
      queries: [
        Query.equal('tag', config.tagValue),
        Query.limit(1),
      ],
    );

    if (list.documents.isEmpty) {
      _cached = null;
      return null;
    }

    _cached = _fromDocument(list.documents.first);
    return _cached;
  }

  Future<void> updateUrl(String url) async {
    final doc = _cached;
    if (doc == null) {
      throw StateError('No Appwrite document loaded; cannot update url');
    }
    if (doc.url == url) return;

    // ignore: deprecated_member_use
    final updated = await _databases.updateDocument(
      databaseId: config.appwriteDatabaseId,
      collectionId: config.appwriteCollectionId,
      documentId: doc.id,
      data: {config.urlAttr: url},
    );
    _cached = _fromDocument(updated);
  }

  Future<void> updateOnline(bool online) async {
    final doc = _cached;
    if (doc == null) {
      throw StateError('No Appwrite document loaded; cannot update online');
    }
    if (doc.online == online) return;

    // ignore: deprecated_member_use
    final updated = await _databases.updateDocument(
      databaseId: config.appwriteDatabaseId,
      collectionId: config.appwriteCollectionId,
      documentId: doc.id,
      data: {config.onlineAttr: online},
    );
    _cached = _fromDocument(updated);
  }

  /// Upload a local `.zip` to Storage and upsert resource metadata
  /// (`tag` / `fileId` / `buildId`) keyed by tag + buildId.
  Future<ResourceUploadResult> uploadZipResource({
    required String path,
    required String buildId,
    String? tag,
  }) async {
    final resolvedTag = (tag ?? config.tagValue).trim();
    final resolvedBuildId = buildId.trim();
    if (resolvedTag.isEmpty) {
      throw ArgumentError('tag is required');
    }
    if (resolvedBuildId.isEmpty) {
      throw ArgumentError('buildId is required');
    }

    final file = File(path);
    if (!file.existsSync()) {
      throw StateError('File not found: $path');
    }
    if (p.extension(path).toLowerCase() != '.zip') {
      throw ArgumentError('Only .zip files are allowed: $path');
    }

    final existing = await _findResourceDoc(
      tag: resolvedTag,
      buildId: resolvedBuildId,
    );
    final oldFileId = existing?.data['fileId']?.toString();

    final fileId = ID.unique();
    final uploaded = await _storage.createFile(
      bucketId: config.appwriteBucketId,
      fileId: fileId,
      file: InputFile.fromPath(
        path: path,
        filename: p.basename(path),
        contentType: 'application/zip',
      ),
    );

    late final Document resourceDoc;
    final data = {
      'tag': resolvedTag,
      'fileId': uploaded.$id,
      'buildId': resolvedBuildId,
    };

    if (existing == null) {
      // ignore: deprecated_member_use
      resourceDoc = await _databases.createDocument(
        databaseId: config.appwriteDatabaseId,
        collectionId: config.appwriteResourceCollectionId,
        documentId: ID.unique(),
        data: data,
      );
    } else {
      // ignore: deprecated_member_use
      resourceDoc = await _databases.updateDocument(
        databaseId: config.appwriteDatabaseId,
        collectionId: config.appwriteResourceCollectionId,
        documentId: existing.$id,
        data: data,
      );
      if (oldFileId != null &&
          oldFileId.isNotEmpty &&
          oldFileId != uploaded.$id) {
        try {
          await _storage.deleteFile(
            bucketId: config.appwriteBucketId,
            fileId: oldFileId,
          );
        } catch (e) {
          stderr.writeln(
            '[appwrite] delete old file $oldFileId failed: $e',
          );
        }
      }
    }

    return ResourceUploadResult(
      fileId: uploaded.$id,
      buildId: resolvedBuildId,
      tag: resolvedTag,
      documentId: resourceDoc.$id,
      downloadUrl: fileDownloadUrl(uploaded.$id),
      replaced: existing != null,
    );
  }

  /// Delete resource metadata and Storage file keyed by tag + buildId.
  Future<ResourceDeleteResult> deleteZipResource({
    required String buildId,
    String? tag,
  }) async {
    final resolvedTag = (tag ?? config.tagValue).trim();
    final resolvedBuildId = buildId.trim();
    if (resolvedTag.isEmpty) {
      throw ArgumentError('tag is required');
    }
    if (resolvedBuildId.isEmpty) {
      throw ArgumentError('buildId is required');
    }

    final existing = await _findResourceDoc(
      tag: resolvedTag,
      buildId: resolvedBuildId,
    );
    if (existing == null) {
      return ResourceDeleteResult(
        buildId: resolvedBuildId,
        tag: resolvedTag,
        deleted: false,
      );
    }

    final fileId = existing.data['fileId']?.toString();
    var fileDeleted = false;
    if (fileId != null && fileId.isNotEmpty) {
      try {
        await _storage.deleteFile(
          bucketId: config.appwriteBucketId,
          fileId: fileId,
        );
        fileDeleted = true;
      } catch (e) {
        stderr.writeln('[appwrite] delete file $fileId failed: $e');
      }
    }

    // ignore: deprecated_member_use
    await _databases.deleteDocument(
      databaseId: config.appwriteDatabaseId,
      collectionId: config.appwriteResourceCollectionId,
      documentId: existing.$id,
    );

    return ResourceDeleteResult(
      buildId: resolvedBuildId,
      tag: resolvedTag,
      deleted: true,
      documentId: existing.$id,
      fileId: fileId,
      fileDeleted: fileDeleted,
    );
  }

  String fileDownloadUrl(String fileId) {
    final base = config.appwriteEndpoint.replaceAll(RegExp(r'/+$'), '');
    return '$base/storage/buckets/${config.appwriteBucketId}'
        '/files/$fileId/download'
        '?project=${config.appwriteProjectId}';
  }

  Future<Document?> _findResourceDoc({
    required String tag,
    required String buildId,
  }) async {
    // ignore: deprecated_member_use
    final list = await _databases.listDocuments(
      databaseId: config.appwriteDatabaseId,
      collectionId: config.appwriteResourceCollectionId,
      queries: [
        Query.equal('tag', tag),
        Query.equal('buildId', buildId),
        Query.limit(1),
      ],
    );
    if (list.documents.isEmpty) return null;
    return list.documents.first;
  }

  HostDocument _fromDocument(Document document) {
    final data = Map<String, dynamic>.from(document.data);
    data.removeWhere((key, _) => key.startsWith(r'$'));

    return HostDocument(
      id: document.$id,
      url: data[config.urlAttr]?.toString(),
      userName: data[config.userNameAttr]?.toString(),
      password: data[config.passwordAttr]?.toString(),
      active: _asBool(data[config.activeAttr]),
      online: _asBool(data[config.onlineAttr]),
      raw: data,
    );
  }

  bool? _asBool(dynamic value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value.toString().toLowerCase().trim();
    if (text == 'true' || text == '1' || text == 'yes' || text == 'online') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'no' || text == 'offline') {
      return false;
    }
    return null;
  }

  @override
  String toString() => jsonEncode(_cached?.raw ?? {});
}
