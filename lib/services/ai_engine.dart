import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import '../models/pivot.dart';
import '../models/trade_setup.dart';
import 'data_service.dart' show bridgeHeaders;

/// Sends the raw trade setup to an LLM (Claude) to get a short,
/// professional 2-bullet explanation of the trade thesis.
///
/// NOTE: for a production mobile app, calling the Anthropic API
/// directly from the client exposes your API key. Prefer routing this
/// through the same backend bridge that serves MT5 data (a single
/// `/ai-commentary` proxy endpoint) — the direct call below is kept
/// simple for local/dev use.
class AiEngine {
  static const _endpoint = 'https://api.anthropic.com/v1/messages';

  Future<String> explainSetup(TradeSetup setup) async {
    if (!AppConfig.useMockData && !AppConfig.disableMt5Bridge) {
      final viaBridge = await _explainViaBridge(setup);
      if (viaBridge != null) return viaBridge;
    }
    if (AppConfig.anthropicApiKey.isEmpty) {
      return _fallbackReason(setup);
    }

    final prompt = '''
You are a professional XAUUSD (Gold) technical analyst. A trading system just
detected the following confluence-based setup:

- Direction: ${setup.directionLabel}
- Timeframe: ${setup.timeframeLabel}
- Entry: ${setup.entry}
- Stop Loss: ${setup.stopLoss}
- Take Profit: ${setup.takeProfit} (R:R = 1:${AppConfig.riskRewardRatio.toStringAsFixed(0)})
- Confirmation pattern: ${setup.pattern.name}

Write exactly 2 short bullet points (each under 20 words) explaining the
trade thesis in plain, professional language. No preamble, no disclaimer,
just the two bullets.
''';

    try {
      final response = await http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': AppConfig.anthropicApiKey,
              'anthropic-version': '2023-06-01',
            },
            body: jsonEncode({
              'model': AppConfig.anthropicModel,
              'max_tokens': 200,
              'messages': [
                {'role': 'user', 'content': prompt},
              ],
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        return _fallbackReason(setup);
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final content = data['content'] as List<dynamic>;
      final text = content
          .map((block) => (block as Map<String, dynamic>)['text'] ?? '')
          .join('\n')
          .trim();

      return text.isEmpty ? _fallbackReason(setup) : text;
    } catch (_) {
      return _fallbackReason(setup);
    }
  }

  /// The bridge's /ai-commentary proxy keeps the Anthropic key on the PC.
  /// Returns null when the bridge is unreachable or has no key configured.
  Future<String?> _explainViaBridge(TradeSetup setup) async {
    try {
      final response = await http
          .post(
            Uri.parse('${AppConfig.bridgeBaseUrl}/ai-commentary'),
            headers: {'Content-Type': 'application/json', ...bridgeHeaders()},
            body: jsonEncode({
              'symbol': setup.symbol,
              'direction': setup.directionLabel,
              'timeframe': setup.timeframeLabel,
              'setup_type': setup.setupType.label,
              'entry': setup.entry,
              'stop_loss': setup.stopLoss,
              'take_profit': setup.takeProfit,
              'pattern': setup.pattern.name,
              'risk_reward': setup.riskRewardRatio,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;
      final text = (jsonDecode(response.body) as Map<String, dynamic>)['text'] as String?;
      return (text == null || text.trim().isEmpty) ? null : text.trim();
    } catch (_) {
      return null;
    }
  }

  /// Simple deterministic explanation used when no API key is set or the
  /// request fails, so the UI never gets stuck on "Generating…".
  String _fallbackReason(TradeSetup setup) {
    final dir = setup.direction == TradeDirection.buy ? 'bullish' : 'bearish';
    return '• Price reacted at the trendline/S/R confluence with a $dir '
        '${setup.pattern.shapeLabel} confirmation.\n'
        '• Setup offers a clean 1:${AppConfig.riskRewardRatio.toStringAsFixed(0)} '
        'risk-to-reward from the confirmation candle close.';
  }
}
