# Aureus AI 🟡

**Automated XAUUSD (Gold) Trading Assistant & Signal Generator — built in Flutter.**

Aureus AI watches Gold across 4H / 1H / 15M / 5M, detects a **trendline ×
horizontal S/R confluence ("the Sweet Spot")**, waits for a candlestick
confirmation (Pinbar / Engulfing), prices the trade with a strict **1:2
Risk:Reward**, asks an AI model for a short trade thesis, and pushes the
signal to the app and to Telegram.

---

## ⚠️ Important architecture note: why there's a `/bridge` folder

MetaTrader5's official Python package is a **native Windows library**
that talks to a locally running MT5 terminal — it cannot run inside
Flutter (mobile, desktop, or web all run in sandboxed/managed runtimes
with no access to that native API). This is a hard platform limitation,
not a design choice.

So Aureus AI is split into two pieces:

1. **`/bridge`** — a tiny Python FastAPI server that wraps the official
   `MetaTrader5` package and exposes candle data over plain REST
   (`GET /candles?symbol=XAUUSD&timeframe=15&count=300`). Runs on the
   same Windows machine as your MT5 terminal.
2. **The Flutter app (`/lib`)** — all the strategy logic (pivots,
   trendlines, S/R, candlestick patterns, confluence, risk engine, AI
   commentary, notifications, UI) lives here, in Dart, and talks to
   the bridge over HTTP.

If you don't have MT5 running yet, set `USE_MOCK_DATA=true` in `.env`
(the default) and the whole app — strategy engine included — runs on
realistic simulated candles so you can see it working end to end.

---

## 📁 Project structure

```text
aureus_ai/
├── pubspec.yaml
├── .env.example              # copy to .env and fill in your keys
├── lib/
│   ├── main.dart              # app entrypoint
│   ├── config/
│   │   └── app_config.dart    # every tunable constant + .env loader
│   ├── models/
│   │   ├── candle.dart
│   │   ├── pivot.dart          # Pivot, Trendline, SrLevel, ConfluenceZone, CandlePattern
│   │   └── trade_setup.dart
│   ├── services/
│   │   ├── data_service.dart   # MT5 bridge client + mock data generator
│   │   ├── ta_engine.dart      # pivots, trendlines, S/R, patterns, confluence finder
│   │   ├── risk_engine.dart    # Entry/SL/TP with strict 1:2 R:R
│   │   ├── ai_engine.dart      # Claude API call for trade commentary
│   │   ├── notifier_service.dart  # local push + Telegram delivery
│   │   └── signal_monitor.dart    # orchestrator loop (ChangeNotifier)
│   ├── screens/
│   │   ├── home_screen.dart
│   │   ├── signal_detail_screen.dart
│   │   └── settings_screen.dart
│   └── widgets/
│       └── signal_card.dart
└── bridge/
    ├── mt5_bridge_server.py    # FastAPI server wrapping MetaTrader5
    └── requirements.txt
```

---

## 🚀 Getting started (mock mode — no MT5 needed)

```bash
flutter pub get
flutter run
```

`.env` already ships with `USE_MOCK_DATA=true`, so the app launches,
generates simulated XAUUSD candles, and runs the full confluence
strategy against them. Tap **"Start Monitoring"** on the home screen.

---

## 🔌 Going live with real MT5 data

1. **On your Windows machine** (where MT5 is installed and logged in):
   ```bash
   cd bridge
   pip install -r requirements.txt
   python mt5_bridge_server.py
   ```
   This starts the bridge at `http://<your-pc-ip>:8000`.

2. **In the Flutter app**, copy `.env.example` to `.env` and set:
   ```env
   USE_MOCK_DATA=false
   BRIDGE_BASE_URL=http://<your-pc-ip>:8000
   ```
   If your phone isn't on the same network as the PC, tunnel the
   bridge with ngrok/Tailscale and use that URL instead.

3. **Rebuild/hot-restart** the app. `Mt5BridgeDataService` will now
   pull real OHLC candles for every check.

---

## 🤖 Enabling AI trade commentary

Set in `.env`:
```env
ANTHROPIC_API_KEY=sk-ant-...
ANTHROPIC_MODEL=claude-sonnet-4-6
```
Without a key, `AiEngine` falls back to a deterministic 2-bullet
explanation so the app still works — you just won't get LLM-generated
commentary.

> Production note: calling the Anthropic API straight from a mobile
> client exposes the key inside the compiled app. For a real
> deployment, proxy `AiEngine`'s request through the same `/bridge`
> server (add one `/ai-commentary` endpoint there) instead of calling
> `api.anthropic.com` directly from Flutter.

---

## 📲 Enabling Telegram alerts

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy its token.
2. Message the bot once, then open
   `https://api.telegram.org/bot<token>/getUpdates` to find your `chat_id`.
3. Set in `.env`:
   ```env
   TELEGRAM_BOT_TOKEN=123456:ABC-DEF...
   TELEGRAM_CHAT_ID=987654321
   ```

Every confirmed signal is now pushed as a formatted card to that chat,
in addition to the in-app / OS local notification.

---

## 🧠 Strategy logic (implemented in `ta_engine.dart` + `risk_engine.dart`)

1. **Pivots** — a candle is a swing high/low if it's the extreme within
   a `±lookback` window (`TaEngine.findPivots`).
2. **Trendlines** — least-squares line through the most recent swing
   lows (ascending support) and swing highs (descending resistance)
   on the 15M chart (`TaEngine.buildTrendlines`).
3. **Horizontal S/R** — pivot prices are clustered within a small
   width; a cluster with ≥ 2 touches becomes an S/R zone
   (`TaEngine.findSrLevels`).
4. **Confluence ("Sweet Spot")** — fires only when a trendline's
   projected price and an S/R level sit within
   `AppConfig.confluenceThreshold` of each other AND of the current
   price (`TaEngine.findConfluence`).
5. **Confirmation candle** — Pinbar / Engulfing / Doji classification
   on 5M (preferred, tighter SL) or 15M (`TaEngine.classifyPattern`).
6. **Risk engine** — Entry = confirmation candle close; SL = beyond
   the wick / S/R level + buffer; TP = `2 × risk distance`, enforced
   as a hard 1:2 ratio (`RiskEngine.buildTradeSetup`).

All thresholds (confluence width, buffer, R:R ratio, poll interval,
timeframes) are centralized in `lib/config/app_config.dart`.

---

## 🛣️ Suggested next steps

- Add a live candlestick chart (the `fl_chart` dependency is already
  included) rendering the trendlines/S/R zones on the signal detail
  screen.
- Persist signal history locally (e.g. with `sqflite` or `Hive`)
  instead of keeping it only in memory.
- Add a background isolate / WorkManager task so monitoring continues
  when the app is backgrounded.
- Extend `/bridge` with an authenticated endpoint if exposing it
  beyond your local network.
