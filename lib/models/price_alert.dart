/// RECONSTRUCTED 2026-09-12 (the original file was lost — see chat for
/// context). A user-defined price level to watch — fires once when
/// [livePrice] crosses [targetPrice] in the [triggerAbove] direction,
/// unless [enabled] is false (AlertsScreen's on/off toggle).
class PriceAlert {
  final String id;
  final double targetPrice;
  final bool triggerAbove; // true: fires on a cross ABOVE targetPrice; false: below
  bool triggered;
  bool enabled;

  PriceAlert({
    required this.id,
    required this.targetPrice,
    required this.triggerAbove,
    this.triggered = false,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'target_price': targetPrice,
        'trigger_above': triggerAbove,
        'triggered': triggered,
        'enabled': enabled,
      };

  factory PriceAlert.fromJson(Map<String, dynamic> json) => PriceAlert(
        id: json['id'] as String,
        targetPrice: (json['target_price'] as num).toDouble(),
        triggerAbove: json['trigger_above'] as bool,
        triggered: json['triggered'] as bool? ?? false,
        enabled: json['enabled'] as bool? ?? true,
      );
}
