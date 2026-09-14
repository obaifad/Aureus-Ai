/// A single OHLC candlestick for a given timeframe.
class Candle {
  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  const Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  bool get isBullish => close >= open;
  bool get isBearish => close < open;

  double get bodySize => (close - open).abs();
  double get upperWick => high - (isBullish ? close : open);
  double get lowerWick => (isBullish ? open : close) - low;
  double get range => high - low;

  factory Candle.fromJson(Map<String, dynamic> json) {
    return Candle(
      time: DateTime.fromMillisecondsSinceEpoch(
        (json['time'] as num).toInt() * 1000,
        isUtc: true,
      ),
      open: (json['open'] as num).toDouble(),
      high: (json['high'] as num).toDouble(),
      low: (json['low'] as num).toDouble(),
      close: (json['close'] as num).toDouble(),
      volume: (json['tick_volume'] ?? json['volume'] ?? 0 as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'time': time.millisecondsSinceEpoch ~/ 1000,
        'open': open,
        'high': high,
        'low': low,
        'close': close,
        'volume': volume,
      };
}
