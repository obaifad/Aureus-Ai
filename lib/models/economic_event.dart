/// RECONSTRUCTED 2026-09-12 (the original file was lost — see chat for
/// context). A single economic-calendar entry (CPI, NFP, FOMC, ...) —
/// consumed by NewsCalendarService/NotifierService.sendNewsAlert. Kept
/// deliberately minimal since the original's exact fields are unknown.
enum NewsImpact { low, medium, high }

class EconomicEvent {
  final String name;
  final String currency;
  final DateTime timeUtc;
  final NewsImpact impact;

  const EconomicEvent({
    required this.name,
    required this.timeUtc,
    this.currency = 'USD',
    this.impact = NewsImpact.high,
  });
}
