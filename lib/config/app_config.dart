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
  /// The "Interest Area" around an HTF zone (2026-09-09, widened to $4.00
  /// on 2026-09-10) — effectively "how wide the zone itself really is".
  /// NO LONGER a proximity eligibility gate as of 2026-09-14 (explicit
  /// request — the app sat idle for hours anytime price drifted just
  /// outside this buffer, e.g. $5-10 away, even though a fresh 15M candle
  /// kept forming there). Still used for: TaEngine._isConfluenceZone (via
  /// [confluenceZoneToleranceDollars]) to decide when two independent zones
  /// are "the same level"; the HTF Retest Protocol's "closed DECISIVELY
  /// through the zone" test (one full zone width beyond the level, so a
  /// candle closing on the zone's far edge isn't mistaken for a break); and
  /// purely as an informational "in buffer vs Order Flow penetration" label
  /// on a fired trigger.
  static const double interestZoneBufferDollars = 4.0;

  /// Extra flex margin (2026-09-10), now purely informational alongside
  /// [interestZoneBufferDollars] above (2026-09-14 — neither is an
  /// eligibility gate anymore) — kept for the "in buffer" distance labels
  /// and [confluenceZoneToleranceDollars]. Originally: 10 pips ($1.00):
  /// "ليش اذا كانت فوق المجال بـ10 بيب تلغي الصفقة؟" — a
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
  /// is a materially stronger level than either alone. It used to earn such
  /// a zone a relaxed Reversal/Retest eligibility (a plain confirmed
  /// Pinbar/Engulfing, no required wick penetration); since 2026-09-18 the
  /// HTF Retest Protocol gates every retest on the same strict sequence
  /// regardless, so confluence is now reported as a quality tag on the
  /// fired trigger's zone label rather than relaxing any requirement.
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
  ///
  /// Lowered 2.0 -> 1.8 (2026-09-24, explicit request) after a live review
  /// of one full session: five setups fired, THREE reached exactly 1R and
  /// then retraced the whole way back, and not one reached 2R. Pulling the
  /// target in by 0.2R asks the market for materially less follow-through
  /// on every tier at once (every engine prices its TP off this constant),
  /// which is the point — the day's losses came from targets the move
  /// never had the legs to reach, not from bad entries.
  static const double riskRewardRatio = 1.8;

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
  // HTF Retest Protocol (2026-09-18, explicit request) — the Strict
  // Top-Down strategy's Break & Retest path, rebuilt as the full
  // Smart-Money sequence instead of "a Pinbar/Engulfing at a zone price
  // happened to have closed far from recently":
  //   HTF Zone -> HTF Trend/Bias -> price back INTO the zone -> Liquidity
  //   Sweep -> Market Structure Shift -> Entry, with the Stop Loss behind
  //   the swept swing (not the zone boundary) and the Take Profit at the
  //   next liquidity/HTF target (not a blind 1:2 multiple).
  // See TaEngine.findExecutionTrigger's Path A for the gate-by-gate
  // implementation. Only this floor needed a new number — every other gate
  // is structural and reuses constants already defined above.
  // ---------------------------------------------------------------------

  /// Minimum Risk:Reward the liquidity-target Take Profit must pay for an
  /// HTF Retest setup to be taken at all. Because that TP sits at the next
  /// level price is genuinely expected to REACT to (rather than being
  /// stretched out to a fixed [riskRewardRatio]), a target that lands too
  /// close to Entry is a real signal that this move has no room — the
  /// setup is rejected rather than re-priced to a TP nothing supports.
  /// Deliberately below [riskRewardRatio]: a 1:2 floor here would throw
  /// away otherwise-clean retests purely for having honest, nearby targets.
  static const double htfRetestMinRiskReward = 1.5;

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

  /// How many recent candles [TaEngine.findLiquiditySweep] looks back over
  /// for a swing high/low that got wicked through and closed back — i.e.
  /// how "recent" a liquidity sweep has to be to still count. Shared
  /// (2026-09-18) by ICT's Liquidity-Sweep Reversal path and the Top-Down
  /// HTF Retest Protocol, so "a recent sweep" means the same thing in both.
  static const int liquiditySweepLookback = 20;

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

  /// Dynamic ATR-based Stop Loss (2026-09-24, explicit request — replaced
  /// the fixed $1.50 `iciMinStopLossDollars` floor this strategy used from
  /// 2026-09-13). ONLY this strategy re-prices the Stop Loss RiskEngine
  /// hands it; the legacy and ICT tiers stay floor-free (see RiskEngine's
  /// own "no minimum Stop Loss floor" note).
  ///
  ///   finalSlPips = max(structure, [iciSlAtrMultiplier] x ATR(14),
  ///                     [iciMinStopLossPips])
  ///
  /// A fixed dollar floor is wrong in both directions — far too tight when
  /// gold is ranging $8 a candle, needlessly wide when it is quiet — so
  /// the middle term scales the invalidation distance with live volatility
  /// on the execution timeframe. The last term is an absolute hard floor in
  /// pips: below it XAUUSD's own spread and tick noise take the stop out
  /// before the setup has had any chance to be wrong. Structure still wins
  /// whenever it is widest, so this can only ever WIDEN a stop.
  /// See SignalChecker._evaluateIciTrigger for the implementation, which
  /// also re-prices Take Profit off the final risk so [riskRewardRatio]
  /// still holds.
  static const double iciSlAtrMultiplier = 1.5;
  static const double iciMinStopLossPips = 30.0;

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
  // applies identically to EVERY strategy tier (Top-Down/ICT/ICI/ORB/Breakout) and
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
  // reward side) and from the ICI tier's own dynamic ATR stop (see
  // [iciSlAtrMultiplier] — that one WIDENS a tight SL up to a volatility-
  // scaled distance rather than rejecting the setup outright) — this
  // ALWAYS rejects, for every strategy, same as the TP filter.
  // ---------------------------------------------------------------------
  static const double minStopLossPips = 20.0;

  // ---------------------------------------------------------------------
  // Maximum Stop-Loss Distance Filter (2026-09-17, explicit request;
  // widened 120 -> 200 on 2026-09-18, explicit request) — the mirror of
  // [minStopLossPips]: a structural SL wider than this means the
  // invalidation level is simply too far away to be worth trading, so the
  // setup is filtered out and no trade is opened. Enforced for EVERY
  // strategy tier (Top-Down/ICT/ICI/ORB/Breakout), right next to the minimum-distance
  // check. Note the HTF Retest Protocol's Take Profit is no longer a blind
  // 1:2 multiple of this (see AppConfig.htfRetestMinRiskReward) — it prices
  // TP at the next liquidity/HTF target instead, so a wider SL there no
  // longer implies a proportionally distant TP the way it used to.
  // ---------------------------------------------------------------------
  static const double maxStopLossPips = 200.0;

  // ---------------------------------------------------------------------
  // Absorption Strength Filter (2026-09-17, explicit request: skip the
  // entry when the Absorption pattern fails or shows weakness). A raw
  // "bullish candle after a bearish one" is only a genuine Institutional
  // Absorption when the absorbing candle actually takes the prior candle
  // out and closes strong. Three checks, all required (see
  // TaEngine.classifyStrongAbsorption) — used as a shared PATTERN
  // classifier by the HTF Retest Protocol's confirmation check and
  // ImpulseCorrectionEngine; the standalone "15M Higher Low / Lower High
  // Absorption" strategy that originally motivated these thresholds was
  // retired 2026-09-18 (explicit request).
  //   1. Body dominance — the absorbing candle's own body must be at
  //      least this multiple of the absorbed candle's body; a smaller
  //      body absorbed nothing.
  //   2. Body ratio — the absorbing candle must be mostly body, not a
  //      wide indecisive range with a small body.
  //   3. Opposing wick — a large wick against the absorption direction
  //      is the pattern FAILING in real time (price got pushed straight
  //      back), so it is rejected.
  // ---------------------------------------------------------------------
  static const double absorptionMinBodyDominance = 1.0;
  static const double absorptionMinBodyRatio = 0.5;
  static const double absorptionMaxOpposingWickRatio = 0.35;

  // ---------------------------------------------------------------------
  // Opening Range Breakout strategy (orb_engine.dart, 2026-09-18) — a
  // fourth INDEPENDENT strategy layer, deliberately isolated from the
  // Strict Top-Down/ICT/ICI logic above: no HTF zone, structure bias, or
  // candlestick pattern involved at all. The Opening Range is the high/low
  // of the first [orbRangeMinutes] of a session (reusing [londonSessionStartUtc]
  // / [newYorkSessionStartUtc] above as the session anchors, so "the London
  // session" means the exact same UTC hour everywhere in this codebase);
  // a CLOSED 5M candle (never a wick) beyond that range is the breakout;
  // a mandatory retest of the broken boundary (price trading back to it and
  // closing beyond it again) is required before the entry actually fires
  // (2026-09-18, explicit request — the old immediate no-retest entry mode
  // was removed). Off by default: unlike every other tier, ORB needs its
  // own 5M candle
  // fetch (SignalChecker only fetches 4H/1H/15M otherwise, per the
  // "completely disable Scalping strategies" decision above) — enabling it
  // adds real request volume against the same TwelveData/Yahoo quota that
  // decision was protecting, so it's opt-in rather than on by default.
  // ---------------------------------------------------------------------

  /// Master toggle — SignalChecker never fetches 5M candles or evaluates
  /// ORBEngine at all while this is false.
  static bool get useOrb => (_env('USE_ORB') ?? 'false').toLowerCase().trim() == 'true';

  /// Which sessions ORBEngine watches. Both default to true (matching the
  /// request's "configurable for London and New York") — set either to
  /// false in .env to trade only the other.
  static bool get orbLondonEnabled => (_env('ORB_LONDON_ENABLED') ?? 'true').toLowerCase().trim() == 'true';
  static bool get orbNewYorkEnabled => (_env('ORB_NEWYORK_ENABLED') ?? 'true').toLowerCase().trim() == 'true';

  /// Stop Loss / Take Profit sizing for ORB setups specifically ("Allow
  /// dynamic/configurable SL and TP settings", explicit request). Dynamic
  /// by default: SL sits behind the OPPOSITE side of the Opening Range
  /// (the breakout thesis is only proven wrong once price has retraced the
  /// entire range) plus [slBufferDollars], and TP holds the same
  /// [riskRewardRatio] every other tier uses — structural, like the rest of
  /// this codebase's risk sizing, rather than an arbitrary fixed distance.
  /// Setting either override here in .env switches that ONE side to a
  /// fixed pip distance from Entry instead (0 — the default — means
  /// "use the dynamic value").
  static double get orbStopLossPipsOverride => double.tryParse(_env('ORB_STOP_LOSS_PIPS') ?? '') ?? 0;
  static double get orbTakeProfitPipsOverride => double.tryParse(_env('ORB_TAKE_PROFIT_PIPS') ?? '') ?? 0;

  /// ORB's own Confluence Score floor — the standard [minConfluenceScore],
  /// since a confirmed-retest ORB entry is a comparably strong signal to a
  /// with-trend HTF Retest (see OrbEngine's confluence scoring in
  /// SignalChecker._evaluateOrbTrigger).
  static const int minConfluenceScoreOrb = minConfluenceScore;

  /// How long the Opening Range window is, in minutes — narrowed 30 -> 15
  /// (2026-09-24, explicit request: "لorb نزلت لشمعة الربع ساعة بدال النص
  /// ساعة مع نفس الشروط"). EVERY other ORB condition is unchanged: still
  /// closed 5M candles only, still a CLOSE (never a wick) beyond the range
  /// to break it, still a mandatory retest of the broken boundary, still
  /// one trade per session per day.
  ///
  /// What this actually changes: a 15-minute range is narrower than a
  /// 30-minute one, so (a) the breakout fires earlier and more often, and
  /// (b) because ORB's default Stop Loss sits behind the range's OPPOSITE
  /// side, the risk distance on each setup shrinks roughly in proportion —
  /// which directly addresses the 130-153 pip ORB stops seen in the
  /// reviewed session. Must stay a multiple of 5 (the candles it's built
  /// from); OrbEngine.computeRange derives its required candle count from
  /// this value rather than hard-coding one.
  static const int orbRangeMinutes = 15;

  /// How long a formed Opening Range stays TRADEABLE, in hours, measured
  /// from the moment the range window closes (2026-09-24, explicit
  /// request: "اي حطلو حد ساعتين"). Past this deadline the range is dead
  /// for the day: OrbEngine.findTrigger stops looking at candles beyond it
  /// and returns null, so no entry can fire off it any more.
  ///
  /// Why it was needed: findTrigger used to scan EVERY candle after the
  /// range with no time bound at all, which in the reviewed session
  /// produced a New York ORB BUY at 18:26 UTC — more than six hours after
  /// that range closed at 12:15. An opening range describes the first
  /// hour or two of a session's participation; a "breakout" of it six
  /// hours later is just an unrelated level break wearing the strategy's
  /// name, and that trade was one of the day's two full losses.
  ///
  /// Applied to the CANDLES, not merely to the clock, so a scan that runs
  /// late (app asleep, Doze, restart) still can't reach back and fire off
  /// a breakout that happened after the deadline.
  static const int orbMaxHoursAfterRange = 2;

  /// One Active Trade Limit (2026-09-17): while ANY trade is open, no engine
  /// is evaluated at all. On by default. Turning it off (2026-09-25) lets
  /// every engine keep scanning and fire while another position is open, so
  /// positions can overlap across (and within) modules. It exists mainly so
  /// the backtest can MEASURE what the limit costs; concurrent positions
  /// stack real exposure (each is sized on its own), so it should not be
  /// switched off casually on a live account.
  static bool get oneActiveTradeLimit => _envBool('ONE_ACTIVE_TRADE_LIMIT', true);

  // ---------------------------------------------------------------------
  // Ranging Market Module — Zone Bounce Protocol (zone_bounce_engine.dart,
  // 2026-09-25, explicit request) — a SIXTH independent strategy tier.
  //
  // It fills a gap diagnosed live: the Strict Top-Down HTF Retest Protocol
  // is a BREAK-and-retest strategy (its gate 3 demands a close a full
  // [interestZoneBufferDollars] THROUGH the level, its confirmation gate
  // explicitly rejects a Pinbar), so a clean rejection off a level that
  // HOLDS can never produce a trade there. On 2026-09-25 that showed up as
  // 39 Key Zones, a 15M Support $1.66 from price, and not one trigger from
  // any tier all day.
  //
  // Rather than loosen those gates — they are the strict path's whole
  // point — this is a separate engine with its own flag, SetupType and
  // score, exactly like ORB. It only ever runs in the market state the
  // trend engines are NOT built for: no clear HTF bias.
  // ---------------------------------------------------------------------

  /// Master toggle. Off by default, like every other added tier: turning it
  /// on genuinely changes which markets the app trades in (ranging ones),
  /// so it should be a deliberate choice rather than something inherited.
  static bool get enableRangingBounceMode =>
      (_env('ENABLE_RANGING_BOUNCE') ?? 'false').toLowerCase().trim() == 'true';

  /// How close the rejection candle's wick must come to a level to count as
  /// having TOUCHED it. Deliberately much tighter than
  /// [interestZoneBufferDollars] (the Top-Down "near a zone" buffer): this
  /// is a rejection OFF a specific price, not a trade taken in a zone's
  /// general neighbourhood.
  static double get zoneBounceTouchDollars => _envDouble('ZONE_BOUNCE_TOUCH_DOLLARS', 1.0);

  /// Minimum rejection-wick share of the candle's total range for the
  /// third, looser rejection shape (the first two — Pinbar and Engulfing —
  /// reuse TaEngine.classifyPattern's definitions unchanged). A strict
  /// Pinbar additionally demands a small OPPOSITE wick, which rules out
  /// perfectly good rejections that happen to close mid-range; this accepts
  /// those, while still requiring the close to finish in the trade's favour
  /// within the candle's own range.
  static double get zoneBounceMinWickRatio => _envDouble('ZONE_BOUNCE_MIN_WICK_RATIO', 0.5);

  /// How many candles back the engine checks for a decisive close THROUGH
  /// the level before accepting a bounce off it. A level broken within this
  /// window is a broken level being retested — the Top-Down protocol's
  /// territory, with its own sweep/structure-shift gates — not a range
  /// boundary that is holding.
  static int get zoneBounceBreakLookback => _envInt('ZONE_BOUNCE_BREAK_LOOKBACK', 10);

  /// Stop Loss buffer BEYOND the rejection wick's extreme, as a multiple of
  /// ATR(14). The larger of this and [slBufferDollars] wins, so the stop
  /// widens with volatility instead of sitting at a constant distance that
  /// is too tight on a busy day.
  static double get zoneBounceSlAtrMultiplier => _envDouble('ZONE_BOUNCE_SL_ATR', 0.5);

  /// Adaptive Target rule (2026-09-25): the range's opposing boundary only
  /// clips Take Profit when it lies at least this many R from Entry. A
  /// nearer boundary is ignored and Take Profit stays at exactly
  /// [riskRewardRatio]. See ZoneBounceEngine.takeProfitFor.
  static double get zoneBounceMinBoundaryR => _envDouble('ZONE_BOUNCE_MIN_BOUNDARY_R', 1.0);

  /// Take Profit can be clipped to the range's opposing boundary (when that
  /// is at least [zoneBounceMinBoundaryR] away), so the realised R:R can
  /// come in BELOW [riskRewardRatio]. Below this floor the setup is
  /// rejected outright rather than taken for a poor payoff. Note it sits
  /// ABOVE [zoneBounceMinBoundaryR], so a boundary between the two clips a
  /// setup into a rejection — a deliberate, separately tunable trade-off.
  static double get zoneBounceMinRiskReward => _envDouble('ZONE_BOUNCE_MIN_RR', 1.2);

  /// How many of the NEAREST zones are evaluated per cycle (2026-09-25
  /// Multi-Zone Evaluation fix). [TaEngine.findNearestZone] returns exactly
  /// one zone and applies a timeframe handicap when ranking, so a genuinely
  /// closer lower-timeframe level can lose to a further higher-timeframe
  /// one and never be looked at — observed live with a 15M Support $1.66
  /// from price losing to a 1H Support $2.33 away. This tier evaluates the
  /// top N by TRUE distance instead (see [TaEngine.findNearestZones]).
  static int get zoneBounceEvaluatedZoneCount => _envInt('ZONE_BOUNCE_ZONE_COUNT', 3);

  /// Zone Bounce's own Confluence Score floor — the standard
  /// [minConfluenceScore].
  static const int minConfluenceScoreZoneBounce = minConfluenceScore;

  // ---------------------------------------------------------------------
  // DXY Correlation Filter (2026-09-18, explicit request) — a lightweight,
  // NON-BLOCKING-BY-FAILURE confluence/confirmation check, never an
  // independent trigger: Gold and the US Dollar Index trade near-
  // permanently inverse, so a BUY XAUUSD signal firing while DXY is itself
  // in a clear bullish trend (and vice versa for a SELL against a weak
  // DXY) is fighting its own strongest cross-asset headwind. Applied
  // centrally in SignalChecker.check() to every fired setup regardless of
  // which of the five strategy tiers produced it — see
  // DxyFilterService.confirms. Any failure (feed unreachable, symbol not
  // found, not enough candles, disabled) resolves to ALLOW, never to
  // block, per the explicit "gracefully bypass... without stopping" spec.
  // ---------------------------------------------------------------------

  static bool get useDxyFilter => (_env('USE_DXY_FILTER') ?? 'false').toLowerCase().trim() == 'true';

  /// Manual override for the DXY ticker — set this when auto-detection
  /// (DxyFilterService querying the MT5 bridge's /symbols endpoint for
  /// "DXY"/"USDX"/"DOLLAR") picks the wrong Market Watch entry, or when
  /// running in Standalone Mode where there's no Market Watch to query at
  /// all. Empty (the default) means "auto-detect, falling back to Yahoo
  /// Finance's public 'DX-Y.NYB' ticker when the bridge is unavailable or
  /// has no match".
  static String get dxySymbolName => _env('DXY_SYMBOL_NAME') ?? '';

  /// Timeframe and lookback DxyFilterService reads DXY's own trend from —
  /// "lower timeframes" per the request, matching XAUUSD's own 15M
  /// execution timeframe so "DXY's current trend" and "the trend this
  /// system trades gold against" are read on the same clock. Mirrors
  /// SignalChecker._hourlyBias's own net-movement-over-N-candles reading
  /// (see DxyFilterService._trend), just parameterized here since DXY has
  /// no equivalent of that private method to reuse directly.
  static const int dxyTrendTimeframeMinutes = tfM15;
  static const int dxyTrendLookbackCandles = 20;

  /// How often two calls within the same SignalChecker cycle window reuse
  /// the same DXY read instead of re-fetching — mirrors SignalChecker's
  /// own 15M cache TTL, since they're read at the same cadence.
  static const Duration dxyCacheTtl = Duration(seconds: 55);

  // ---------------------------------------------------------------------
  // Breakout/Momentum strategy (breakout_momentum_engine.dart, 2026-09-18;
  // REBUILT 2026-09-22 to an explicit 11-point specification) — a fifth
  // INDEPENDENT strategy layer. Decision chain, in the spec's own order:
  //
  //   Important Level -> Breakout Candle -> Momentum -> HTF -> Session
  //   -> Retest -> DXY -> News -> Entry
  //
  // ...with Failed-Breakout Protection and a "don't chase" maximum entry
  // distance layered in (see BreakoutMomentumEngine's own doc comment for
  // the engine-side half, and SignalChecker._evaluateBreakoutTrigger for
  // the session/HTF/DXY/news half).
  //
  // EVERY threshold below is a .env INPUT rather than a hardcoded constant
  // ("هذه أرقام ابتدائية للاختبار وليست قيم مثالية ثابتة") so the whole
  // strategy can be re-tuned and back-tested without rebuilding the app.
  // The defaults are the spec's own starting numbers.
  //
  // Off by default: it needs its own 5M candle fetch, sharing that fetch
  // with ORB when both are enabled (see SignalChecker.check()) rather than
  // doubling the request volume.
  // ---------------------------------------------------------------------

  static bool get useBreakoutMomentum => (_env('USE_BREAKOUT_MOMENTUM') ?? 'false').toLowerCase().trim() == 'true';

  /// The Opening Range level source's window — deliberately a SEPARATE,
  /// independently configurable UTC time-of-day window from OrbEngine's
  /// fixed "first 30 minutes of a session" one ("configurable start/end
  /// time boundaries", explicit request — not tied to a session at all).
  /// Expressed in minutes since UTC midnight so any boundary (not just a
  /// whole hour) is representable; parsed from "HH:MM" in .env. Defaults
  /// to 00:00-01:00 UTC. A misconfigured end <= start disables this level
  /// source entirely (see BreakoutMomentumEngine.openingRangeLevels).
  static int get breakoutOpeningRangeStartUtcMinutes => _parseHhMmMinutes(_env('BREAKOUT_OR_START_UTC'), 0);
  static int get breakoutOpeningRangeEndUtcMinutes => _parseHhMmMinutes(_env('BREAKOUT_OR_END_UTC'), 60);

  static int _parseHhMmMinutes(String? raw, int fallback) {
    final parts = raw?.trim().split(':');
    if (parts == null || parts.length != 2) return fallback;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return fallback;
    return h * 60 + m;
  }

  static double _envDouble(String key, double fallback) => double.tryParse(_env(key) ?? '') ?? fallback;
  static int _envInt(String key, int fallback) => int.tryParse(_env(key) ?? '') ?? fallback;
  static bool _envBool(String key, bool fallback) {
    final raw = _env(key)?.toLowerCase().trim();
    if (raw == null || raw.isEmpty) return fallback;
    return raw == 'true';
  }

  // --- Spec 1: Important Level ------------------------------------------

  /// Confirmed-pivot lookback for the Swing High/Low level source (a pivot
  /// needs this many candles closed on BOTH sides before it counts) and
  /// how many of the most recent swings per side stay in the pool.
  static int get breakoutSwingPivotLookback => _envInt('BREAKOUT_SWING_LOOKBACK', 3);
  static int get breakoutSwingMaxCount => _envInt('BREAKOUT_SWING_MAX_COUNT', 3);

  /// Two level sources landing within this many dollars of each other are
  /// the SAME level — the weaker one is dropped (see
  /// BreakoutMomentumEngine.prioritize) so one price can't get two shots.
  static double get breakoutLevelDedupeDollars => _envDouble('BREAKOUT_LEVEL_DEDUPE_DOLLARS', 1.0);

  // --- Spec 2 + 3: Breakout Candle & Momentum ---------------------------

  /// Body-to-ATR(14) validation band: the breakout candle's body must fall
  /// inside [breakoutMinBodyToAtrRatio, breakoutMaxBodyToAtrRatio] of
  /// ATR(14) — below the floor means too little real conviction behind the
  /// close, above the ceiling means a climax/exhaustion candle
  /// statistically prone to a snap-back rather than genuine continuation.
  /// Floor raised 0.5 -> 0.6 on 2026-09-22 per the spec ("Body >= 0.6 x
  /// ATR(14)").
  static double get breakoutMinBodyToAtrRatio => _envDouble('BREAKOUT_MIN_BODY_ATR', 0.6);
  static double get breakoutMaxBodyToAtrRatio => _envDouble('BREAKOUT_MAX_BODY_ATR', 2.5);

  /// Close-Location Wick Filter: the close must sit within this fraction
  /// of the candle's own high-low range on the breakout side — 0.70 means
  /// at or above the 70th percentile for a BUY (bottom 30% for a SELL) —
  /// which is what rules out a large opposing rejection wick even when the
  /// body/ATR reading alone would qualify. Loosened 0.75 -> 0.70 on
  /// 2026-09-22 per the spec ("Close Location >= 70%").
  static double get breakoutCloseLocationThreshold => _envDouble('BREAKOUT_CLOSE_LOCATION', 0.70);

  /// Momentum Confirmation ("أريد أن أرى أن الحركة لديها قوة"): the
  /// breakout candle's range must be at least this multiple of the average
  /// range of the 14 candles before it — i.e. volatility has to EXPAND
  /// into the break, not merely continue.
  static double get breakoutMinRangeToAvgRatio => _envDouble('BREAKOUT_MIN_RANGE_EXPANSION', 1.2);

  // --- Spec 4: Don't chase ----------------------------------------------

  /// Maximum Entry Distance ("إذا اخترق السعر المستوى ثم تحرك مسافة كبيرة
  /// بالفعل، لا تطارده"): the entry candle's close must still be within
  /// this many ATR of the broken level.
  static double get breakoutMaxEntryDistanceAtr => _envDouble('BREAKOUT_MAX_ENTRY_DISTANCE_ATR', 0.8);

  // --- Spec 5: Retest ---------------------------------------------------

  /// Break -> Retest -> Entry is the DEFAULT mode ("اجعل الخيار الأساسي").
  /// Set false to take the breakout candle itself.
  static bool get breakoutRequireRetest => _envBool('BREAKOUT_REQUIRE_RETEST', true);

  /// How many M5 candles back the retest sequence may reach for its
  /// original breakout candle, and how close price must come back to the
  /// level for that return to count as a retest of it.
  static int get breakoutRetestLookbackCandles => _envInt('BREAKOUT_RETEST_LOOKBACK', 24);
  static double get breakoutRetestToleranceDollars => _envDouble('BREAKOUT_RETEST_TOLERANCE_DOLLARS', 0.5);

  // --- Failed-Breakout Reversal (2026-09-22, explicit request) ----------

  /// "في حال الاختراق فشل هل فينا ناخد صفقة بالاتجاه المعاكس" — trades the
  /// TRAP instead of discarding it: a strong break that gets rejected, with
  /// a CLOSE back through the level and then a further confirmation candle
  /// extending that rejection, becomes an entry in the OPPOSITE direction.
  /// Stop Loss anchors to the trap's own extreme (see
  /// BreakoutMomentumEngine._failedReversalTrigger).
  ///
  /// Off by default: measured against the real 2026-09-22 losing streak it
  /// would have turned 2 of 5 losses into clear wins, 2 into
  /// sub-target scratches and 1 into no trade at all (its stop was too
  /// tight to survive the minimum-SL filter) — a genuine improvement, but
  /// not the "all of them" it looks like at first glance, so it stays an
  /// opt-in to test rather than an assumption.
  static bool get breakoutFailedReversalEnabled => _envBool('BREAKOUT_FAILED_REVERSAL', false);

  /// How many M5 candles after the break the failure may arrive in and
  /// still count as a trap. A break that holds for hours before giving way
  /// is a normal trend change, not a fakeout, and trading it as a
  /// "reversal" means entering a move that already happened.
  static int get breakoutFailedReversalMaxCandles => _envInt('BREAKOUT_FAILED_REVERSAL_MAX_CANDLES', 12);

  /// The reversal's OWN "don't chase" limit (2026-09-23): the entry must
  /// still be within this many ATR of the trap's extreme — the level the
  /// Stop Loss is anchored to.
  ///
  /// [breakoutMaxEntryDistanceAtr] cannot do this job: it measures the
  /// entry against the LEVEL, which for a continuation IS the stop anchor
  /// but for a reversal is not. The tier's first live reversal proved the
  /// gap — it entered 0.21 ATR from the level (comfortably "not chasing")
  /// while sitting 3.66 ATR from the trap extreme its stop hung off, which
  /// priced the trade at a 198-pip risk and lost all of it. With this cap
  /// the worst case is [breakoutReversalMaxTrapDistanceAtr] +
  /// [breakoutSlAtrMultiplier] ATR of risk, by construction.
  static double get breakoutReversalMaxTrapDistanceAtr => _envDouble('BREAKOUT_REVERSAL_MAX_TRAP_ATR', 1.5);

  // --- Spec 6: Session filter -------------------------------------------

  /// "للذهب، لا أترك النظام يعمل طوال اليوم" — outside the London and New
  /// York windows below, this tier takes no trade at all. The windows are
  /// .env inputs ("اجعل أوقات الجلسات Inputs") in UTC "HH:MM" form,
  /// independent of the other tiers' own session constants, since broker
  /// server time and DST shift what "the session" means locally.
  static bool get breakoutSessionFilterEnabled => _envBool('BREAKOUT_SESSION_FILTER', true);
  static int get breakoutLondonStartUtcMinutes => _parseHhMmMinutes(_env('BREAKOUT_LONDON_START_UTC'), 7 * 60);
  static int get breakoutLondonEndUtcMinutes => _parseHhMmMinutes(_env('BREAKOUT_LONDON_END_UTC'), 16 * 60);
  static int get breakoutNewYorkStartUtcMinutes => _parseHhMmMinutes(_env('BREAKOUT_NEWYORK_START_UTC'), 12 * 60);
  static int get breakoutNewYorkEndUtcMinutes => _parseHhMmMinutes(_env('BREAKOUT_NEWYORK_END_UTC'), 21 * 60);

  /// The Asian session as a THIRD, separately switchable window (2026-09-23,
  /// explicit request: "فعّل الجلسة الآسيوية كمان، ومنختبرها ومنقرر بعدها").
  /// Deliberately its own flag rather than widened London hours so its
  /// effect can be measured — and reverted — on its own.
  ///
  /// Off by default, and worth knowing why before turning it on: the Asian
  /// range is ALREADY working for this engine without trading inside it —
  /// Asian Session High/Low is one of the five level sources
  /// (BreakoutMomentumEngine.previousSessionLevels), so the quiet Asian
  /// range builds the levels the London open then breaks. Trading during
  /// its formation means taking breakouts in the thinnest liquidity of the
  /// gold day, which is the weakest possible environment for a breakout
  /// engine.
  static bool get breakoutAsianSessionEnabled => _envBool('BREAKOUT_ASIAN_SESSION', false);
  static int get breakoutAsianStartUtcMinutes =>
      _parseHhMmMinutes(_env('BREAKOUT_ASIAN_START_UTC'), asianSessionStartUtc * 60);
  static int get breakoutAsianEndUtcMinutes =>
      _parseHhMmMinutes(_env('BREAKOUT_ASIAN_END_UTC'), asianSessionEndUtc * 60);

  // --- Spec 7 + 9: DXY and HTF direction --------------------------------

  /// Both started as CONFIRMATION weights ("لا تجعل DXY شرطاً مطلقاً قبل
  /// أن تثبت فائدته بالـBacktest") and were promoted to HARD GATES on
  /// 2026-09-23, explicit request — "ياخد بعين الاعتبار لـDXY وHTF وما
  /// يعتبرن استشاريين بس" — after the back-test they were waiting for
  /// arrived by itself: the tier's first Failed-Breakout Reversal fired a
  /// BUY logged as `HTF bearish, DXY neutral/against` and lost 198 pips,
  /// with BOTH advisory checks having pointed the right way and neither
  /// able to stop it.
  ///
  ///   * `block` (default) — a CLEAR disagreement rejects the setup;
  ///   * `score`           — agreement only adds Confluence Score;
  ///   * `off`             — not consulted at all.
  ///
  /// "Clear" matters: neither check ever blocks on missing data. An
  /// unreadable or flat DXY resolves to "confirms" inside
  /// DxyFilterService, and an unclear 1H swing structure returns a null
  /// bias that this tier treats as "no objection" — so a dead feed can
  /// never silently halt trading, only a genuine contradiction can.
  static String get breakoutHtfMode => (_env('BREAKOUT_HTF_MODE') ?? 'block').toLowerCase().trim();
  static String get breakoutDxyMode => (_env('BREAKOUT_DXY_MODE') ?? 'block').toLowerCase().trim();

  // --- Spec 8: News filter ----------------------------------------------

  /// "إذا كان هناك خبر عالي التأثير قريب جداً: No New Entry" — a
  /// high-impact USD event (CPI/NFP/FOMC/Rate/PCE...) within this many
  /// minutes either side blocks a NEW entry on this tier. Existing trades
  /// are never touched.
  static bool get breakoutNewsFilterEnabled => _envBool('BREAKOUT_NEWS_FILTER', true);
  static int get breakoutNewsBlackoutMinutes => _envInt('BREAKOUT_NEWS_BLACKOUT_MINUTES', 15);

  // --- Spec 10: Risk ----------------------------------------------------

  /// "لا تجعل TP ثابتاً بالدولارات. استخدم SL = Structure أو ATR" — the
  /// Stop Loss sits this many ATR BEYOND the broken level (structure AND
  /// volatility, not a fixed dollar distance), and the Take Profit is this
  /// R multiple of the resulting risk. 2R is only the starting point to
  /// test against 1.5R / 2.5R / 3R, not an assumption.
  static double get breakoutSlAtrMultiplier => _envDouble('BREAKOUT_SL_ATR', 1.2);
  ///
  /// Defaults to the global [riskRewardRatio] (2026-09-24, explicit
  /// request: "والتيك بروفيت لكل الصفقات 1.8") rather than carrying its
  /// own separate 2.0 — every tier now targets the SAME multiple unless
  /// this is overridden in .env for a deliberate A/B test.
  static double get breakoutTakeProfitRMultiple => _envDouble('BREAKOUT_TP_R', riskRewardRatio);

  /// Breakout/Momentum tier's own Confluence Score floor — the standard
  /// [minConfluenceScore].
  static const int minConfluenceScoreBreakout = minConfluenceScore;

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

  /// Bridge-Only Mode (2026-09-15, explicit request — "بدي يجيب بشكل لحظي
  /// ما بدي عن طريق Tewleve وغيره، بدي بس عن طريق Metatreader"): when true,
  /// [FailoverDataService] tries ONLY the MT5 bridge — TwelveData and Yahoo
  /// Finance are never touched, not even when the bridge is unreachable.
  /// The opposite tradeoff of the default failover chain: no silent
  /// degrade to a different (non-broker) price source ever, at the cost of
  /// monitoring pausing outright (no candles at all) whenever the bridge
  /// itself is down — exactly what you want when every signal/SL/TP must
  /// be computed off the SAME price your broker will actually fill you at.
  static bool get bridgeOnly => (_env('BRIDGE_ONLY') ?? 'false').toLowerCase().trim() == 'true';

  // ---------------------------------------------------------------------
  // Institutional Risk Management, Spread Filter & Trade Safety Protocols
  // (2026-09-20, explicit request) — every calculation here runs LOCALLY
  // off live MT5 Bridge data (mt5_trading_service.dart), never a paid
  // third-party service. Master-gated by [enableAutoTrading]: while false
  // (the default), the app behaves exactly as before — a signal-only
  // advisor — so an existing install never starts sending real broker
  // orders just from upgrading. Every getter below still has a purpose
  // even with auto-trading off (e.g. the lot size is still computed and
  // shown on a signal for the user's own manual sizing reference).
  // ---------------------------------------------------------------------

  /// Master switch: while false, SignalChecker never calls
  /// Mt5TradingService.openMarketOrder/modifyStopLoss — every setup stays a
  /// local/virtual signal exactly like before this feature existed. Off by
  /// default — this is the one flag that turns Aureus AI from an alert
  /// system into a live auto-trader.
  static bool get enableAutoTrading => (_env('ENABLE_AUTO_TRADING') ?? 'false').toLowerCase().trim() == 'true';

  /// Dynamic Position Sizing — hard risk cap as a percentage of live
  /// account Balance/Equity risked on a single trade's Stop Loss distance.
  /// Configurable via .env; defaults to the requested 1% max risk/trade.
  static double get riskPercentPerTrade => double.tryParse(_env('RISK_PERCENT_PER_TRADE') ?? '') ?? 1.0;

  /// XAUUSD contract size (troy ounces per 1.0 standard lot) — combined
  /// with [TradeSetup.dollarsPerPip] ($0.10/pip) this gives the $/pip value
  /// of one lot, the other half of the lot-size formula alongside the risk
  /// amount and the setup's own SL distance. 100oz is the standard broker
  /// contract; override only if your broker quotes a different one.
  static double get xauContractSize => double.tryParse(_env('XAU_CONTRACT_SIZE') ?? '') ?? 100.0;

  /// Broker lot constraints RiskEngine.calculateLotSize rounds/clamps the
  /// computed size against, so a signal never carries a lot the broker
  /// would reject outright.
  static double get minLotSize => double.tryParse(_env('MIN_LOT_SIZE') ?? '') ?? 0.01;
  static double get maxLotSize => double.tryParse(_env('MAX_LOT_SIZE') ?? '') ?? 5.0;
  static double get lotStep => double.tryParse(_env('LOT_STEP') ?? '') ?? 0.01;

  /// Single Active Position Guard: before any of the 5 engines' signals is
  /// emitted, SignalChecker asks the bridge for open XAUUSD positions (see
  /// Mt5TradingService.getOpenPositions) and skips the new signal outright
  /// if one is already open — on top of (not instead of) the existing
  /// locally-tracked "One Active Trade Limit", which still applies in mock/
  /// standalone modes where there is no real broker position to query.
  ///
  /// Live Spread Protection: the live bid/ask spread (Mt5TradingService.
  /// getSpreadPips) is checked right before a setup is finalized/executed;
  /// exceeding this rejects the trade outright. Default matches the
  /// requested 30-pip ($3.00 on XAUUSD) ceiling.
  static double get maxSpreadPips => double.tryParse(_env('MAX_SPREAD_PIPS') ?? '') ?? 30.0;

  /// Break-Even Stop (RETIRED 2026-09-24, explicit request — "لا تحرك
  /// الستوب لنقطة الدخول ابدا يضل بمحلو يا ستوب يا هدف"). While true, a
  /// trade reaching 1R moved its Stop Loss to Entry; it is now false, so
  /// the Stop Loss NEVER moves once placed and every trade resolves as a
  /// clean binary: the original structural SL, or the Take Profit.
  ///
  /// Why it was turned off: on the reviewed session all three trades that
  /// reached 1R were then stopped out at Entry for exactly 0.0 pips, and
  /// price subsequently continued far enough that at least one of them
  /// would have paid its full target. Note the trade-off this accepts —
  /// with no Break-Even those same three trades could equally have run
  /// back to the full original Stop Loss instead, so this raises the
  /// variance of every losing day as well as the ceiling of every winning
  /// one. Kept as a flag rather than deleted so it can be measured against
  /// the alternative later without another code change.
  ///
  /// The whole Break-Even machinery is left intact behind it —
  /// TradeSetup.breakEvenActive / breakEvenTriggerPrice / activeStopLoss,
  /// the Broker Sync block in SignalChecker._sweepOpenTrades, and the
  /// "⚖️ Break-Even (SL @ Entry)" outcome label — so trades already closed
  /// at Break-Even before this change still render their real history
  /// correctly. Nothing ARMS the flag any more: SignalChecker passes
  /// updateBreakEven: [breakEvenEnabled] into both outcome sweeps.
  static bool get breakEvenEnabled =>
      (_env('BREAK_EVEN_ENABLED') ?? 'false').toLowerCase().trim() == 'true';

  // NOTE: Automatic Partial Take-Profit (closing 50% of the lot at 1:1 R:R)
  // was REMOVED 2026-09-21, explicit request — "بدون قفل جزئي، بس تحريك
  // الستوب للدخول عند 1R" ("no partial close, just move the stop to Entry
  // at 1R"): a trade reaching 1:1 R:R now ONLY moves the REAL position's
  // Stop Loss to Entry (see SignalChecker._resolveOpenTrades's Broker
  // Sync block) — the FULL lot keeps running from there, resolving to
  // either exactly 0 (stopped at Break-Even) or the full Take Profit, a
  // clean binary outcome rather than a blended partial-profit one.
  // Mt5TradingService.closePartial and the bridge's /order/close_partial
  // endpoint still exist (tested, unused) in case this is ever re-enabled.
  // TradeSetup.partialTpExecuted/partialClosePrice are likewise kept ONLY
  // so trades that already partial-closed before this change still report
  // their real blended P&L correctly — no new trade ever sets them again.
}
