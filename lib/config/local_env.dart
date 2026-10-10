import 'dart:io';

/// Settings read from a file that is NOT bundled inside the app.
///
/// The `.env` asset ships inside every build, so a secret in it can be read by
/// anyone who can open the app package. A file beside the executable (or in the
/// user's own profile folder) never leaves the machine it was written on, and its
/// values override the bundled ones — so a distributed build can carry no secret
/// at all and each machine adds its own `BRIDGE_API_KEY` locally.
class LocalEnv {
  LocalEnv._();

  static const fileName = 'aureus.local.env';

  /// Keys supplied by the local file (empty when there is none).
  static Set<String> providedKeys = {};

  /// The file the values came from, or null.
  static String? loadedFrom;

  /// KEY=VALUE per line; blank lines and `#` comments ignored; one pair of
  /// surrounding quotes stripped. Malformed lines are skipped, never fatal.
  static Map<String, String> parse(String text) {
    final out = <String, String>{};
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final key = line.substring(0, eq).trim();
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) continue;
      var value = line.substring(eq + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      out[key] = value;
    }
    return out;
  }

  /// Where the file may live, most specific first: beside the executable, in the
  /// user's profile (%APPDATA%\AureusAI), then the working directory.
  static List<String> defaultCandidates() {
    final paths = <String>[];
    try {
      paths.add('${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}$fileName');
    } catch (_) {}
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      paths.add('$appData${Platform.pathSeparator}AureusAI${Platform.pathSeparator}$fileName');
    }
    paths.add(fileName);
    return paths;
  }

  /// Loads the first candidate that exists. Never throws: a missing or unreadable
  /// file simply means "no local overrides". Records what it found in [providedKeys]
  /// and [loadedFrom].
  static Future<Map<String, String>> load({List<String>? candidates}) async {
    providedKeys = {};
    loadedFrom = null;
    for (final path in candidates ?? defaultCandidates()) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final values = parse(await file.readAsString());
        providedKeys = values.keys.toSet();
        loadedFrom = path;
        return values;
      } catch (_) {
        continue;
      }
    }
    return const {};
  }
}
