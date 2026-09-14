import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Persistent, cross-isolate log. On Android the monitoring loop runs in the
/// foreground-service isolate, whose memory the UI isolate cannot see — so
/// every line is appended to one shared file (both isolates write to it,
/// SystemLogsScreen re-reads it), in addition to the in-memory buffer and
/// `print` (which, unlike `dart:developer`'s log, reaches `adb logcat` in
/// release builds too, tagged `I/flutter`).
class AppLogger {
  AppLogger._();

  static const int _maxEntries = 1000;
  static const int _maxFileBytes = 512 * 1024;
  static const String _fileName = 'aureus_logs.txt';

  static final List<String> _entries = [];
  static final List<String> _pending = [];
  static File? _file;
  static Future<void>? _initFuture;
  static Future<void> _writeChain = Future.value();
  static String _tag = 'UI';

  /// Bumped whenever [entries] changes — listen to rebuild a UI live.
  static final ValueNotifier<int> version = ValueNotifier(0);

  static List<String> get entries => List.unmodifiable(_entries);

  /// Call once per isolate before (or soon after) the first [log]. Lines
  /// logged earlier are buffered and flushed once the file is resolved.
  /// Only the UI isolate should pass [trim] — trimming rewrites the file.
  static Future<void> init({required String isolateTag, bool trim = false}) {
    _tag = isolateTag;
    return _initFuture ??= _init(trim);
  }

  static Future<void> _init(bool trim) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      if (trim && await file.exists() && await file.length() > _maxFileBytes) {
        final lines = await file.readAsLines();
        final keep = lines.length > _maxEntries ? lines.sublist(lines.length - _maxEntries) : lines;
        await file.writeAsString('${keep.join('\n')}\n', flush: true);
      }
      _file = file;
      if (_pending.isNotEmpty) {
        final buffered = _pending.join();
        _pending.clear();
        _enqueueWrite(buffered);
      }
      await refreshFromDisk();
    } catch (e) {
      // ignore: avoid_print
      print('[AureusAI] AppLogger init failed: $e');
    }
  }

  static void log(String message) {
    final line = '${DateTime.now().toIso8601String()} [$_tag] $message';
    _entries.add(line);
    if (_entries.length > _maxEntries) _entries.removeRange(0, _entries.length - _maxEntries);
    version.value++;
    // ignore: avoid_print
    print('[AureusAI] $line');

    if (_file == null) {
      _pending.add('$line\n');
    } else {
      _enqueueWrite('$line\n');
    }
  }

  static void _enqueueWrite(String text) {
    final file = _file;
    if (file == null) return;
    _writeChain = _writeChain
        .then((_) => file.writeAsString(text, mode: FileMode.append))
        .then((_) {}, onError: (_) {});
  }

  /// Replaces the in-memory buffer with the shared file's tail, so lines
  /// written by the OTHER isolate show up too.
  static Future<void> refreshFromDisk() async {
    final file = _file;
    if (file == null) return;
    try {
      await _writeChain;
      if (!await file.exists()) return;
      final lines = (await file.readAsLines()).where((l) => l.isNotEmpty).toList();
      final tail = lines.length > _maxEntries ? lines.sublist(lines.length - _maxEntries) : lines;
      final changed = tail.length != _entries.length || (tail.isNotEmpty && tail.last != _entries.last);
      if (!changed) return;
      _entries
        ..clear()
        ..addAll(tail);
      version.value++;
    } catch (_) {}
  }

  static Future<void> clear() async {
    _entries.clear();
    version.value++;
    final file = _file;
    if (file == null) return;
    _writeChain = _writeChain.then((_) => file.writeAsString('')).then((_) {}, onError: (_) {});
    await _writeChain;
  }
}
