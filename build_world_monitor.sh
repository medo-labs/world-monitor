#!/usr/bin/env bash
# Bootstrap: builds the world_monitor project under /root/world_monitor
set -e
mkdir -p /root/world_monitor/collectors
cd /root/world_monitor

cat > 'config.py' << 'WMFILE_EOF'
"""
Central configuration for the World Monitor.
Everything you tune lives here: what to watch and when to shout.
Secrets come from environment variables (see .env.example) — never hard-code them.
"""
import os

TELEGRAM_TOKEN = os.environ.get("WM_TELEGRAM_TOKEN", "")
TELEGRAM_CHAT_ID = os.environ.get("WM_TELEGRAM_CHAT_ID", "")
FRED_API_KEY = os.environ.get("WM_FRED_API_KEY", "")

DB_HOST = os.environ.get("WM_DB_HOST", "localhost")
DB_PORT = os.environ.get("WM_DB_PORT", "5432")
DB_NAME = os.environ.get("WM_DB_NAME", "world_monitor")
DB_USER = os.environ.get("WM_DB_USER", "wm")
DB_PASS = os.environ.get("WM_DB_PASS", "")

EQUITY_INDICES = {
    "^GSPC": "S&P 500 (US)",
    "^IXIC": "Nasdaq (US)",
    "^DJI": "Dow Jones (US)",
    "^FTSE": "FTSE 100 (UK)",
    "^GDAXI": "DAX (Germany)",
    "^FCHI": "CAC 40 (France)",
    "^N225": "Nikkei 225 (Japan)",
    "^HSI": "Hang Seng (HK)",
    "000001.SS": "Shanghai Composite (China)",
    "^AXJO": "ASX 200 (Australia)",
}

COMMODITIES = {
    "GC=F": "Gold",
    "SI=F": "Silver",
    "CL=F": "Crude Oil",
    "HG=F": "Copper",
    "NG=F": "Natural Gas",
    "ZW=F": "Wheat",
}

CURRENCIES = {
    "DX-Y.NYB": "US Dollar Index (DXY)",
    "JPY=X": "USD/JPY",
    "EURUSD=X": "EUR/USD",
    "AUDUSD=X": "AUD/USD",
}

CRYPTO = {
    "bitcoin": "Bitcoin",
    "ethereum": "Ethereum",
    "bittensor": "TAO",
}

FRED_SERIES = {
    "DGS10": "US 10Y Treasury Yield",
    "DGS2": "US 2Y Treasury Yield",
    "T10Y2Y": "10Y-2Y Spread (yield curve)",
    "UNRATE": "US Unemployment Rate",
    "ICSA": "Initial Jobless Claims",
    "M2SL": "M2 Money Supply",
    "UMCSENT": "Consumer Sentiment",
}

ALERT_THRESHOLDS = {
    "equity": 2.0,
    "commodity": 3.0,
    "currency": 1.0,
    "crypto": 5.0,
}

ALERT_COOLDOWN_MINUTES = 180
WMFILE_EOF

cat > 'db.py' << 'WMFILE_EOF'
"""
Database layer. One table holds every observation from every collector.
House rule (same as your TAO stack): we only ever INSERT. Never delete.
"""
import json
import psycopg2
from psycopg2.extras import RealDictCursor
from datetime import datetime, timezone

import config


def connect():
    return psycopg2.connect(
        host=config.DB_HOST,
        port=config.DB_PORT,
        dbname=config.DB_NAME,
        user=config.DB_USER,
        password=config.DB_PASS,
    )


def init_schema():
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS observations (
                id          BIGSERIAL PRIMARY KEY,
                ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
                asset_class TEXT NOT NULL,
                symbol      TEXT NOT NULL,
                name        TEXT,
                price       DOUBLE PRECISION,
                change_pct  DOUBLE PRECISION,
                extra       JSONB
            );
            """
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_obs_symbol_ts "
            "ON observations (symbol, ts DESC);"
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS alert_state (
                symbol         TEXT PRIMARY KEY,
                last_alert_ts  TIMESTAMPTZ NOT NULL
            );
            """
        )
        conn.commit()
    print("[db] schema ready")


def write_observation(asset_class, symbol, name, price,
                      change_pct=None, extra=None):
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO observations
                (ts, asset_class, symbol, name, price, change_pct, extra)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            """,
            (
                datetime.now(timezone.utc),
                asset_class,
                symbol,
                name,
                price,
                change_pct,
                json.dumps(extra) if extra is not None else None,
            ),
        )
        conn.commit()


def latest_per_symbol():
    with connect() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            """
            SELECT DISTINCT ON (symbol)
                symbol, name, asset_class, price, change_pct, ts
            FROM observations
            ORDER BY symbol, ts DESC;
            """
        )
        return cur.fetchall()


def get_last_alert(symbol):
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT last_alert_ts FROM alert_state WHERE symbol = %s;",
            (symbol,),
        )
        row = cur.fetchone()
        return row[0] if row else None


def set_last_alert(symbol, ts):
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO alert_state (symbol, last_alert_ts)
            VALUES (%s, %s)
            ON CONFLICT (symbol)
            DO UPDATE SET last_alert_ts = EXCLUDED.last_alert_ts;
            """,
            (symbol, ts),
        )
        conn.commit()


if __name__ == "__main__":
    init_schema()
WMFILE_EOF

cat > 'alert_engine.py' << 'WMFILE_EOF'
"""
Alert engine — the brain. Reads the latest observation for every symbol,
checks the daily % move against the threshold, fires Telegram with cooldown.
"""
import sys
import requests
from datetime import datetime, timezone, timedelta

import config
import db


def send_telegram(text):
    if not config.TELEGRAM_TOKEN or not config.TELEGRAM_CHAT_ID:
        print("[alert] Telegram not configured — would have sent:\n" + text,
              file=sys.stderr)
        return
    url = f"https://api.telegram.org/bot{config.TELEGRAM_TOKEN}/sendMessage"
    resp = requests.post(
        url,
        data={"chat_id": config.TELEGRAM_CHAT_ID, "text": text},
        timeout=30,
    )
    resp.raise_for_status()


def threshold_for(asset_class):
    return config.ALERT_THRESHOLDS.get(asset_class)


def run():
    now = datetime.now(timezone.utc)
    cooldown = timedelta(minutes=config.ALERT_COOLDOWN_MINUTES)
    rows = db.latest_per_symbol()

    for r in rows:
        change = r["change_pct"]
        threshold = threshold_for(r["asset_class"])
        if change is None or threshold is None:
            continue
        if abs(change) < threshold:
            continue

        last = db.get_last_alert(r["symbol"])
        if last and (now - last) < cooldown:
            continue

        direction = "🔴 DOWN" if change < 0 else "🟢 UP"
        msg = (
            f"{direction} {r['name']}\n"
            f"{r['price']:,.2f}  ({change:+.2f}% today)\n"
            f"[{r['asset_class']}]"
        )
        send_telegram(msg)
        db.set_last_alert(r["symbol"], now)
        print(f"[alert] sent: {r['name']} {change:+.2f}%")


if __name__ == "__main__":
    run()
WMFILE_EOF

cat > 'digest.py' << 'WMFILE_EOF'
"""
Nightly digest — one Telegram message summarising the whole board,
biggest movers on top. Run once a day via cron.
"""
import sys
import requests

import config
import db


def send_telegram(text):
    if not config.TELEGRAM_TOKEN or not config.TELEGRAM_CHAT_ID:
        print("[digest] Telegram not configured — would have sent:\n" + text,
              file=sys.stderr)
        return
    url = f"https://api.telegram.org/bot{config.TELEGRAM_TOKEN}/sendMessage"
    requests.post(
        url,
        data={"chat_id": config.TELEGRAM_CHAT_ID, "text": text},
        timeout=30,
    )


def run():
    rows = db.latest_per_symbol()
    movers = [r for r in rows if r["change_pct"] is not None]
    movers.sort(key=lambda r: abs(r["change_pct"]), reverse=True)

    lines = ["🌍 WORLD MONITOR — daily digest", ""]
    for r in movers:
        arrow = "🔴" if r["change_pct"] < 0 else "🟢"
        lines.append(
            f"{arrow} {r['name']}: {r['price']:,.2f} "
            f"({r['change_pct']:+.2f}%)"
        )

    macro = [r for r in rows if r["asset_class"] == "macro"]
    if macro:
        lines.append("")
        lines.append("— macro —")
        for r in macro:
            lines.append(f"{r['name']}: {r['price']}")

    send_telegram("\n".join(lines))
    print("[digest] sent")


if __name__ == "__main__":
    run()
WMFILE_EOF

cat > 'requirements.txt' << 'WMFILE_EOF'
psycopg2-binary>=2.9
requests>=2.31
yfinance>=0.2.40
fredapi>=0.5.2
WMFILE_EOF

cat > 'run_once.sh' << 'WMFILE_EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -f .env ]; then
    set -a; source .env; set +a
fi
PY="./venv/bin/python"
echo "=== run @ $(date -u) ==="
$PY collectors/crypto.py        || true
$PY collectors/markets.py all   || true
$PY alert_engine.py             || true
WMFILE_EOF

cat > '.env.example' << 'WMFILE_EOF'
export WM_TELEGRAM_TOKEN=""
export WM_TELEGRAM_CHAT_ID=""
export WM_FRED_API_KEY=""
export WM_DB_HOST="localhost"
export WM_DB_PORT="5432"
export WM_DB_NAME="world_monitor"
export WM_DB_USER="wm"
export WM_DB_PASS="change_me"
WMFILE_EOF

cat > 'collectors/crypto.py' << 'WMFILE_EOF'
"""
Crypto collector — CoinGecko free endpoint, no API key required.
"""
import sys
import requests

import config
import db

URL = "https://api.coingecko.com/api/v3/simple/price"


def run():
    ids = ",".join(config.CRYPTO.keys())
    params = {
        "ids": ids,
        "vs_currencies": "usd",
        "include_24hr_change": "true",
    }
    resp = requests.get(URL, params=params, timeout=30)
    resp.raise_for_status()
    data = resp.json()

    for coin_id, name in config.CRYPTO.items():
        row = data.get(coin_id)
        if not row:
            print(f"[crypto] no data for {coin_id}", file=sys.stderr)
            continue
        price = row.get("usd")
        change = row.get("usd_24h_change")
        db.write_observation(
            asset_class="crypto",
            symbol=coin_id,
            name=name,
            price=price,
            change_pct=change,
        )
        print(f"[crypto] {name}: ${price:,.2f} ({change:+.2f}%)")


if __name__ == "__main__":
    run()
WMFILE_EOF

cat > 'collectors/markets.py' << 'WMFILE_EOF'
"""
Market collector — Yahoo Finance via yfinance.
Handles global equity indices, commodities, and currencies.
    python markets.py equities | commodities | currencies | all
"""
import sys
import yfinance as yf

import config
import db


def _fetch_and_store(asset_class, tickers):
    for symbol, name in tickers.items():
        try:
            t = yf.Ticker(symbol)
            hist = t.history(period="2d")
            if hist.empty:
                print(f"[{asset_class}] no data for {symbol}", file=sys.stderr)
                continue
            price = float(hist["Close"].iloc[-1])
            if len(hist) >= 2:
                prev = float(hist["Close"].iloc[-2])
                change = (price - prev) / prev * 100 if prev else None
            else:
                change = None
            db.write_observation(
                asset_class=asset_class,
                symbol=symbol,
                name=name,
                price=price,
                change_pct=change,
            )
            chg_str = f"{change:+.2f}%" if change is not None else "n/a"
            print(f"[{asset_class}] {name}: {price:,.2f} ({chg_str})")
        except Exception as e:
            print(f"[{asset_class}] error on {symbol}: {e}", file=sys.stderr)


def run(bucket="all"):
    if bucket in ("equities", "all"):
        _fetch_and_store("equity", config.EQUITY_INDICES)
    if bucket in ("commodities", "all"):
        _fetch_and_store("commodity", config.COMMODITIES)
    if bucket in ("currencies", "all"):
        _fetch_and_store("currency", config.CURRENCIES)


if __name__ == "__main__":
    bucket = sys.argv[1] if len(sys.argv) > 1 else "all"
    run(bucket)
WMFILE_EOF

cat > 'collectors/macro.py' << 'WMFILE_EOF'
"""
Macro collector — FRED (St. Louis Fed). Free, needs a free API key.
Context, not a trigger. Run once a day.
"""
import sys
from fredapi import Fred

import config
import db


def run():
    if not config.FRED_API_KEY:
        print("[macro] WM_FRED_API_KEY not set — skipping", file=sys.stderr)
        return
    fred = Fred(api_key=config.FRED_API_KEY)
    for series_id, name in config.FRED_SERIES.items():
        try:
            s = fred.get_series(series_id)
            s = s.dropna()
            if s.empty:
                print(f"[macro] no data for {series_id}", file=sys.stderr)
                continue
            value = float(s.iloc[-1])
            db.write_observation(
                asset_class="macro",
                symbol=series_id,
                name=name,
                price=value,
                change_pct=None,
            )
            print(f"[macro] {name}: {value}")
        except Exception as e:
            print(f"[macro] error on {series_id}: {e}", file=sys.stderr)


if __name__ == "__main__":
    run()
WMFILE_EOF

chmod +x run_once.sh
echo ""
echo "=== world_monitor built. Files: ==="
ls -la /root/world_monitor /root/world_monitor/collectors
