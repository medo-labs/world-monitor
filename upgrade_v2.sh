#!/usr/bin/env bash
# World Monitor v2 — breadth alerts, VIX + extra markets, drawdown, backups.
# Safe to run more than once.
set -e
cd /root/world_monitor

# --- 1. append new settings to config.py (only once) ---
if grep -q 'BREADTH_MIN_COUNT' config.py; then
  echo "[upgrade] config already patched, skipping"
else
cat >> config.py << 'WMCFG_EOF'

# ---------------------------------------------------------------------------
# v2 additions
# ---------------------------------------------------------------------------

VOLATILITY = {
    "^VIX": "VIX (fear index)",
}

EXTRA_MARKETS = {
    "EEM": "Emerging Markets (EEM)",
    "VNQ": "US REITs (VNQ)",
    "HYG": "High-Yield Credit (HYG)",
    "TLT": "20Y+ Treasuries (TLT)",
}

VIX_LEVELS = [30.0, 40.0]

ALERT_THRESHOLDS["volatility"] = 15.0
ALERT_THRESHOLDS["etf"] = 2.5

BREADTH_DOWN_PCT = -1.0
BREADTH_MIN_COUNT = 6
BREADTH_COOLDOWN_MINUTES = 360

DRAWDOWN_LOOKBACK_DAYS = 30
DRAWDOWN_THRESHOLDS = {
    "equity": 8.0,
    "commodity": 12.0,
    "currency": 5.0,
    "crypto": 20.0,
    "etf": 10.0,
    "volatility": None,
}
DRAWDOWN_COOLDOWN_MINUTES = 1440
WMCFG_EOF
  echo "[upgrade] config.py patched"
fi

# --- writing breadth.py ---
cat > 'breadth.py' << 'WMFILE_EOF'
"""
Breadth alert — the crash detector.
One index down 2% is routine. Seven of ten down together is a regime change.
Also handles VIX level alerts.
"""
import sys
import requests
from datetime import datetime, timezone, timedelta

import config
import db


def send_telegram(text):
    if not config.TELEGRAM_TOKEN or not config.TELEGRAM_CHAT_ID:
        print("[breadth] Telegram not configured", file=sys.stderr)
        return
    url = f"https://api.telegram.org/bot{config.TELEGRAM_TOKEN}/sendMessage"
    resp = requests.post(
        url,
        data={"chat_id": config.TELEGRAM_CHAT_ID, "text": text},
        timeout=30,
    )
    resp.raise_for_status()


def _cooled_down(key, now, minutes):
    last = db.get_last_alert(key)
    if last and (now - last) < timedelta(minutes=minutes):
        return False
    return True


def check_equity_breadth(rows, now):
    core = set(config.EQUITY_INDICES.keys())
    equities = [r for r in rows
                if r["symbol"] in core and r["change_pct"] is not None]
    if not equities:
        return

    down = [r for r in equities if r["change_pct"] <= config.BREADTH_DOWN_PCT]
    total = len(equities)

    print(f"[breadth] {len(down)}/{total} indices down "
          f"{config.BREADTH_DOWN_PCT}% or more")

    if len(down) < config.BREADTH_MIN_COUNT:
        return
    if not _cooled_down("__breadth_equity__", now,
                        config.BREADTH_COOLDOWN_MINUTES):
        print("[breadth] breach, but within cooldown")
        return

    down.sort(key=lambda r: r["change_pct"])
    lines = [
        "\U0001F6A8 BROAD SELL-OFF",
        f"{len(down)} of {total} world indices down "
        f"{abs(config.BREADTH_DOWN_PCT):.0f}%+ together",
        "",
    ]
    for r in down:
        lines.append(f"\U0001F534 {r['name']}: {r['change_pct']:+.2f}%")

    send_telegram("\n".join(lines))
    db.set_last_alert("__breadth_equity__", now)
    print(f"[breadth] ALERT SENT — {len(down)}/{total} down")


def check_vix_levels(rows, now):
    vix = next((r for r in rows if r["symbol"] == "^VIX"), None)
    if not vix or vix["price"] is None:
        return

    level = vix["price"]
    print(f"[breadth] VIX at {level:.2f}")

    breached = [lv for lv in config.VIX_LEVELS if level >= lv]
    if not breached:
        return
    top = max(breached)

    key = f"__vix_{int(top)}__"
    if not _cooled_down(key, now, config.BREADTH_COOLDOWN_MINUTES):
        return

    send_telegram(
        f"\u26A0\uFE0F VIX above {top:.0f}\n"
        f"Now {level:.2f} — fear elevated"
    )
    db.set_last_alert(key, now)
    print(f"[breadth] VIX ALERT SENT — above {top}")


def run():
    now = datetime.now(timezone.utc)
    rows = db.latest_per_symbol()
    check_equity_breadth(rows, now)
    check_vix_levels(rows, now)


if __name__ == "__main__":
    run()
WMFILE_EOF

# --- writing drawdown.py ---
cat > 'drawdown.py' << 'WMFILE_EOF'
"""
Drawdown tracker — catches the slow bleeds that daily % misses.
Reads history already in the observations table; fetches nothing new.
"""
import sys
import requests
from datetime import datetime, timezone, timedelta

import config
import db


def send_telegram(text):
    if not config.TELEGRAM_TOKEN or not config.TELEGRAM_CHAT_ID:
        print("[drawdown] Telegram not configured", file=sys.stderr)
        return
    url = f"https://api.telegram.org/bot{config.TELEGRAM_TOKEN}/sendMessage"
    resp = requests.post(
        url,
        data={"chat_id": config.TELEGRAM_CHAT_ID, "text": text},
        timeout=30,
    )
    resp.raise_for_status()


def compute_drawdowns(days):
    sql = """
        WITH recent AS (
            SELECT symbol, name, asset_class, price, ts
            FROM observations
            WHERE ts > now() - make_interval(days => %s)
              AND price IS NOT NULL
              AND asset_class <> 'macro'
        ),
        highs AS (
            SELECT symbol, max(price) AS high
            FROM recent
            GROUP BY symbol
        ),
        latest AS (
            SELECT DISTINCT ON (symbol)
                symbol, name, asset_class, price
            FROM recent
            ORDER BY symbol, ts DESC
        )
        SELECT l.symbol, l.name, l.asset_class, l.price, h.high
        FROM latest l
        JOIN highs h ON h.symbol = l.symbol
        ORDER BY l.symbol;
    """
    from psycopg2.extras import RealDictCursor
    with db.connect() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(sql, (days,))
        rows = cur.fetchall()

    out = []
    for r in rows:
        high = r["high"]
        price = r["price"]
        if not high or high <= 0:
            continue
        dd = (price - high) / high * 100.0
        out.append({
            "symbol": r["symbol"],
            "name": r["name"],
            "asset_class": r["asset_class"],
            "price": price,
            "high": high,
            "drawdown": dd,
        })
    return out


def run():
    now = datetime.now(timezone.utc)
    days = config.DRAWDOWN_LOOKBACK_DAYS
    cooldown = timedelta(minutes=config.DRAWDOWN_COOLDOWN_MINUTES)
    rows = compute_drawdowns(days)

    if not rows:
        print("[drawdown] no history yet")
        return

    rows.sort(key=lambda r: r["drawdown"])
    print(f"[drawdown] {days}-day drawdowns (worst first):")
    for r in rows[:10]:
        print(f"  {r['name']}: {r['drawdown']:+.1f}% "
              f"(now {r['price']:,.2f} / high {r['high']:,.2f})")

    for r in rows:
        threshold = config.DRAWDOWN_THRESHOLDS.get(r["asset_class"])
        if threshold is None:
            continue
        if r["drawdown"] > -threshold:
            continue

        key = f"__dd_{r['symbol']}__"
        last = db.get_last_alert(key)
        if last and (now - last) < cooldown:
            continue

        send_telegram(
            f"\U0001F4C9 {r['name']} — slow bleed\n"
            f"{r['drawdown']:+.1f}% from its {days}-day high\n"
            f"Now {r['price']:,.2f} (high was {r['high']:,.2f})"
        )
        db.set_last_alert(key, now)
        print(f"[drawdown] ALERT SENT — {r['name']} {r['drawdown']:+.1f}%")


if __name__ == "__main__":
    run()
WMFILE_EOF

# --- writing collectors/markets.py ---
cat > 'collectors/markets.py' << 'WMFILE_EOF'
"""
Market collector — Yahoo Finance via yfinance.
Global indices, commodities, currencies, plus (v2) VIX and extra ETFs.
    python -m collectors.markets equities|commodities|currencies|extras|all
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
    if bucket in ("extras", "all"):
        _fetch_and_store("volatility", config.VOLATILITY)
        _fetch_and_store("etf", config.EXTRA_MARKETS)


if __name__ == "__main__":
    bucket = sys.argv[1] if len(sys.argv) > 1 else "all"
    run(bucket)
WMFILE_EOF

# --- writing backup_db.sh ---
cat > 'backup_db.sh' << 'WMFILE_EOF'
#!/usr/bin/env bash
# Nightly database snapshot, gzipped, keeping the last 14 days.
# Caveat: writes to the SAME droplet. Protects against a bad query or wipe,
# NOT against the droplet dying. Copy off-box later for real safety.
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
    set -a; source .env; set +a
fi

BACKUP_DIR="/root/world_monitor/backups"
mkdir -p "$BACKUP_DIR"

STAMP=$(date -u +%Y%m%d_%H%M)
OUT="$BACKUP_DIR/world_monitor_${STAMP}.sql.gz"

PGPASSWORD="$WM_DB_PASS" pg_dump \
    -h "$WM_DB_HOST" -p "$WM_DB_PORT" \
    -U "$WM_DB_USER" -d "$WM_DB_NAME" \
    | gzip > "$OUT"

echo "[backup] wrote $OUT ($(du -h "$OUT" | cut -f1))"

ls -1t "$BACKUP_DIR"/world_monitor_*.sql.gz 2>/dev/null \
    | tail -n +15 \
    | xargs -r rm -f

echo "[backup] $(ls -1 "$BACKUP_DIR" | wc -l) snapshots retained"
WMFILE_EOF

chmod +x backup_db.sh

# --- update run_once.sh to include the breadth check ---
cat > run_once.sh << 'WMRUN_EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -f .env ]; then
    set -a; source .env; set +a
fi
PY="./venv/bin/python"
echo "=== run @ $(date -u) ==="
$PY -m collectors.crypto      || true
$PY -m collectors.markets all || true
$PY alert_engine.py           || true
$PY breadth.py                || true
WMRUN_EOF
chmod +x run_once.sh

echo ""
echo "=== v2 installed ==="
ls -la /root/world_monitor
