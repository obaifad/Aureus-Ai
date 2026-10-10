import 'dart:io';

import 'package:aureus_ai/config/app_config.dart';
import 'package:aureus_ai/config/local_env.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('aureus_local_env_');
    LocalEnv.providedKeys = {};
    LocalEnv.loadedFrom = null;
  });
  tearDown(() async {
    LocalEnv.providedKeys = {};
    LocalEnv.loadedFrom = null;
    await dir.delete(recursive: true);
  });

  group('parsing', () {
    test('reads KEY=VALUE lines and ignores comments and blanks', () {
      final values = LocalEnv.parse('# a comment\n\nBRIDGE_API_KEY=abc123\n  SPACED = value with spaces  \n');
      expect(values, {'BRIDGE_API_KEY': 'abc123', 'SPACED': 'value with spaces'});
    });

    test('strips one pair of surrounding quotes only', () {
      expect(LocalEnv.parse('A="quoted"\nB=\'single\'\nC="half'), {'A': 'quoted', 'B': 'single', 'C': '"half'});
    });

    test('keeps an equals sign inside the value (keys often end in =)', () {
      expect(LocalEnv.parse('KEY=abc=def=='), {'KEY': 'abc=def=='});
    });

    test('skips malformed lines instead of failing', () {
      expect(LocalEnv.parse('no equals here\n=novalue\n1BAD=x\nGOOD=1\nBAD KEY=2'), {'GOOD': '1'});
    });

    test('handles Windows line endings', () {
      expect(LocalEnv.parse('A=1\r\nB=2\r\n'), {'A': '1', 'B': '2'});
    });

    test('an empty file means no overrides', () {
      expect(LocalEnv.parse(''), isEmpty);
    });
  });

  group('loading', () {
    test('the first existing candidate wins and is recorded', () async {
      final first = File('${dir.path}/first.env')..writeAsStringSync('BRIDGE_API_KEY=from-first\nOTHER=1');
      File('${dir.path}/second.env').writeAsStringSync('BRIDGE_API_KEY=from-second');
      final values = await LocalEnv.load(candidates: ['${dir.path}/missing.env', first.path, '${dir.path}/second.env']);
      expect(values['BRIDGE_API_KEY'], 'from-first');
      expect(LocalEnv.loadedFrom, first.path);
      expect(LocalEnv.providedKeys, {'BRIDGE_API_KEY', 'OTHER'});
    });

    test('with no file at all there are simply no overrides', () async {
      final values = await LocalEnv.load(candidates: ['${dir.path}/nothing.env']);
      expect(values, isEmpty);
      expect(LocalEnv.loadedFrom, isNull);
      expect(LocalEnv.providedKeys, isEmpty);
    });

    test('an unreadable path never throws', () async {
      final values = await LocalEnv.load(candidates: [dir.path]); // a directory, not a file
      expect(values, isEmpty);
    });

    test('a previous load does not leak into the next one', () async {
      final file = File('${dir.path}/a.env')..writeAsStringSync('X=1');
      await LocalEnv.load(candidates: [file.path]);
      await LocalEnv.load(candidates: ['${dir.path}/gone.env']);
      expect(LocalEnv.providedKeys, isEmpty);
      expect(LocalEnv.loadedFrom, isNull);
    });

    test('the default search covers beside-the-exe, the user profile and the working directory', () {
      final candidates = LocalEnv.defaultCandidates();
      expect(candidates.every((p) => p.endsWith(LocalEnv.fileName)), isTrue);
      expect(candidates.last, LocalEnv.fileName);
      expect(candidates.length, greaterThanOrEqualTo(2));
    });
  });

  group('overriding the bundled .env', () {
    test('local values replace bundled ones when merged', () async {
      final file = File('${dir.path}/aureus.local.env')..writeAsStringSync('BRIDGE_API_KEY=local-secret');
      final local = await LocalEnv.load(candidates: [file.path]);
      dotenv.testLoad(fileInput: 'BRIDGE_API_KEY=bundled-secret\nUSE_MOCK_DATA=false');
      dotenv.env.addAll(local);
      expect(AppConfig.bridgeApiKey, 'local-secret');
    });
  });

  group('the warning about a key that ships inside the build', () {
    const live = 'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=false\nBRIDGE_API_KEY=a-long-bundled-key-0123456789\n';

    test('a bundled key is fine while the bridge is on this machine', () {
      for (final url in ['http://127.0.0.1:8000', 'http://localhost:8000', 'http://10.0.2.2:8000']) {
        dotenv.testLoad(fileInput: '${live}BRIDGE_BASE_URL=$url');
        expect(AppConfig.bundledSecretWarnings, isEmpty, reason: url);
      }
    });

    test('a bundled key with a bridge elsewhere on the network is called out', () {
      dotenv.testLoad(fileInput: '${live}BRIDGE_BASE_URL=http://192.168.1.23:8000');
      final warnings = AppConfig.bundledSecretWarnings;
      expect(warnings.single, contains('BRIDGE_API_KEY'));
      expect(warnings.single, contains(LocalEnv.fileName));
      expect(warnings.single, isNot(contains('a-long-bundled-key')));
    });

    test('a key that came from the local file is not a bundled secret', () {
      dotenv.testLoad(fileInput: '${live}BRIDGE_BASE_URL=http://192.168.1.23:8000');
      LocalEnv.providedKeys = {'BRIDGE_API_KEY'};
      expect(AppConfig.bundledSecretWarnings, isEmpty);
    });

    test('mock mode has no bridge, so no such warning', () {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true\nBRIDGE_API_KEY=k\nBRIDGE_BASE_URL=http://192.168.1.23:8000');
      expect(AppConfig.bundledSecretWarnings, isEmpty);
    });
  });
}
