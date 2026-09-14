import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Central place for every configurable value in Aureus AI.
/// Values are loaded from a local `.env` file (see `.env.example`).
///
/// `.env` must be loaded in EVERY isolate that reads this class — main()
/// for the UI isolate and MonitorTaskHandler.onStart for the Android
/// foreground-service isolate. [_env] never throws if it wasn't (flutter_
/// dotenv's own `env` getter throws NotInitializedError), so a missing load
/// degrades to defaults instead of failing every monitoring cycle.
class AppConfig {
  AppConfig._();

  static String? _env(String key) => dotenv.isInitialized ? dotenv.env[key] : null;

  /// True once `.env` has been loaded in the current isolate.
  static bool get isEnvLoaded => dotenv.isInitialized;

  // ---------------------------------------------------------------------
  // Trading symbol & timeframes
  // ---------------------------------------------------------------------
  static const String symbol = 'XAUUSD';

  /// The EXACT symbol name the MT5 bridge/broker uses — brokers often
  /// suffix or rename gold (e.g. "XAUUSD...", "XAUUSDm", "GOLD#"). This is
  /// what's actually sent to /candles and /stream/ticks; [symbol] above
  /// stays the clean name used everywhere in the UI/notifications/history.
  /// Set MT5_SYMBOL in .env if your broker doesn't use plain "XAUUSD" —
  /// check Market Watch -> right-click a gold entry -> Symbols, or ask the
  /// bridge to list matches (see bridge/mt5_bridge_server.py /symbols).
  static String get brokerSymbol {
    final configured = _env('MT5_SYMBOL')?.trim();
    return (configured != null && configured.isNotEmpty) ? configured : symbol;
  }

  /// Timeframes used by the confluence strategy (in minutes). [tfM1] is a
  /// same-cycle scalping fallback checked only when [tfM5] finds no
  /// trigger (see signal_checker.dart) — not an independent concurrent
  /// stream — so 5M stays the primary execution timeframe throughout.
  static const int tfM1 = 1;
  static const int tfM5 = 5;
  static const int tfM15 = 15;
  static const int tfH1 = 60;
  static const int tfH4 = 240;

  /// Daily — GoldChartScreen's timeframe strip only (2026-09-13); none of
  /// the 3 strategy engines use it, so it's absent from every "which
  /// timeframes get scanned" list elsewhere in this file/codebase on
  /// purpose.
  static const int tfD1 = 1440;

  // ---------------------------------------------------------------------
  // Strategy thresholds
  // ---------------------------------------------------------------------
  /// Distance (in price $) TaEngine.findExecutionTrigger uses to classify
  /// a trigger as Retest vs Reversal — how far price must have closed
  /// beyond a zone in recent 5M candles to count as a broken/retested
  /// level. No longer gates whether a trigger fires at all (2026-09-09):
  /// the HTF-zone proximity requirement was removed, so a confirming
  /// candle now qualifies regardless of distance from the nearest zone.
  static const double proximityThreshold = 15.0;

  /// The "Interest Area" around an HTF zone (2026-09-09, widened to $4.00
  /// on 2026-09-10): both findExecutionTrigger trigger paths (Reversal/
  /// Retest AND Momentum/Breakout) require the current 1M/5M price to be
  /// within this many dollars of the nearest HTF zone to be eligible at
  /// all — 40 pips ($4.00) at this codebase's $0.10/pip XAUUSD convention
  /// (see RiskEngine's "$5.00 / 50 pips" comment). Widened from $2.00/20
  /// pips: live monitoring showed price sitting right at a Key Zone for
  /// long stretches without a confirming candle ever forming inside the
  /// old, tighter buffer — $4.00 gives a genuine reversal/momentum candle
  /// more room to actually qualify once it does form. Distinct from
  /// [proximityThreshold] above, which is unrelated: it only classifies an
  /// already-eligible trigger as Retest vs Reversal, it never gates
  /// whether a trigger fires.
  static const double interestZoneBufferDollars = 4.0;

  /// Extra flex margin (2026-09-10) added ON TOP of
  /// [interestZoneBufferDollars] before a Momentum/Breakout or 15M
  /// Absorption trigger is rejected for being outside the Interest Area —
  /// 10 pips ($1.00): "ليش اذا كانت فوق المجال بـ10 بيب تلغي الصفقة؟" — a
  /// near-miss just past the main buffer shouldn't hard-cancel an
  /// otherwise-valid setup. Distinct from the buffer itself so the two
  /// numbers stay independently tunable (the buffer defines the zone's
  /// real range; this is slack for measurement/rounding noise at its edge).
  static const double interestZoneToleranceDollars = 1.0;

  /// How close two INDEPENDENT [HtfZone] entries must sit to count as a
  /// "Confluence Zone" (2026-09-11 — "التقاء دعم/مقاومة وخط ترند"; widened
  /// same day from $2.00 to $4.00 — "خلي المجال شوية مرونة" — deliberately
  /// reusing [interestZoneBufferDollars]'s own value rather than a new
  /// arbitrary number, so "close enough to be the same level" means the
  /// same distance everywhere in this codebase). See
  /// TaEngine._isConfluenceZone — a Trendline crossing right through a
  /// Support/Resistance, or a 1H zone landing almost exactly on a 4H one,
  /// is a materially stronger level than either alone, which is what earns
  /// it findExecutionTrigger's relaxed Reversal/Retest eligibility (a plain
  /// confirmed Pinbar/Engulfing, no required wick penetration through the
  /// exact price — unlike an ordinary single-source zone, which still needs
  /// genuine Institutional Absorption).
  static const double confluenceZoneToleranceDollars = interestZoneBufferDollars;

  /// Minimum number of touches for a horizontal S/R zone to be valid.
  /// (A temporary debug value of 1 was reverted 2026-09-14 — a single
  /// touch isn't structure and flooded the zone pool with noise.)
  static const int minSrTouches = 2;

  /// Minimum number of swing points required to draw a trendline.
  static const int minTrendlinePivots = 3;

  /// Extra buffer (in $) added beyond the confirmation candle wick
  /// when placing the Stop Loss.
  static const double slBufferDollars = 0.3;

  /// Fixed Risk:Reward ratio enforced on every signal.
  static const double riskRewardRatio = 2.0;

  // NOTE: there is deliberately no minimum Stop Loss floor (removed
  // 2026-09-10 — see RiskEngine.buildTradeSetup): the SL always sits at
  // whatever the structural distance actually is; the user sizes their own
  // position (lot) to the real pip distance instead of the system forcing
  // a fixed-dollar floor onto it.

  /// Rule 2 — Signal Staleness Validation (signal_checker.dart): if the
  /// live price has drifted this far from a just-built setup's Entry
  /// before it's actually sent, the setup is discarded rather than
  /// alerting on a price that's already moved on. Compared against the LIVE
  /// price (the still-forming candle / latest tick), not the closed
  /// confirmation candle Entry is priced from. (A temporary debug value of
  /// $15 was reverted 2026-09-14.)
  static const double maxStalePriceDriftDollars = 1.5;

  /// Rule 2 — Signal Staleness Validation: if the confirmation candle
  /// closed more than this many of its own bars ago, the setup is
  /// discarded as expired.
  static const double maxStaleBars = 3.0;

  /// Market Closed / Stale Data Feed Guard (2026-09-12 — the app kept
  /// firing signals on a weekend/broker holiday because nothing checked
  /// whether the data source was actually live): if the newest 5M candle
  /// SignalChecker fetches is older than this many multiples of the 5M
  /// timeframe itself, MT5 (bridge mode) or TwelveData/Yahoo (standalone
  /// mode) is serving a frozen last-known price rather than a live one —
  /// weekend, broker holiday, or a stalled upstream feed — and the whole
  /// cycle is skipped before any trigger is evaluated, rather than firing
  /// a signal off a market that isn't actually moving.
  static const int staleFeedTimeframeMultiplier = 2;

  /// Rule 3 — Directional Debounce (signal_checker.dart): once a signal
  /// fires, an opposing (BUY vs SELL) signal on another timeframe is
  /// suppressed for this long, so the app never whipsaws the user between
  /// directions within minutes.
  static const Duration directionalDebounceWindow = Duration(minutes: 15);

  /// Rule 4 — High-Probability Confluence Filter (Strict Top-Down
  /// strategy, signal_checker.dart): a setup's 0-100 Confluence Score
  /// (HTF trend alignment + reversal-pattern strength + R:R + organic-vs-
  /// clamped SL) must reach at least this to ever be emitted.
  ///
  /// Lowered from 70 to 50 (2026-09-09): the $5 min-SL guard and hard 1:2
  /// R:R already filter out most low-quality setups upstream of this
  /// score, so a 70 floor on top of that was cutting into legitimate
  /// signal frequency more than it was adding quality. 50 is the floor of
  /// the "🎯 Moderate Setup" badge tier (see TradeSetup.confidenceBadge in
  /// trade_setup.dart / SignalCard) — every setup that reaches the user is
  /// now explicitly labeled Moderate/Standard/High so score-based
  /// confidence stays visible instead of being an invisible pass/fail
  /// cutoff. (The News Freeze and HTF-zone proximity gate that used to
  /// also filter upstream of this score were both removed 2026-09-09.)
  static const int minConfluenceScore = 50;

  /// Rule 4's Confluence Score floor for 1M SCALPING setups only
  /// (2026-09-10, High-Probability Gating): a fast 1M entry has far less
  /// structural confirmation behind it than a 5M reversal by nature, so it
  /// needs a materially higher score to justify firing at all — win-rate
  /// over frequency for the scalping layer specifically.
  ///
  /// UNUSED as of 2026-09-14 ("completely disable Scalping strategies") —
  /// 1M/5M were removed from every strategy's execution-timeframe list
  /// entirely, so nothing ever reaches the branch in SignalChecker that
  /// used to read this. Left defined rather than deleted purely as a
  /// historical record of the old threshold.
  static const int minConfluenceScoreScalping = 70;

  // ---------------------------------------------------------------------
  // ICT / Smart-Money-Concepts strategy (ict_engine.dart) — an INDEPENDENT
  // strategy layer added 2026-09-12 alongside the Strict Top-Down Dual-Mode
  // strategy above: Break of Structure / Change of Character bias on 4H+1H,
  // Liquidity Sweeps, Premium/Discount, Order Blocks, Fair Value Gaps,
  // Breaker Blocks, and with-trend Trendline continuation. It keeps its own
  // debounce/cooldown state in SignalChecker and can fire its own setup in
  // the SAME cycle the legacy strategy already did — the two run
  // side-by-side, neither blocks the other.
  // ---------------------------------------------------------------------

  /// London session, UTC hours [start, end) — one of the three "high
  /// liquidity" windows a trade is expected to fall within ("جلسات
  /// السيولة العالية مثل جلسة لندن او نيويورك"), unless the signal scores
  /// at least [ictSessionOverrideScore].
  static const int londonSessionStartUtc = 7;
  static const int londonSessionEndUtc = 16;

  /// New York session, UTC hours [start, end).
  static const int newYorkSessionStartUtc = 12;
  static const int newYorkSessionEndUtc = 21;

  /// Asian (Tokyo) session, UTC hours [start, end) — added 2026-09-12
  /// ("لو تحققت الشروط بالجلسة الاسيوية مافي مشكلة لدخول صفقة"): a setup
  /// that genuinely clears every other gate (confirmation candle, HTF bias,
  /// Confluence Score, ...) is accepted here too at the SAME standard
  /// threshold as London/New York — it no longer needs
  /// [ictSessionOverrideScore] just for landing in this window.
  static const int asianSessionStartUtc = 0;
  static const int asianSessionEndUtc = 9;

  /// A setup outside all three sessions above (i.e. the low-liquidity gap
  /// roughly between the New York close and the Tokyo open) is still
  /// allowed through when its Confluence Score reaches this — "الا اذا
  /// كانت الاشارة قوية جدا".
  static const int ictSessionOverrideScore = 85;

  /// How many recent candles an Order Block / Fair Value Gap / Breaker
  /// Block is still eligible from before it's considered too old/stale to
  /// trade against.
  static const int ictZoneMaxAgeCandles = 40;

  /// How many recent candles [IctEngine._sweptLiquidityRecently] looks back
  /// over for a swing high/low that got wicked through and closed back —
  /// i.e. how "recent" a liquidity sweep has to be to still count.
  static const int ictLiquiditySweepLookback = 20;

  /// Number of 1H candles used to build the Premium/Discount dealing range
  /// (its midpoint is the equilibrium — buys only below it, sells only
  /// above it).
  static const int ictEquilibriumWindow = 50;

  /// Confluence Score floor for the ICT Liquidity-Sweep Reversal path
  /// specifically — it trades AGAINST the immediate structure by design, so
  /// (mirroring [minConfluenceScoreScalping]'s precedent for 1M scalps) it
  /// needs a materially higher score than the other, with-trend ICT paths,
  /// which use the standard [minConfluenceScore] floor.
  static const int minConfluenceScoreIctReversal = 70;

  // ---------------------------------------------------------------------
  // Impulse-Correction-Impulse strategy (impulse_correction_engine.dart) —
  // a third INDEPENDENT strategy layer added 2026-09-13: a strong impulsive
  // leg (Impulse 1), a corrective pullback that retraces into the 50%-
  // 61.8% Fibonacci zone (or touches a broken S/R/FVG/Order Block reused
  // from IctEngine), then a fresh entry the moment the correction shows
  // genuine signs of ending, back in Impulse 1's own direction. Unlike ICT,
  // this strategy has NO exemption from HTF alignment — every setup must
  // agree with BOTH the 1H and 4H bias.
  // ---------------------------------------------------------------------

  /// Minimum body-to-range ratio for a candle to count toward Impulse 1 —
  /// reuses the exact same "decisive candle" threshold TaEngine.
  /// classifyMomentum already uses, so "strong expansion" means the same
  /// thing everywhere in this codebase.
  static const double iciMinImpulseBodyRatio = 0.65;

  /// Impulse 1 must be at least this many CONSECUTIVE same-direction
  /// candles (each clearing [iciMinImpulseBodyRatio]) to count as a
  /// genuine expansion leg, not just one decisive bar.
  static const int iciMinConsecutiveImpulseCandles = 2;

  /// The correction phase's retracement into Impulse 1's own range must
  /// fall inside [iciFibRetracementMin, iciFibRetracementMax] (the classic
  /// 50%-61.8% "golden zone") to count as a valid pullback — OR touch a
  /// broken S/R/FVG/Order Block instead (see ImpulseCorrectionEngine).
  static const double iciFibRetracementMin = 0.5;
  static const double iciFibRetracementMax = 0.618;

  /// Correction-phase candles (excluding the final confirmation candle)
  /// must average a body-to-range ratio below this to count as genuine
  /// "low volatility / exhaustion" — well under [iciMinImpulseBodyRatio],
  /// since a correction that hits just as hard as the impulse isn't really
  /// pausing at all.
  static const double iciMaxCorrectionBodyRatio = 0.5;

  /// Correction Termination Trigger #2 (Rejection Wick): the confirmation
  /// candle's rejecting wick must be at least this fraction of its own
  /// total high-low range.
  static const double iciMinRejectionWickRatio = 0.5;

  /// Stop-Loss safety floor (2026-09-13, explicit request) — ONLY this
  /// strategy has a minimum-SL floor; the legacy and ICT strategies
  /// deliberately don't (see RiskEngine's own "no minimum Stop Loss floor"
  /// note). If the organic structural distance (past the correction's own
  /// high/low) is tighter than this, the SL is widened to exactly this
  /// many dollars and Take Profit is repriced to keep the 1:2 ratio.
  static const double iciMinStopLossDollars = 1.50;

  /// How many recent candles Impulse 1 is still eligible from before it's
  /// considered too old to trade a correction/continuation against.
  static const int iciMaxImpulseAgeCandles = 40;

  /// Impulse-Correction-Impulse strategy tier's own Confluence Score floor
  /// — the standard [minConfluenceScore], since (unlike ICT's Liquidity
  /// Sweep Reversal) every ICI setup is already a strict with-trend
  /// continuation with mandatory HTF consensus, not a higher-risk
  /// countertrend play.
  static const int minConfluenceScoreIci = minConfluenceScore;

  // ---------------------------------------------------------------------
  // Minimum Take-Profit Distance Filter (2026-09-14, explicit request) —
  // applies identically to EVERY strategy tier (Top-Down/ICT/ICI) and
  // every timeframe/pattern path within them (Reversal, Momentum/
  // Breakout, Absorption, ...): a setup whose TP sits too close to Entry
  // isn't worth taking on a real account regardless of how clean the
  // structural pattern behind it looks — spread, slippage, and commission
  // eat a disproportionate share of a small move. Checked once, right
  // after RiskEngine prices each candidate setup, before any
  // strategy-specific pattern rejection runs.
  // ---------------------------------------------------------------------
  static const double minTakeProfitPips = 60.0;

  // ---------------------------------------------------------------------
  // Minimum Stop-Loss Distance Filter (2026-09-14, explicit request, part
  // of "completely disable Scalping strategies") — a SL any tighter than
  // this sits inside ordinary market noise for a near-24h, multi-hundred-
  // dollar instrument like gold: it gets stopped out by a random wick
  // rather than a genuine invalidation of the setup, which is exactly the
  // "premature exit" scalping-style micro-setups are prone to. The
  // request specified "at least 20-30 pips" as an acceptable range; 20
  // pips (the more permissive end of that range) is enforced as the hard
  // floor. Distinct from [minTakeProfitPips] above (which gates the
  // reward side) and from [iciMinStopLossDollars] (the ICI-only $1.50
  // floor that widens a tight SL up to the actual minimum rather than
  // rejecting the setup outright) — this ALWAYS rejects, for every
  // strategy, same as the TP filter.
  // ---------------------------------------------------------------------
  static const double minStopLossPips = 20.0;

  /// How often the foreground-service/Timer loop wakes up and calls
  /// SignalChecker.check(). Was briefly tried at 15 seconds, which drove
  /// both TwelveData AND Yahoo Finance into rate-limiting within minutes
  /// (see StandaloneDataService's cooldown handling) — 30 seconds is the
  /// balance point: still catches a just-closed 5M candle within half a
  /// minute, while roughly halving request volume vs. 15s.
  ///
  /// SignalChecker's own per-timeframe candle cache (see
  /// signal_checker.dart) does the heavy lifting here: only the 5M pass
  /// re-fetches on every tick, while 15M/1H/4H are served from cache
  /// between their own natural candle closes. Steady state is ~2 fresh 5M
  /// requests/minute purely for TwelveData's free tier: comfortably inside
  /// its 8 req/min cap, but still ~2,880 requests/day against an 800/day
  /// free quota — i.e. the daily quota is exhausted after roughly 6-7
  /// hours of continuous monitoring, after which Yahoo Finance (and its
  /// own 2-minute rate-limit cooldown) carries the rest of the day. If
  /// both providers are cooling down at once, getCandles() returns an
  /// empty list rather than throwing, so the loop keeps ticking quietly
  /// instead of surfacing a raw exception every cycle. A 5M candle also
  /// cannot close more than once every 5 minutes regardless of poll
  /// frequency — polling faster than that improves how quickly a
  /// just-closed candle is *noticed*, not how often the underlying market
  /// itself produces a new confirmed signal.
  ///
  /// 1M scalping (see [tfM1]) is only fetched — fresh, every cycle, at the
  /// same cadence as 5M — on a cycle where 5M itself found no trigger, so
  /// it bounds rather than doubles the added request volume described
  /// above.
  static const Duration pollInterval = Duration(seconds: 30);

  // ---------------------------------------------------------------------
  // Data source: Standalone (direct web API, default) or Bridge (local MT5)
  // ---------------------------------------------------------------------
  /// Optional free API key from https://twelvedata.com (free tier: 800
  /// requests/day) used by StandaloneDataService for proper XAU/USD OHLC
  /// candles. Leave empty and standalone mode automatically falls back to
  /// Yahoo Finance's public chart endpoint, which needs no signup at all.
  static String get twelveDataApiKey => _env('TWELVE_DATA_API_KEY') ?? '';

  /// Yahoo Finance's GC=F is COMEX gold FUTURES, typically $10-40 away from
  /// spot XAUUSD. Signals and SL/TP outcomes computed from it would not
  /// match the broker's chart, so by default the engine pauses (no new
  /// signals, no outcome resolution) while Yahoo is the only live feed.
  /// Set ALLOW_FUTURES_FALLBACK_SIGNALS=true in .env to override.
  static bool get allowFuturesFallbackSignals =>
      (_env('ALLOW_FUTURES_FALLBACK_SIGNALS') ?? 'false').toLowerCase().trim() == 'true';

  /// Flutter cannot talk to the
  /// MetaTrader5 terminal directly (it's a native Windows COM/DLL API),
  /// so bridge mode instead talks to a small local bridge service (see
  /// /bridge in the README) that wraps the official `MetaTrader5` Python
  /// package behind a simple REST API.
  ///
  /// Platform-aware default (2026-09-13 — "Connection Refused" fix):
  /// an explicit BRIDGE_BASE_URL in .env always wins outright, since it's
  /// the only way this can ever work from a REAL physical Android device
  /// — `10.0.2.2` is a magic alias the Android EMULATOR maps to the host
  /// machine's localhost; it does not exist on real hardware, which
  /// instead needs the PC's actual LAN IP (e.g. http://192.168.1.23:8000)
  /// set explicitly here. Without an override, Android defaults to
  /// `10.0.2.2` (helps emulator testing out of the box) and every other
  /// platform (Windows/desktop) keeps `127.0.0.1`.
  static String get bridgeBaseUrl {
    final configured = _env('BRIDGE_BASE_URL')?.trim();
    if (configured != null && configured.isNotEmpty) {
      return configured.endsWith('/') ? configured.substring(0, configured.length - 1) : configured;
    }
    if (!kIsWeb && Platform.isAndroid) return 'http://10.0.2.2:8000';
    return 'http://127.0.0.1:8000';
  }

  /// Shared secret sent as `X-API-Key` to the bridge server. Must match
  /// BRIDGE_API_KEY in bridge/.env — see bridge/.env.example.
  static String get bridgeApiKey => _env('BRIDGE_API_KEY') ?? '';

  // ---------------------------------------------------------------------
  // AI Engine (trade thesis commentary)
  // ---------------------------------------------------------------------
  /// AiEngine prefers the bridge's /ai-commentary proxy (key stays on the
  /// PC). This client-side key is only a fallback — anything in `.env` is
  /// bundled inside the APK as an asset and can be extracted from it.
  static String get anthropicApiKey => _env('ANTHROPIC_API_KEY') ?? '';
  static String get anthropicModel => _env('ANTHROPIC_MODEL') ?? 'claude-sonnet-4-6';

  // ---------------------------------------------------------------------
  // Alert delivery (Telegram)
  // ---------------------------------------------------------------------
  static String get telegramBotToken => _env('TELEGRAM_BOT_TOKEN') ?? '';
  static String get telegramChatId => _env('TELEGRAM_CHAT_ID') ?? '';

  /// If true, no real network calls are made to MT5/AI/Telegram — the app
  /// runs entirely on simulated candles. Useful for demoing the UI/logic
  /// without a broker connection.
  static bool get useMockData => (_env('USE_MOCK_DATA') ?? 'true').toLowerCase().trim() == 'true';

  /// Standalone Mode (2026-09-14): skips the MT5 bridge tier entirely and
  /// goes straight to TwelveData -> Yahoo — for a device that will never be
  /// able to reach the bridge (different network than the PC, e.g. a second
  /// phone on mobile data used to compare against a bridge-connected one).
  /// Without this, every single poll cycle on such a device would burn a
  /// full ~10s HTTP timeout trying (and always failing) to reach the
  /// bridge before failing over — this flag skips straight past that,
  /// and also skips the tick WebSocket and the bridge health poll/badge,
  /// none of which could ever succeed anyway.
  static bool get disableMt5Bridge => (_env('DISABLE_MT5_BRIDGE') ?? 'false').toLowerCase().trim() == 'true';
}
