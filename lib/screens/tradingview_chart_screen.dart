import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../config/app_config.dart';

/// Embeds the REAL, official TradingView "Advanced Chart" widget
/// (2026-09-13, explicit request: "بدي يجيب التشارت نفسه ذاته من
/// Tradingview") — added as its OWN screen, separate from
/// [GoldChartScreen], on the user's explicit choice: TradingView's
/// widget is an opaque WebView (their own rendering, their own real-time
/// feed), so it can never carry this app's Order Block / FVG / BOS-
/// CHoCH / Entry-SL-TP overlays the way the custom CustomPainter chart
/// does — keeping the two as separate screens means neither compromises
/// the other. This screen has no dependency on AppConfig.useMockData or
/// DataService() at all; it is TradingView's own data end to end, free,
/// with no API key.
class TradingViewChartScreen extends StatefulWidget {
  const TradingViewChartScreen({super.key});

  @override
  State<TradingViewChartScreen> createState() => _TradingViewChartScreenState();
}

class _TradingViewChartScreenState extends State<TradingViewChartScreen> {
  // OANDA's XAUUSD feed is the most widely embedded free "spot gold" data
  // series on TradingView's own charts — matches the "Gold Spot / U.S.
  // Dollar" label the reference screenshot showed inside the widget
  // itself (that label is drawn by TradingView, not this app).
  static const _symbol = 'OANDA:XAUUSD';

  String _interval = '60'; // TradingView's own interval codes — see _timeframeLabel
  InAppWebViewController? _controller;

  static const _timeframes = ['1', '15', '60', '240', 'D', 'W'];

  String _timeframeLabel(String interval) => switch (interval) {
        '1' => '1m',
        '15' => '15m',
        '60' => '1H',
        '240' => '4H',
        'D' => '1D',
        'W' => '1W',
        _ => interval,
      };

  String _buildHtml(String interval) {
    // The standard public TradingView widget embed (no API key, no
    // TradingView account needed) — dark theme to match the rest of this
    // app. Loaded as an inline HTML string (not a bare iframe URL)
    // because the widget's own JS (tv.js) needs a container div id to
    // attach to.
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <style>
    html, body { margin:0; padding:0; height:100%; background:#0f1117; }
    #tv_chart { height:100%; width:100%; }
  </style>
</head>
<body>
  <div id="tv_chart"></div>
  <script src="https://s3.tradingview.com/tv.js"></script>
  <script>
    new TradingView.widget({
      "container_id": "tv_chart",
      "autosize": true,
      "symbol": "$_symbol",
      "interval": "$interval",
      "timezone": "Etc/UTC",
      "theme": "dark",
      "style": "1",
      "locale": "en",
      "toolbar_bg": "#0f1117",
      "enable_publishing": false,
      "hide_top_toolbar": true,
      "hide_legend": false,
      "save_image": false,
      "allow_symbol_change": false
    });
  </script>
</body>
</html>
''';
  }

  void _selectTimeframe(String interval) {
    if (interval == _interval) return;
    setState(() => _interval = interval);
    _controller?.loadData(data: _buildHtml(interval), mimeType: 'text/html', encoding: 'utf8');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TradingView — ${AppConfig.symbol}'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 6,
              children: _timeframes
                  .map((tf) => ChoiceChip(
                        label: Text(_timeframeLabel(tf)),
                        selected: _interval == tf,
                        onSelected: (_) => _selectTimeframe(tf),
                      ))
                  .toList(),
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialData: InAppWebViewInitialData(data: _buildHtml(_interval), mimeType: 'text/html', encoding: 'utf8'),
              onWebViewCreated: (controller) => _controller = controller,
            ),
          ),
        ],
      ),
    );
  }
}
