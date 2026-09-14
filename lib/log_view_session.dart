import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

/// In-memory registry of read-only log snapshots for online viewing.
class LogViewSessionStore {
  LogViewSessionStore({
    this.idleTimeout = const Duration(minutes: 30),
    Duration sweepInterval = const Duration(minutes: 1),
  }) {
    _sweepTimer = Timer.periodic(sweepInterval, (_) {
      unawaited(sweepExpired());
    });
  }

  final Duration idleTimeout;
  final _sessions = <String, LogViewSession>{};
  Timer? _sweepTimer;

  LogViewSession? operator [](String sessionId) => _sessions[sessionId];

  void put(LogViewSession session) {
    _sessions[session.sessionId] = session;
  }

  Future<bool> close(String sessionId) async {
    final session = _sessions.remove(sessionId);
    if (session == null) return false;
    await session.dispose();
    return true;
  }

  Future<void> sweepExpired() async {
    final now = DateTime.now();
    final expired = <String>[];
    for (final entry in _sessions.entries) {
      if (now.difference(entry.value.lastAccess) >= idleTimeout) {
        expired.add(entry.key);
      }
    }
    for (final id in expired) {
      await close(id);
    }
  }

  Future<void> disposeAll() async {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    final ids = _sessions.keys.toList();
    for (final id in ids) {
      await close(id);
    }
  }

  static String newSessionId() =>
      'lv_${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(1 << 20)}';
}

class LogViewSession {
  LogViewSession({
    required this.sessionId,
    required this.dir,
    required this.snapshot,
  }) : lastAccess = DateTime.now();

  final String sessionId;
  final Directory dir;
  final File snapshot;
  DateTime lastAccess;

  void touch() => lastAccess = DateTime.now();

  Future<int> get size async => snapshot.length();

  Future<void> dispose() async {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }
}

/// Read up to [lines] complete lines ending strictly before [beforeOffset]
/// (or EOF when null). Offsets are relative to the snapshot file.
Future<LogChunk> readLogChunkBefore(
  File file, {
  required int lines,
  int? beforeOffset,
}) async {
  final size = await file.length();
  var end = beforeOffset ?? size;
  if (end > size) end = size;
  if (end < 0) end = 0;
  if (lines < 1 || end <= 0) {
    return LogChunk(
      text: '',
      lineCount: 0,
      startOffset: 0,
      endOffset: end,
      hasMore: false,
      size: size,
    );
  }

  const windowSize = 16 * 1024;
  var readStart = end;
  List<int> region = const [];
  var attempts = 0;

  while (attempts < 32) {
    attempts++;
    final grow = windowSize * attempts;
    readStart = math.max(0, end - grow);

    final raf = await file.open();
    try {
      await raf.setPosition(readStart);
      region = await raf.read(end - readStart);
    } finally {
      await raf.close();
    }

    final parsed = _parseLinesInRegion(
      region,
      regionFileOffset: readStart,
      skipPartialFirstLine: readStart > 0,
    );
    if (parsed.length >= lines || readStart == 0) {
      final selected = parsed.length > lines
          ? parsed.sublist(parsed.length - lines)
          : parsed;
      if (selected.isEmpty) {
        return LogChunk(
          text: '',
          lineCount: 0,
          startOffset: end,
          endOffset: end,
          hasMore: end > 0,
          size: size,
        );
      }
      final startOffset = selected.first.startOffset;
      final text = selected.map((e) => e.text).join('\n');
      return LogChunk(
        text: text,
        lineCount: selected.length,
        startOffset: startOffset,
        endOffset: end,
        hasMore: startOffset > 0,
        size: size,
      );
    }
  }

  // Fallback: return whatever we parsed.
  final parsed = _parseLinesInRegion(
    region,
    regionFileOffset: readStart,
    skipPartialFirstLine: readStart > 0,
  );
  final selected =
      parsed.length > lines ? parsed.sublist(parsed.length - lines) : parsed;
  if (selected.isEmpty) {
    return LogChunk(
      text: '',
      lineCount: 0,
      startOffset: end,
      endOffset: end,
      hasMore: end > 0,
      size: size,
    );
  }
  final startOffset = selected.first.startOffset;
  return LogChunk(
    text: selected.map((e) => e.text).join('\n'),
    lineCount: selected.length,
    startOffset: startOffset,
    endOffset: end,
    hasMore: startOffset > 0,
    size: size,
  );
}

class LogChunk {
  const LogChunk({
    required this.text,
    required this.lineCount,
    required this.startOffset,
    required this.endOffset,
    required this.hasMore,
    required this.size,
  });

  final String text;
  final int lineCount;
  final int startOffset;
  final int endOffset;
  final bool hasMore;
  final int size;

  Map<String, dynamic> toBody({String? sessionId}) => {
        'sessionId': ?sessionId,
        'text': text,
        'lineCount': lineCount,
        'startOffset': startOffset,
        'endOffset': endOffset,
        'hasMore': hasMore,
        'size': size,
      };
}

class _LineSpan {
  const _LineSpan({
    required this.startOffset,
    required this.text,
  });

  final int startOffset;
  final String text;
}

List<_LineSpan> _parseLinesInRegion(
  List<int> region, {
  required int regionFileOffset,
  required bool skipPartialFirstLine,
}) {
  var offsetInRegion = 0;
  if (skipPartialFirstLine) {
    final nl = region.indexOf(0x0A);
    if (nl < 0) return const [];
    offsetInRegion = nl + 1;
  }

  final lines = <_LineSpan>[];
  var i = offsetInRegion;
  while (i < region.length) {
    var j = i;
    while (j < region.length && region[j] != 0x0A) {
      j++;
    }
    final lineBytes = region.sublist(i, j);
    lines.add(
      _LineSpan(
        startOffset: regionFileOffset + i,
        text: utf8.decode(lineBytes, allowMalformed: true),
      ),
    );
    if (j >= region.length) break;
    i = j + 1; // skip '\n'
  }
  return lines;
}

Future<LogViewSession> createSnapshotSession({
  required File source,
  String snapshotName = 'snapshot.log',
}) async {
  if (!await source.exists()) {
    throw StateError('Log file not found: ${source.path}');
  }
  final sessionId = LogViewSessionStore.newSessionId();
  final dir = await Directory.systemTemp.createTemp('log_view_${sessionId}_');
  final dest = File(p.join(dir.path, snapshotName));
  await source.copy(dest.path);
  return LogViewSession(sessionId: sessionId, dir: dir, snapshot: dest);
}

Future<LogViewSession> createSnapshotSessionFromBytes({
  required List<int> bytes,
  String snapshotName = 'snapshot.log',
}) async {
  final sessionId = LogViewSessionStore.newSessionId();
  final dir = await Directory.systemTemp.createTemp('log_view_${sessionId}_');
  final dest = File(p.join(dir.path, snapshotName));
  await dest.writeAsBytes(bytes, flush: true);
  return LogViewSession(sessionId: sessionId, dir: dir, snapshot: dest);
}

int clampLogViewLines(Object? raw, {int fallback = 10}) {
  var lines = fallback;
  if (raw is num) {
    lines = raw.toInt();
  } else if (raw != null) {
    lines = int.tryParse('$raw') ?? fallback;
  }
  if (lines < 1) lines = 1;
  if (lines > 200) lines = 200;
  return lines;
}

int? parseBeforeOffset(Object? raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toInt();
  return int.tryParse('$raw');
}
