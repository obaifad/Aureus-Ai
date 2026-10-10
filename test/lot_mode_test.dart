import 'package:aureus_ai/services/risk_engine.dart';
import 'package:aureus_ai/services/strategy_config_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

StrategyConfigSnapshot _snapshot({String? mode, num? fixed}) => StrategyConfigSnapshot.fromResponse({
      'revision': 7,
      'config': {
        'account_limits': {
          if (mode != null) 'lot_mode': mode,
          if (fixed != null) 'fixed_lot_size': fixed,
        },
      },
    });

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StrategyConfig.instance.resetForTesting();
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true\nMIN_LOT_SIZE=0.01\nMAX_LOT_SIZE=5\nLOT_STEP=0.01');
  });
  tearDown(() => StrategyConfig.instance.resetForTesting());

  group('what the bridge config says about the lot', () {
    test('mode and fixed size are read from account_limits', () {
      final snapshot = _snapshot(mode: 'fixed', fixed: 0.05);
      expect(snapshot.lotMode, 'fixed');
      expect(snapshot.fixedLotSize, 0.05);
    });

    test('an integer from the bridge is read as a number', () {
      expect(_snapshot(mode: 'fixed', fixed: 2).fixedLotSize, 2.0);
    });

    test('a bridge that does not know the setting gives null, so nothing changes', () {
      expect(_snapshot().lotMode, isNull);
      expect(_snapshot().fixedLotSize, isNull);
      expect(StrategyConfigSnapshot.empty.lotMode, isNull);
    });
  });

  group('RiskEngine.sizeLot', () {
    final engine = RiskEngine();
    // 10,000 equity, 1% = 100 at a 10.00 stop: 100 / (100 pips x $10 per lot per pip) = 0.10 lot
    double size({double equity = 10000, double stop = 10}) => engine.sizeLot(equity: equity, stopLossDollars: stop);

    test('with no config, or dynamic mode, the lot comes from the risk percentage as before', () {
      expect(size(), 0.1);
      StrategyConfig.instance.setSnapshot(_snapshot(mode: 'dynamic', fixed: 0.5));
      expect(size(), 0.1);
      expect(size(equity: 20000), 0.2);
      expect(size(stop: 5), 0.2);
    });

    test('fixed mode ignores equity and stop distance', () {
      StrategyConfig.instance.setSnapshot(_snapshot(mode: 'fixed', fixed: 0.05));
      expect(size(), 0.05);
      expect(size(equity: 1000000), 0.05);
      expect(size(equity: 50), 0.05);
      expect(size(stop: 1), 0.05);
      expect(size(stop: 30), 0.05);
    });

    test('a fixed lot between steps is rounded down, never up', () {
      StrategyConfig.instance.setSnapshot(_snapshot(mode: 'fixed', fixed: 0.057));
      expect(size(), 0.05);
      StrategyConfig.instance.setSnapshot(_snapshot(mode: 'fixed', fixed: 0.3));
      expect(size(), 0.3, reason: 'float noise must not drop a whole step');
      StrategyConfig.instance.setSnapshot(_snapshot(mode: 'fixed', fixed: 0.07));
      expect(size(), 0.07);
    });

    test('a fixed lot is kept inside the allowed range', () {
      StrategyConfig.instance.setSnapshot(_snapshot(mode: 'fixed', fixed: 9));
      expect(size(), 5.0);
      StrategyConfig.instance.setSnapshot(_snapshot(mode: 'fixed', fixed: 0.001));
      expect(size(), 0.01);
    });

    test('fixed mode without a size falls back to the smallest lot', () {
      StrategyConfig.instance.setSnapshot(_snapshot(mode: 'fixed'));
      expect(size(), 0.01);
    });

    test('switching back to dynamic sizes by risk again', () {
      StrategyConfig.instance.setSnapshot(_snapshot(mode: 'fixed', fixed: 0.05));
      expect(size(), 0.05);
      StrategyConfig.instance.setSnapshot(_snapshot(mode: 'dynamic', fixed: 0.05));
      expect(size(), 0.1);
    });
  });
}
